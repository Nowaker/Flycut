#import "FlycutArchive.h"
#import <sqlite3.h>
#import <CoreFoundation/CoreFoundation.h>
#import <limits.h>

NSString * const FlycutArchiveErrorDomain = @"net.nowaker.flycut.archive";
NSString * const FlycutArchiveDidChangeNotification = @"FlycutArchiveDidChangeNotification";
NSString * const FlycutArchiveProtocol = @"net.nowaker.flycut.events";

static BOOL ArchiveError(NSError **error, FlycutArchiveErrorCode code, NSString *message) {
	if (error) *error = [NSError errorWithDomain:FlycutArchiveErrorDomain code:code
		userInfo:@{NSLocalizedDescriptionKey: message}];
	return NO;
}

static void DrainPool(NSAutoreleasePool *pool, NSError **error) {
	NSError *saved = error ? [*error retain] : nil;
	[pool drain];
	if (error) *error = [saved autorelease];
}

static BOOL UUIDIsValid(id value) {
	if (![value isKindOfClass:[NSString class]] || [value length] != 36) return NO;
	NSUUID *uuid = [[[NSUUID alloc] initWithUUIDString:value] autorelease];
	return uuid && [[[[uuid UUIDString] lowercaseString] description] isEqualToString:value];
}

static BOOL IsBoolean(id value) {
	return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL IsInteger(id value) {
	if (![value isKindOfClass:[NSNumber class]] || IsBoolean(value) ||
		CFNumberIsFloatType((CFNumberRef)value)) return NO;
	return [[NSDecimalNumber decimalNumberWithString:[value stringValue]]
		compare:[NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%lld", [value longLongValue]]]] == NSOrderedSame;
}

static BOOL NullableString(id value) {
	return value == [NSNull null] || ([value isKindOfClass:[NSString class]] &&
		[value dataUsingEncoding:NSUTF8StringEncoding] != nil);
}

static BOOL HasKeys(NSDictionary *dictionary, NSArray *keys) {
	return [dictionary isKindOfClass:[NSDictionary class]] && [dictionary count] == [keys count] &&
		[[NSSet setWithArray:[dictionary allKeys]] isEqualToSet:[NSSet setWithArray:keys]];
}

static BOOL ParseClock(id value, long long *clock) {
	if (![value isKindOfClass:[NSString class]] || [value length] == 0 || [value length] > 19) return NO;
	long long result = 0;
	for (NSUInteger i = 0; i < [value length]; i++) {
		unichar c = [value characterAtIndex:i];
		if (c < '0' || c > '9' || (i == 0 && c == '0')) return NO;
		if (result > (LLONG_MAX - (c - '0')) / 10) return NO;
		result = result * 10 + c - '0';
	}
	if (clock) *clock = result;
	return YES;
}

static NSString *ColumnString(sqlite3_stmt *statement, int column) {
	if (sqlite3_column_type(statement, column) == SQLITE_NULL) return nil;
	return [[[NSString alloc] initWithBytes:sqlite3_column_text(statement, column)
		length:sqlite3_column_bytes(statement, column) encoding:NSUTF8StringEncoding] autorelease];
}

static NSData *ColumnData(sqlite3_stmt *statement, int column) {
	return [NSData dataWithBytes:sqlite3_column_blob(statement, column) length:sqlite3_column_bytes(statement, column)];
}

static void ContainsText(sqlite3_context *context, int count, sqlite3_value **values) {
	@autoreleasepool {
		NSString *text = [[[NSString alloc] initWithBytes:sqlite3_value_text(values[0])
			length:sqlite3_value_bytes(values[0]) encoding:NSUTF8StringEncoding] autorelease];
		NSString *query = [[[NSString alloc] initWithBytes:sqlite3_value_text(values[1])
			length:sqlite3_value_bytes(values[1]) encoding:NSUTF8StringEncoding] autorelease];
		sqlite3_result_int(context, [query length] == 0 || (text && query &&
			[text rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound));
	}
}

@interface FlycutArchive ()
- (BOOL)execute:(NSString *)sql bindings:(NSArray *)bindings error:(NSError **)error;
- (sqlite3_stmt *)prepare:(NSString *)sql bindings:(NSArray *)bindings error:(NSError **)error;
- (NSDictionary *)metadata:(NSError **)error;
- (BOOL)insertEvent:(NSDictionary *)event changed:(BOOL *)changed error:(NSError **)error;
- (NSDictionary *)localEvent:(NSString *)operation itemID:(NSString *)itemID payload:(NSDictionary *)payload error:(NSError **)error;
- (BOOL)finishTransaction:(BOOL)success changed:(BOOL)changed error:(NSError **)error;
@end

@implementation FlycutArchive

+ (BOOL)validateEvent:(NSDictionary *)event error:(NSError **)error {
	if (!HasKeys(event, @[@"protocol", @"version", @"collection_id", @"event_id", @"device_id", @"clock", @"op", @"item_id", @"payload"]) ||
		![[event objectForKey:@"protocol"] isEqual:FlycutArchiveProtocol] ||
		!IsInteger([event objectForKey:@"version"]) || [[event objectForKey:@"version"] longLongValue] != 1 ||
		!UUIDIsValid([event objectForKey:@"collection_id"]) || !UUIDIsValid([event objectForKey:@"event_id"]) ||
		!UUIDIsValid([event objectForKey:@"device_id"]) || !UUIDIsValid([event objectForKey:@"item_id"]) ||
		!ParseClock([event objectForKey:@"clock"], NULL))
		return ArchiveError(error, FlycutArchiveInvalidEvent, @"Invalid event envelope or protocol version.");
	NSString *op = [event objectForKey:@"op"];
	NSDictionary *payload = [event objectForKey:@"payload"];
	BOOL valid = NO;
	if ([op isEqual:@"create"]) {
		id text = [payload isKindOfClass:[NSDictionary class]] ? [payload objectForKey:@"text"] : nil;
		id date = [payload isKindOfClass:[NSDictionary class]] ? [payload objectForKey:@"captured_at_ms"] : nil;
		valid = HasKeys(payload, @[@"text", @"content_type", @"captured_at_ms", @"source_app", @"source_id", @"favorite"]) &&
			[[event objectForKey:@"event_id"] isEqual:[event objectForKey:@"item_id"]] &&
			[text isKindOfClass:[NSString class]] && [text length] > 0 && [text dataUsingEncoding:NSUTF8StringEncoding] &&
			[[payload objectForKey:@"content_type"] isEqual:@"text/plain"] && (date == [NSNull null] || IsInteger(date)) &&
			NullableString([payload objectForKey:@"source_app"]) && NullableString([payload objectForKey:@"source_id"]) &&
			IsBoolean([payload objectForKey:@"favorite"]);
	} else if ([op isEqual:@"favorite"]) {
		valid = HasKeys(payload, @[@"value"]) && IsBoolean([payload objectForKey:@"value"]);
	} else if ([op isEqual:@"touch"] || [op isEqual:@"delete"]) {
		valid = HasKeys(payload, @[]);
	}
	return valid || ArchiveError(error, FlycutArchiveInvalidEvent, @"Invalid operation or payload.");
}

- (id)initWithPath:(NSString *)path error:(NSError **)error {
	self = [super init];
	if (!self) return nil;
	if (![path isKindOfClass:[NSString class]] || [path length] == 0) {
		ArchiveError(error, FlycutArchiveInvalidArgument, @"An archive path is required.");
		[self release]; return nil;
	}
	_path = [path copy];
	sqlite3 *database = NULL;
	int result = sqlite3_open_v2([path fileSystemRepresentation], &database,
		SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
	_database = database;
	if (result != SQLITE_OK) {
		ArchiveError(error, FlycutArchiveStorageError, @"Cannot open durable archive.");
		[self release]; return nil;
	}
	sqlite3_busy_timeout(database, 5000);
	sqlite3_create_function_v2(database, "flycut_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC,
		NULL, ContainsText, NULL, NULL, NULL);
	BOOL ok = [self execute:@"PRAGMA journal_mode=WAL" bindings:@[] error:error] &&
		[self execute:@"PRAGMA synchronous=FULL" bindings:@[] error:error] &&
		[self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error];
	if (ok) ok = [self execute:@"CREATE TABLE IF NOT EXISTS archive_meta (singleton INTEGER PRIMARY KEY CHECK(singleton=1), schema_version INTEGER NOT NULL, collection_id TEXT NOT NULL, device_id TEXT NOT NULL, local_clock INTEGER NOT NULL, revision INTEGER NOT NULL, migrated INTEGER NOT NULL DEFAULT 0, legacy_backup BLOB)" bindings:@[] error:error];
	if (ok) ok = [self execute:@"INSERT OR IGNORE INTO archive_meta(singleton,schema_version,collection_id,device_id,local_clock,revision) VALUES(1,1,?,?,0,0)"
		bindings:@[[[[NSUUID UUID] UUIDString] lowercaseString], [[[NSUUID UUID] UUIDString] lowercaseString]] error:error];
	if (ok) {
		sqlite3_stmt *statement = [self prepare:@"SELECT schema_version FROM archive_meta WHERE singleton=1" bindings:@[] error:error];
		ok = statement && sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1;
		sqlite3_finalize(statement);
		if (!ok) ArchiveError(error, FlycutArchiveStorageError, @"Unsupported archive schema.");
	}
	if (ok) ok = [self execute:@"CREATE TABLE IF NOT EXISTS events (ingest_seq INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE, device_id TEXT NOT NULL, clock INTEGER NOT NULL, op TEXT NOT NULL, item_id TEXT NOT NULL, json BLOB NOT NULL)" bindings:@[] error:error];
	if (ok) ok = [self execute:@"CREATE TABLE IF NOT EXISTS items (item_id TEXT PRIMARY KEY, text TEXT, content_type TEXT, captured_at_ms INTEGER, source_app TEXT, source_id TEXT, create_clock INTEGER, create_device TEXT, create_event TEXT, favorite INTEGER NOT NULL DEFAULT 0, favorite_clock INTEGER NOT NULL DEFAULT 0, favorite_device TEXT NOT NULL DEFAULT '', favorite_event TEXT NOT NULL DEFAULT '', recent_clock INTEGER NOT NULL DEFAULT 0, recent_device TEXT NOT NULL DEFAULT '', recent_event TEXT NOT NULL DEFAULT '', deleted INTEGER NOT NULL DEFAULT 0)" bindings:@[] error:error];
	if (ok) ok = [self execute:@"CREATE INDEX IF NOT EXISTS items_live_recent ON items(recent_clock DESC,recent_device DESC,recent_event DESC,item_id DESC) WHERE deleted=0 AND text IS NOT NULL" bindings:@[] error:error];
	if (ok) ok = [self execute:@"CREATE INDEX IF NOT EXISTS items_text ON items(text) WHERE deleted=0 AND text IS NOT NULL" bindings:@[] error:error];
	if (ok) ok = [self execute:@"CREATE TABLE IF NOT EXISTS checkpoints (backend TEXT PRIMARY KEY, upload_sequence INTEGER NOT NULL DEFAULT 0, download_cursor TEXT)" bindings:@[] error:error];
	if (![self finishTransaction:ok changed:NO error:error]) { [self release]; return nil; }
	return self;
}

- (void)dealloc {
	if (_database) sqlite3_close((sqlite3 *)_database);
	[_path release];
	[super dealloc];
}

- (sqlite3_stmt *)prepare:(NSString *)sql bindings:(NSArray *)bindings error:(NSError **)error {
	sqlite3_stmt *statement = NULL;
	int result = sqlite3_prepare_v2((sqlite3 *)_database, [sql UTF8String], -1, &statement, NULL);
	if (result == SQLITE_OK) {
		int index = 1;
		for (id value in bindings) {
			if (value == [NSNull null]) result = sqlite3_bind_null(statement, index);
			else if ([value isKindOfClass:[NSNumber class]]) result = sqlite3_bind_int64(statement, index, [value longLongValue]);
			else if ([value isKindOfClass:[NSData class]]) result = sqlite3_bind_blob(statement, index, [value bytes], (int)[value length], SQLITE_TRANSIENT);
			else {
				NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
				result = sqlite3_bind_text(statement, index, [value UTF8String], (int)[data length], SQLITE_TRANSIENT);
			}
			if (result != SQLITE_OK) break;
			index++;
		}
	}
	if (result != SQLITE_OK) {
		ArchiveError(error, FlycutArchiveStorageError, @"Archive statement failed.");
		sqlite3_finalize(statement); return NULL;
	}
	return statement;
}

- (BOOL)execute:(NSString *)sql bindings:(NSArray *)bindings error:(NSError **)error {
	sqlite3_stmt *statement = [self prepare:sql bindings:bindings error:error];
	if (!statement) return NO;
	int result;
	do { result = sqlite3_step(statement); } while (result == SQLITE_ROW);
	sqlite3_finalize(statement);
	return result == SQLITE_DONE || ArchiveError(error, FlycutArchiveStorageError, @"Durable archive write failed.");
}

- (BOOL)finishTransaction:(BOOL)success changed:(BOOL)changed error:(NSError **)error {
	if (success && changed) success = [self execute:@"UPDATE archive_meta SET revision=revision+1 WHERE singleton=1" bindings:@[] error:error];
	if (success) success = [self execute:@"COMMIT" bindings:@[] error:error];
	if (!success) [self execute:@"ROLLBACK" bindings:@[] error:NULL];
	if (success && changed) [[NSNotificationCenter defaultCenter] postNotificationName:FlycutArchiveDidChangeNotification object:self];
	return success;
}

- (NSDictionary *)metadata:(NSError **)error {
	sqlite3_stmt *statement = [self prepare:@"SELECT collection_id,device_id,local_clock,revision,migrated FROM archive_meta WHERE singleton=1" bindings:@[] error:error];
	if (!statement) return nil;
	NSDictionary *result = nil;
	if (sqlite3_step(statement) == SQLITE_ROW) result = @{@"collection_id": ColumnString(statement, 0), @"device_id": ColumnString(statement, 1),
		@"clock": @(sqlite3_column_int64(statement, 2)), @"revision": @(sqlite3_column_int64(statement, 3)), @"migrated": @(sqlite3_column_int(statement, 4))};
	else ArchiveError(error, FlycutArchiveStorageError, @"Archive metadata unavailable.");
	sqlite3_finalize(statement);
	return result;
}

- (NSString *)collectionID { @synchronized(self) { return [[[[self metadata:NULL] objectForKey:@"collection_id"] copy] autorelease]; } }
- (NSString *)deviceID { @synchronized(self) { return [[[[self metadata:NULL] objectForKey:@"device_id"] copy] autorelease]; } }
- (long long)revision { @synchronized(self) { return [[[self metadata:NULL] objectForKey:@"revision"] longLongValue]; } }

- (BOOL)insertEvent:(NSDictionary *)event changed:(BOOL *)changed error:(NSError **)error {
	if (![[self class] validateEvent:event error:error]) return NO;
	NSDictionary *meta = [self metadata:error];
	if (!meta) return NO;
	if (![[event objectForKey:@"collection_id"] isEqual:[meta objectForKey:@"collection_id"]])
		return ArchiveError(error, FlycutArchiveCollectionMismatch, @"Explicit collection adoption is required.");
	sqlite3_stmt *existing = [self prepare:@"SELECT json FROM events WHERE event_id=?" bindings:@[[event objectForKey:@"event_id"]] error:error];
	if (!existing) return NO;
	int result = sqlite3_step(existing);
	if (result == SQLITE_ROW) {
		NSDictionary *stored = [NSJSONSerialization JSONObjectWithData:ColumnData(existing, 0) options:0 error:error];
		BOOL same = [stored isEqual:event];
		sqlite3_finalize(existing);
		return same || ArchiveError(error, FlycutArchiveConflictingEvent, @"Conflicting reuse of an event ID.");
	}
	sqlite3_finalize(existing);
	if (result != SQLITE_DONE) return ArchiveError(error, FlycutArchiveStorageError, @"Cannot check event identity.");
	long long clock = 0;
	ParseClock([event objectForKey:@"clock"], &clock);
	NSData *json = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:error];
	if (!json) return NO;
	NSString *itemID = [event objectForKey:@"item_id"], *device = [event objectForKey:@"device_id"], *eventID = [event objectForKey:@"event_id"], *op = [event objectForKey:@"op"];
	NSDictionary *payload = [event objectForKey:@"payload"];
	if (![self execute:@"INSERT INTO events(event_id,device_id,clock,op,item_id,json) VALUES(?,?,?,?,?,?)" bindings:@[eventID, device, @(clock), op, itemID, json] error:error] ||
		![self execute:@"UPDATE archive_meta SET local_clock=MAX(local_clock,?) WHERE singleton=1" bindings:@[@(clock)] error:error] ||
		![self execute:@"INSERT OR IGNORE INTO items(item_id) VALUES(?)" bindings:@[itemID] error:error]) return NO;
	if ([op isEqual:@"create"]) {
		if (![self execute:@"UPDATE items SET text=?,content_type=?,captured_at_ms=?,source_app=?,source_id=?,create_clock=?,create_device=?,create_event=? WHERE item_id=?"
			bindings:@[[payload objectForKey:@"text"], [payload objectForKey:@"content_type"], [payload objectForKey:@"captured_at_ms"], [payload objectForKey:@"source_app"], [payload objectForKey:@"source_id"], @(clock), device, eventID, itemID] error:error]) return NO;
	}
	if ([op isEqual:@"create"] || [op isEqual:@"favorite"]) {
		NSNumber *value = [payload objectForKey:[op isEqual:@"create"] ? @"favorite" : @"value"];
		if (![self execute:@"UPDATE items SET favorite=?,favorite_clock=?,favorite_device=?,favorite_event=? WHERE item_id=? AND (favorite_clock,favorite_device,favorite_event)<(?,?,?)"
			bindings:@[value, @(clock), device, eventID, itemID, @(clock), device, eventID] error:error]) return NO;
	}
	if ([op isEqual:@"create"] || [op isEqual:@"touch"]) {
		if (![self execute:@"UPDATE items SET recent_clock=?,recent_device=?,recent_event=? WHERE item_id=? AND (recent_clock,recent_device,recent_event)<(?,?,?)"
			bindings:@[@(clock), device, eventID, itemID, @(clock), device, eventID] error:error]) return NO;
	}
	if ([op isEqual:@"delete"] && ![self execute:@"UPDATE items SET deleted=1 WHERE item_id=?" bindings:@[itemID] error:error]) return NO;
	if (changed) *changed = YES;
	return YES;
}

- (NSDictionary *)localEvent:(NSString *)operation itemID:(NSString *)itemID payload:(NSDictionary *)payload error:(NSError **)error {
	NSDictionary *meta = [self metadata:error];
	if (!meta) return nil;
	long long clock = [[meta objectForKey:@"clock"] longLongValue];
	if (clock == LLONG_MAX) { ArchiveError(error, FlycutArchiveClockExhausted, @"Archive clock exhausted."); return nil; }
	NSString *eventID = [[[NSUUID UUID] UUIDString] lowercaseString];
	return @{@"protocol": FlycutArchiveProtocol, @"version": @1, @"collection_id": [meta objectForKey:@"collection_id"],
		@"event_id": eventID, @"device_id": [meta objectForKey:@"device_id"], @"clock": [NSString stringWithFormat:@"%lld", clock + 1],
		@"op": operation, @"item_id": itemID ?: eventID, @"payload": payload};
}

- (NSDictionary *)captureText:(NSString *)text sourceApp:(NSString *)sourceApp sourceID:(NSString *)sourceID capturedAtMS:(NSNumber *)capturedAtMS favorite:(BOOL)favorite error:(NSError **)error {
	@synchronized(self) {
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return nil;
		NSDictionary *event = [self localEvent:@"create" itemID:nil payload:@{@"text": text ?: @"", @"content_type": @"text/plain",
			@"captured_at_ms": capturedAtMS ?: (id)[NSNull null], @"source_app": sourceApp ?: (id)[NSNull null],
			@"source_id": sourceID ?: (id)[NSNull null], @"favorite": @(favorite)} error:error];
		BOOL changed = NO;
		BOOL ok = event && [self insertEvent:event changed:&changed error:error];
		if (![self finishTransaction:ok changed:changed error:error]) return nil;
		return [self itemWithID:[event objectForKey:@"item_id"] error:error];
	}
}

- (NSDictionary *)itemFromStatement:(sqlite3_stmt *)statement {
	return @{@"item_id": ColumnString(statement, 0), @"text": ColumnString(statement, 1), @"content_type": ColumnString(statement, 2),
		@"captured_at_ms": sqlite3_column_type(statement, 3) == SQLITE_NULL ? (id)[NSNull null] : @(sqlite3_column_int64(statement, 3)),
		@"source_app": ColumnString(statement, 4) ?: (id)[NSNull null], @"source_id": ColumnString(statement, 5) ?: (id)[NSNull null],
		@"favorite": @(sqlite3_column_int(statement, 6) != 0), @"recent_clock": [NSString stringWithFormat:@"%lld", sqlite3_column_int64(statement, 7)],
		@"recent_device": ColumnString(statement, 8), @"recent_event": ColumnString(statement, 9)};
}

- (NSDictionary *)itemWithID:(NSString *)itemID error:(NSError **)error {
	@synchronized(self) {
		if (!UUIDIsValid(itemID)) { ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid item ID."); return nil; }
		sqlite3_stmt *statement = [self prepare:@"SELECT item_id,text,content_type,captured_at_ms,source_app,source_id,favorite,recent_clock,recent_device,recent_event FROM items WHERE item_id=? AND deleted=0 AND text IS NOT NULL" bindings:@[itemID] error:error];
		if (!statement) return nil;
		int result = sqlite3_step(statement);
		NSDictionary *item = result == SQLITE_ROW ? [self itemFromStatement:statement] : nil;
		if (result != SQLITE_ROW && result != SQLITE_DONE) ArchiveError(error, FlycutArchiveStorageError, @"Cannot read archive item.");
		sqlite3_finalize(statement);
		return item;
	}
}

- (BOOL)mutate:(NSString *)operation itemID:(NSString *)itemID payload:(NSDictionary *)payload error:(NSError **)error {
	@synchronized(self) {
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return NO;
		BOOL ok = [self itemWithID:itemID error:error] != nil;
		if (!ok && (!error || !*error)) ArchiveError(error, FlycutArchiveInvalidArgument, @"Item is not live in this archive.");
		NSDictionary *event = ok ? [self localEvent:operation itemID:itemID payload:payload error:error] : nil;
		BOOL changed = NO;
		ok = event && [self insertEvent:event changed:&changed error:error];
		return [self finishTransaction:ok changed:changed error:error];
	}
}

- (BOOL)setFavorite:(BOOL)favorite forItemID:(NSString *)itemID error:(NSError **)error { return [self mutate:@"favorite" itemID:itemID payload:@{@"value": @(favorite)} error:error]; }
- (BOOL)touchItemID:(NSString *)itemID error:(NSError **)error { return [self mutate:@"touch" itemID:itemID payload:@{} error:error]; }
- (BOOL)deleteItemID:(NSString *)itemID error:(NSError **)error { return [self mutate:@"delete" itemID:itemID payload:@{} error:error]; }

- (BOOL)clearHistory:(NSError **)error {
	@synchronized(self) {
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return NO;
		BOOL changed = NO, ok = YES;
		while (ok) {
			sqlite3_stmt *statement = [self prepare:@"SELECT item_id FROM items WHERE deleted=0 AND text IS NOT NULL AND favorite=0 LIMIT 1" bindings:@[] error:error];
			if (!statement) { ok = NO; break; }
			int result = sqlite3_step(statement);
			NSString *itemID = [ColumnString(statement, 0) retain];
			sqlite3_finalize(statement);
			if (result == SQLITE_DONE) { [itemID release]; break; }
			if (result != SQLITE_ROW) { [itemID release]; ok = ArchiveError(error, FlycutArchiveStorageError, @"Cannot enumerate clear-history items."); break; }
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSDictionary *event = [self localEvent:@"delete" itemID:itemID payload:@{} error:error];
			ok = event && [self insertEvent:event changed:&changed error:error];
			DrainPool(pool, ok ? NULL : error);
			[itemID release];
		}
		return [self finishTransaction:ok changed:changed error:error];
	}
}

- (NSDictionary *)searchText:(NSString *)query favoritesOnly:(BOOL)favoritesOnly groupDuplicates:(BOOL)groupDuplicates limit:(NSUInteger)limit cursor:(NSDictionary *)cursor error:(NSError **)error {
	@synchronized(self) {
		query = query ?: @"";
		if (![query isKindOfClass:[NSString class]] || limit < 1 || limit > 1000) { ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid query or page limit."); return nil; }
		if (![self execute:@"BEGIN" bindings:@[] error:error]) return nil;
		NSDictionary *meta = [self metadata:error];
		BOOL ok = meta != nil;
		long long revision = [[meta objectForKey:@"revision"] longLongValue];
		if (ok && cursor) {
			ok = HasKeys(cursor, @[@"query", @"favorites", @"duplicates", @"revision", @"collection_id", @"clock", @"device", @"event", @"item"]) &&
				[[cursor objectForKey:@"query"] isEqual:query] && IsBoolean([cursor objectForKey:@"favorites"]) &&
				[[cursor objectForKey:@"favorites"] boolValue] == favoritesOnly && IsBoolean([cursor objectForKey:@"duplicates"]) &&
				[[cursor objectForKey:@"duplicates"] boolValue] == groupDuplicates && IsInteger([cursor objectForKey:@"revision"]) &&
				[[cursor objectForKey:@"revision"] longLongValue] == revision && [[cursor objectForKey:@"collection_id"] isEqual:[meta objectForKey:@"collection_id"]] &&
				ParseClock([cursor objectForKey:@"clock"], NULL) && UUIDIsValid([cursor objectForKey:@"device"]) &&
				UUIDIsValid([cursor objectForKey:@"event"]) && UUIDIsValid([cursor objectForKey:@"item"]);
			if (!ok) ArchiveError(error, FlycutArchiveStaleCursor, @"Archive or query changed; restart search.");
		}
		NSMutableString *sql = [NSMutableString stringWithString:@"SELECT i.item_id,i.text,i.content_type,i.captured_at_ms,i.source_app,i.source_id,i.favorite,i.recent_clock,i.recent_device,i.recent_event FROM items i WHERE i.deleted=0 AND i.text IS NOT NULL AND flycut_contains(i.text,?)"];
		NSMutableArray *bindings = [NSMutableArray arrayWithObject:query];
		if (favoritesOnly) [sql appendString:@" AND i.favorite=1"];
		if (groupDuplicates) {
			[sql appendString:@" AND NOT EXISTS(SELECT 1 FROM items n WHERE n.deleted=0 AND n.text=i.text AND (n.recent_clock,n.recent_device,n.recent_event,n.item_id)>(i.recent_clock,i.recent_device,i.recent_event,i.item_id)"];
			if (favoritesOnly) [sql appendString:@" AND n.favorite=1"];
			[sql appendString:@")"];
		}
		if (cursor && ok) {
			long long clock = 0; ParseClock([cursor objectForKey:@"clock"], &clock);
			[sql appendString:@" AND (i.recent_clock,i.recent_device,i.recent_event,i.item_id)<(?,?,?,?)"];
			[bindings addObjectsFromArray:@[@(clock), [cursor objectForKey:@"device"], [cursor objectForKey:@"event"], [cursor objectForKey:@"item"]]];
		}
		[sql appendString:@" ORDER BY i.recent_clock DESC,i.recent_device DESC,i.recent_event DESC,i.item_id DESC LIMIT ?"];
		[bindings addObject:@(limit + 1)];
		sqlite3_stmt *statement = ok ? [self prepare:sql bindings:bindings error:error] : NULL;
		ok = ok && statement != NULL;
		NSMutableArray *items = [NSMutableArray array];
		if (ok) {
			int result;
			while ((result = sqlite3_step(statement)) == SQLITE_ROW) [items addObject:[self itemFromStatement:statement]];
			if (result != SQLITE_DONE) ok = ArchiveError(error, FlycutArchiveStorageError, @"Archive search failed.");
		}
		sqlite3_finalize(statement);
		if (![self finishTransaction:ok changed:NO error:error]) return nil;
		BOOL more = [items count] > limit;
		if (more) [items removeLastObject];
		id next = [NSNull null];
		if (more) {
			NSDictionary *last = [items lastObject];
			next = @{@"query": query, @"favorites": @(favoritesOnly), @"duplicates": @(groupDuplicates), @"revision": @(revision),
				@"collection_id": [meta objectForKey:@"collection_id"], @"clock": [last objectForKey:@"recent_clock"],
				@"device": [last objectForKey:@"recent_device"], @"event": [last objectForKey:@"recent_event"], @"item": [last objectForKey:@"item_id"]};
		}
		return @{@"items": items, @"next_cursor": next, @"has_more": @(more), @"revision": @(revision)};
	}
}

- (NSDictionary *)eventsAfterSequence:(long long)sequence limit:(NSUInteger)limit error:(NSError **)error {
	@synchronized(self) {
		if (sequence < 0 || limit < 1 || limit > 1000) { ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid event page bounds."); return nil; }
		sqlite3_stmt *statement = [self prepare:@"SELECT ingest_seq,json FROM events WHERE ingest_seq>? ORDER BY ingest_seq LIMIT ?" bindings:@[@(sequence), @(limit + 1)] error:error];
		if (!statement) return nil;
		NSMutableArray *events = [NSMutableArray array];
		long long next = sequence;
		int result; BOOL more = NO, ok = YES;
		while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
			if ([events count] == limit) { more = YES; break; }
			NSDictionary *event = [NSJSONSerialization JSONObjectWithData:ColumnData(statement, 1) options:0 error:error];
			if (!event) { ok = NO; break; }
			[events addObject:event]; next = sqlite3_column_int64(statement, 0);
		}
		if (ok && result != SQLITE_ROW && result != SQLITE_DONE) ok = ArchiveError(error, FlycutArchiveStorageError, @"Cannot export events.");
		sqlite3_finalize(statement);
		return ok ? @{@"events": events, @"next_sequence": @(next), @"has_more": @(more)} : nil;
	}
}

- (BOOL)ingestEvents:(NSArray *)events backend:(NSString *)backend checkpoint:(NSString *)checkpoint error:(NSError **)error {
	@synchronized(self) {
		if (![events isKindOfClass:[NSArray class]] || [events count] > 1000 ||
			(backend && (![backend isKindOfClass:[NSString class]] || [backend length] == 0)) ||
			(checkpoint && (![checkpoint isKindOfClass:[NSString class]] || !backend)))
			return ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid event batch or backend checkpoint.");
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return NO;
		BOOL changed = NO, ok = YES;
		for (NSDictionary *event in events) { if (!(ok = [self insertEvent:event changed:&changed error:error])) break; }
		if (ok && backend) ok = [self execute:@"INSERT OR IGNORE INTO checkpoints(backend) VALUES(?)" bindings:@[backend] error:error] &&
			[self execute:@"UPDATE checkpoints SET download_cursor=? WHERE backend=?" bindings:@[checkpoint ?: (id)[NSNull null], backend] error:error];
		return [self finishTransaction:ok changed:changed error:error];
	}
}

- (NSDictionary *)checkpointForBackend:(NSString *)backend error:(NSError **)error {
	@synchronized(self) {
		if (![backend isKindOfClass:[NSString class]] || [backend length] == 0) { ArchiveError(error, FlycutArchiveInvalidArgument, @"Backend name required."); return nil; }
		sqlite3_stmt *statement = [self prepare:@"SELECT upload_sequence,download_cursor FROM checkpoints WHERE backend=?" bindings:@[backend] error:error];
		if (!statement) return nil;
		int result = sqlite3_step(statement);
		NSDictionary *checkpoint = nil;
		if (result == SQLITE_ROW) checkpoint = @{@"upload_sequence": @(sqlite3_column_int64(statement, 0)), @"download_cursor": ColumnString(statement, 1) ?: (id)[NSNull null]};
		else if (result == SQLITE_DONE) checkpoint = @{@"upload_sequence": @0, @"download_cursor": [NSNull null]};
		else ArchiveError(error, FlycutArchiveStorageError, @"Cannot read backend checkpoint.");
		sqlite3_finalize(statement); return checkpoint;
	}
}

- (BOOL)acknowledgeUploadThroughSequence:(long long)sequence backend:(NSString *)backend error:(NSError **)error {
	@synchronized(self) {
		if (sequence < 0 || ![backend isKindOfClass:[NSString class]] || [backend length] == 0)
			return ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid upload acknowledgement.");
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return NO;
		sqlite3_stmt *statement = [self prepare:@"SELECT COALESCE(MAX(ingest_seq),0) FROM events" bindings:@[] error:error];
		BOOL ok = statement && sqlite3_step(statement) == SQLITE_ROW;
		if (ok && sequence > sqlite3_column_int64(statement, 0)) ok = ArchiveError(error, FlycutArchiveInvalidArgument, @"Acknowledgement exceeds exported events.");
		sqlite3_finalize(statement);
		if (ok) ok = [self execute:@"INSERT OR IGNORE INTO checkpoints(backend) VALUES(?)" bindings:@[backend] error:error] &&
			[self execute:@"UPDATE checkpoints SET upload_sequence=MAX(upload_sequence,?) WHERE backend=?" bindings:@[@(sequence), backend] error:error];
		return [self finishTransaction:ok changed:NO error:error];
	}
}

- (BOOL)resetCheckpointForBackend:(NSString *)backend error:(NSError **)error {
	@synchronized(self) {
		if (![backend isKindOfClass:[NSString class]] || [backend length] == 0) return ArchiveError(error, FlycutArchiveInvalidArgument, @"Backend name required.");
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return NO;
		return [self finishTransaction:[self execute:@"DELETE FROM checkpoints WHERE backend=?" bindings:@[backend] error:error] changed:NO error:error];
	}
}

- (BOOL)adoptCollectionID:(NSString *)collectionID sharingExistingEvents:(BOOL)share error:(NSError **)error {
	@synchronized(self) {
		if (!UUIDIsValid(collectionID)) return ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid collection ID.");
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return NO;
		NSDictionary *meta = [self metadata:error];
		BOOL ok = meta != nil, changed = ![[meta objectForKey:@"collection_id"] isEqual:collectionID];
		sqlite3_stmt *statement = ok ? [self prepare:@"SELECT COUNT(*) FROM events" bindings:@[] error:error] : NULL;
		ok = ok && statement && sqlite3_step(statement) == SQLITE_ROW;
		if (ok && changed && !share && sqlite3_column_int64(statement, 0) != 0)
			ok = ArchiveError(error, FlycutArchiveCollectionMismatch, @"Sharing existing events requires an explicit decision.");
		sqlite3_finalize(statement);
		long long sequence = 0;
		while (ok && changed) {
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			statement = [self prepare:@"SELECT ingest_seq,json FROM events WHERE ingest_seq>? ORDER BY ingest_seq LIMIT 1" bindings:@[@(sequence)] error:error];
			if (!statement) { ok = NO; DrainPool(pool, error); break; }
			int result = sqlite3_step(statement);
			if (result == SQLITE_DONE) { sqlite3_finalize(statement); DrainPool(pool, NULL); break; }
			if (result != SQLITE_ROW) { sqlite3_finalize(statement); ok = ArchiveError(error, FlycutArchiveStorageError, @"Cannot adopt retained events."); DrainPool(pool, error); break; }
			sequence = sqlite3_column_int64(statement, 0);
			NSMutableDictionary *event = [[NSJSONSerialization JSONObjectWithData:ColumnData(statement, 1) options:NSJSONReadingMutableContainers error:error] retain];
			sqlite3_finalize(statement);
			if (!event) { ok = NO; DrainPool(pool, error); break; }
			[event setObject:collectionID forKey:@"collection_id"];
			NSData *json = [NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:error];
			[event release];
			ok = json && [self execute:@"UPDATE events SET json=? WHERE ingest_seq=?" bindings:@[json, @(sequence)] error:error];
			DrainPool(pool, ok ? NULL : error);
		}
		if (ok && changed) ok = [self execute:@"UPDATE archive_meta SET collection_id=? WHERE singleton=1" bindings:@[collectionID] error:error] &&
			[self execute:@"DELETE FROM checkpoints" bindings:@[] error:error];
		return [self finishTransaction:ok changed:changed error:error];
	}
}

- (NSDictionary *)legacyDefaultsBackup:(NSError **)error {
	@synchronized(self) {
		sqlite3_stmt *statement = [self prepare:@"SELECT legacy_backup FROM archive_meta WHERE singleton=1" bindings:@[] error:error];
		if (!statement) return nil;
		NSDictionary *backup = nil;
		if (sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_type(statement, 0) != SQLITE_NULL)
			backup = [NSPropertyListSerialization propertyListWithData:ColumnData(statement, 0) options:NSPropertyListImmutable format:NULL error:error];
		sqlite3_finalize(statement); return backup;
	}
}

- (NSArray *)legacyTuple:(NSDictionary *)clip {
	NSMutableArray *tuple = [NSMutableArray array];
	for (NSString *key in @[@"Contents", @"Type", @"Timestamp", @"AppLocalizedName", @"AppBundleURL"])
		[tuple addObject:[clip objectForKey:key] ?: (id)[NSNull null]];
	return tuple;
}

- (NSDictionary *)legacyPayload:(NSDictionary *)clip favorite:(BOOL)favorite error:(NSError **)error {
	if (![clip isKindOfClass:[NSDictionary class]] || ![[clip objectForKey:@"Contents"] isKindOfClass:[NSString class]] ||
		[[clip objectForKey:@"Contents"] length] == 0 || ![[clip objectForKey:@"Contents"] dataUsingEncoding:NSUTF8StringEncoding] ||
		![[clip objectForKey:@"Type"] isKindOfClass:[NSString class]] ||
		!NullableString([clip objectForKey:@"AppLocalizedName"] ?: (id)[NSNull null]) ||
		!NullableString([clip objectForKey:@"AppBundleURL"] ?: (id)[NSNull null])) {
		ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid legacy clipping; original defaults remain untouched."); return nil;
	}
	id seconds = [clip objectForKey:@"Timestamp"];
	NSNumber *milliseconds = nil;
	if (seconds) {
		if (!IsInteger(seconds) || [seconds longLongValue] > LLONG_MAX / 1000 || [seconds longLongValue] < LLONG_MIN / 1000) {
			ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid legacy timestamp."); return nil;
		}
		milliseconds = @([seconds longLongValue] * 1000);
	}
	return @{@"text": [clip objectForKey:@"Contents"], @"content_type": @"text/plain",
		@"captured_at_ms": milliseconds ?: (id)[NSNull null], @"source_app": [clip objectForKey:@"AppLocalizedName"] ?: (id)[NSNull null],
		@"source_id": [clip objectForKey:@"AppBundleURL"] ?: (id)[NSNull null], @"favorite": @(favorite)};
}

- (NSDictionary *)legacyCreate:(NSDictionary *)clip favorite:(BOOL)favorite error:(NSError **)error {
	NSDictionary *payload = [self legacyPayload:clip favorite:favorite error:error];
	return payload ? [self localEvent:@"create" itemID:nil payload:payload error:error] : nil;
}

- (BOOL)migrateLegacyDefaults:(NSDictionary *)defaults error:(NSError **)error {
	@synchronized(self) {
		if (![defaults isKindOfClass:[NSDictionary class]]) return ArchiveError(error, FlycutArchiveInvalidArgument, @"Raw legacy defaults dictionary required.");
		if (![self execute:@"BEGIN IMMEDIATE" bindings:@[] error:error]) return NO;
		NSDictionary *meta = [self metadata:error];
		if (!meta) return [self finishTransaction:NO changed:NO error:error];
		if ([[meta objectForKey:@"migrated"] boolValue]) return [self finishTransaction:YES changed:NO error:error];
		NSData *backup = [NSPropertyListSerialization dataWithPropertyList:defaults format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
		id store = [defaults objectForKey:@"store"] ?: @{};
		id history = [store isKindOfClass:[NSDictionary class]] ? ([store objectForKey:@"jcList"] ?: @[]) : nil;
		id favorites = [store isKindOfClass:[NSDictionary class]] ? ([store objectForKey:@"favoritesList"] ?: @[]) : nil;
		BOOL ok = backup && [history isKindOfClass:[NSArray class]] && [favorites isKindOfClass:[NSArray class]], changed = NO;
		if (!ok) ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid raw legacy store; migration was not committed.");
		NSMutableDictionary *favoriteCounts = [NSMutableDictionary dictionary];
		if (ok) for (id clip in favorites) {
			if (![self legacyPayload:clip favorite:YES error:error]) { ok = NO; break; }
			NSArray *tuple = [self legacyTuple:clip];
			[favoriteCounts setObject:@([[favoriteCounts objectForKey:tuple] unsignedIntegerValue] + 1) forKey:tuple];
		}
		NSMutableDictionary *matchedCounts = [NSMutableDictionary dictionary];
		if (ok) for (id clip in [history reverseObjectEnumerator]) {
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			if (![clip isKindOfClass:[NSDictionary class]]) { ok = ArchiveError(error, FlycutArchiveInvalidArgument, @"Invalid legacy history entry."); DrainPool(pool, error); break; }
			NSArray *tuple = [self legacyTuple:clip];
			NSUInteger remaining = [[favoriteCounts objectForKey:tuple] unsignedIntegerValue];
			BOOL favorite = remaining > 0;
			NSDictionary *event = [self legacyCreate:clip favorite:favorite error:error];
			ok = event && [self insertEvent:event changed:&changed error:error];
			if (!ok) { DrainPool(pool, error); break; }
			if (favorite) {
				[favoriteCounts setObject:@(remaining - 1) forKey:tuple];
				[matchedCounts setObject:@([[matchedCounts objectForKey:tuple] unsignedIntegerValue] + 1) forKey:tuple];
			}
			DrainPool(pool, ok ? NULL : error);
		}
		if (ok) for (id clip in [favorites reverseObjectEnumerator]) {
			NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
			NSArray *tuple = [self legacyTuple:clip];
			NSUInteger matched = [[matchedCounts objectForKey:tuple] unsignedIntegerValue];
			if (matched > 0) { [matchedCounts setObject:@(matched - 1) forKey:tuple]; DrainPool(pool, NULL); continue; }
			NSDictionary *event = [self legacyCreate:clip favorite:YES error:error];
			ok = event && [self insertEvent:event changed:&changed error:error];
			DrainPool(pool, ok ? NULL : error);
			if (!ok) break;
		}
		if (ok) ok = [self execute:@"UPDATE archive_meta SET migrated=1,legacy_backup=? WHERE singleton=1" bindings:@[backup] error:error];
		return [self finishTransaction:ok changed:changed error:error];
	}
}

@end
