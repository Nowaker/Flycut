#import <Foundation/Foundation.h>
#import "../FlycutArchive.h"
#import <sqlite3.h>

static void Require(BOOL condition, NSString *message) {
	if (!condition) { fprintf(stderr, "FAIL: %s\n", [message UTF8String]); exit(1); }
}

static FlycutArchive *Open(NSString *path) {
	NSError *error = nil;
	FlycutArchive *archive = [[[FlycutArchive alloc] initWithPath:path error:&error] autorelease];
	Require(archive != nil, [NSString stringWithFormat:@"open archive: %@", error]);
	return archive;
}

static NSDictionary *Page(FlycutArchive *archive, NSString *query, BOOL favorites, BOOL duplicates, NSUInteger limit, NSDictionary *cursor) {
	NSError *error = nil;
	NSDictionary *page = [archive searchText:query favoritesOnly:favorites groupDuplicates:duplicates limit:limit cursor:cursor error:&error];
	Require(page != nil, [NSString stringWithFormat:@"query archive: %@", error]);
	return page;
}

static NSDictionary *Capture(FlycutArchive *archive, NSString *text, BOOL favorite) {
	NSError *error = nil;
	NSDictionary *item = [archive captureText:text sourceApp:@"Synthetic" sourceID:@"test.app" capturedAtMS:@123000 favorite:favorite error:&error];
	Require(item != nil, [NSString stringWithFormat:@"capture: %@", error]);
	return item;
}

static NSUInteger EventCount(FlycutArchive *archive) {
	NSUInteger count = 0;
	long long sequence = 0;
	while (YES) {
		NSDictionary *page = [archive eventsAfterSequence:sequence limit:200 error:NULL];
		Require(page != nil, @"bounded export");
		count += [[page objectForKey:@"events"] count];
		sequence = [[page objectForKey:@"next_sequence"] longLongValue];
		if (![[page objectForKey:@"has_more"] boolValue]) break;
	}
	return count;
}

static void FixtureSQL(NSString *path, const char *sql) {
	sqlite3 *database = NULL;
	Require(sqlite3_open([path fileSystemRepresentation], &database) == SQLITE_OK, @"open isolated failure-injection connection");
	Require(sqlite3_exec(database, sql, NULL, NULL, NULL) == SQLITE_OK, @"install or remove isolated failure injection");
	sqlite3_close(database);
}

@interface CommitProbe : NSObject {
@public
	NSString *path;
	NSUInteger notifications;
}
- (void)changed:(NSNotification *)notification;
@end
@implementation CommitProbe
- (void)changed:(NSNotification *)notification {
	notifications++;
	FlycutArchive *reader = [[FlycutArchive alloc] initWithPath:path error:NULL];
	Require(reader != nil, @"notification can independently reopen committed database");
	Require([reader revision] == [(FlycutArchive *)[notification object] revision], @"notification only after durable revision visible");
	[reader release];
}
@end

static void RunFixtures(NSDictionary *fixtures) {
	NSUInteger deliveries = 0;
	for (NSDictionary *test in [fixtures objectForKey:@"cases"]) {
		NSArray *events = [test objectForKey:@"events"];
		NSMutableArray *orders = [NSMutableArray arrayWithArray:[test objectForKey:@"deliveries"]];
		for (NSUInteger seed = 1; seed <= 32; seed++) {
			NSMutableArray *order = [NSMutableArray array];
			for (NSUInteger i = 0; i < [events count]; i++) [order addObject:@(i)];
			uint32_t state = (uint32_t)seed;
			for (NSUInteger i = [order count] - 1; i > 0; i--) {
				state = state * 1664525u + 1013904223u;
				[order exchangeObjectAtIndex:i withObjectAtIndex:state % (i + 1)];
			}
			[orders addObject:order];
		}
		for (NSArray *order in orders) {
			@autoreleasepool {
				FlycutArchive *archive = Open(@":memory:");
				Require([archive adoptCollectionID:[fixtures objectForKey:@"collection_id"] sharingExistingEvents:NO error:NULL], @"fixture explicit collection adoption");
				for (NSNumber *index in order) Require([archive ingestEvents:@[[events objectAtIndex:[index unsignedIntegerValue]]] backend:nil checkpoint:nil error:NULL], @"fixture event accepted");
				Require([[Page(archive, @"", NO, NO, 1000, nil) objectForKey:@"items"] isEqual:[test objectForKey:@"expected_items"]], [test objectForKey:@"name"]);
				for (NSString *itemID in [test objectForKey:@"expected_hidden_ids"]) Require([archive itemWithID:itemID error:NULL] == nil, @"permanent deletion");
				Require(EventCount(archive) == [[test objectForKey:@"expected_event_count"] unsignedIntegerValue], @"idempotent replay emits no derived events");
				long long revision = [archive revision];
				Require([archive ingestEvents:events backend:@"fixture" checkpoint:@"replayed" error:NULL], @"equivalent full replay");
				Require([archive revision] == revision, @"replay preserves revision");
				deliveries++;
			}
		}
	}
	for (NSDictionary *variant in [fixtures objectForKey:@"invalid_variants"]) {
		NSDictionary *test = [[fixtures objectForKey:@"cases"] objectAtIndex:[[variant objectForKey:@"base_case"] unsignedIntegerValue]];
		NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:[[test objectForKey:@"events"] objectAtIndex:[[variant objectForKey:@"base_event"] unsignedIntegerValue]]];
		[event addEntriesFromDictionary:[variant objectForKey:@"replace"] ?: @{}];
		NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:[event objectForKey:@"payload"]];
		[payload addEntriesFromDictionary:[variant objectForKey:@"payload_replace"] ?: @{}];
		[event setObject:payload forKey:@"payload"];
		NSError *error = nil;
		Require(![FlycutArchive validateEvent:event error:&error] && [error code] == FlycutArchiveInvalidEvent, [variant objectForKey:@"name"]);
	}
	printf("PASS portable fixtures: %lu delivery orders, %lu invalid variants\n", (unsigned long)deliveries, (unsigned long)[[fixtures objectForKey:@"invalid_variants"] count]);
}

static void RunStorage(NSString *directory, NSDictionary *fixtures) {
	NSString *path = [directory stringByAppendingPathComponent:@"storage.sqlite"];
	FlycutArchive *archive = [[FlycutArchive alloc] initWithPath:path error:NULL];
	Require(archive != nil, @"file archive creation");
	CommitProbe *probe = [[[CommitProbe alloc] init] autorelease]; probe->path = path;
	[[NSNotificationCenter defaultCenter] addObserver:probe selector:@selector(changed:) name:FlycutArchiveDidChangeNotification object:archive];
	NSString *collection = [[archive collectionID] copy], *device = [[archive deviceID] copy];
	NSDictionary *first = Capture(archive, @"first", NO);
	NSDictionary *favorite = Capture(archive, @"favorite", YES);
	NSDictionary *duplicate = Capture(archive, @"first", NO);
	Require(![[first objectForKey:@"item_id"] isEqual:[duplicate objectForKey:@"item_id"]], @"separate copies have separate IDs");
	Require([[Page(archive, @"FIRST", NO, NO, 5, nil) objectForKey:@"items"] count] == 2, @"case-insensitive substring");
	Require([[[Page(archive, @"first", NO, YES, 5, nil) objectForKey:@"items"] firstObject] isEqual:duplicate], @"duplicate representative newest");
	NSDictionary *cursor = [Page(archive, @"", NO, NO, 1, nil) objectForKey:@"next_cursor"];
	Require([[Page(archive, @"", NO, NO, 1, cursor) objectForKey:@"items"] count] == 1, @"keyset next page");
	NSError *error = nil;
	Require([archive searchText:@"changed" favoritesOnly:NO groupDuplicates:NO limit:1 cursor:cursor error:&error] == nil && [error code] == FlycutArchiveStaleCursor, @"cursor bound to query");
	Require([archive touchItemID:[first objectForKey:@"item_id"] error:NULL], @"touch mutation");
	error = nil;
	Require([archive searchText:@"" favoritesOnly:NO groupDuplicates:NO limit:1 cursor:cursor error:&error] == nil && [error code] == FlycutArchiveStaleCursor, @"revision invalidation");
	Require([[[[Page(archive, @"", NO, NO, 1, nil) objectForKey:@"items"] firstObject] objectForKey:@"item_id"] isEqual:[first objectForKey:@"item_id"]], @"touch moves newest by stamp");
	Require([archive setFavorite:YES forItemID:[first objectForKey:@"item_id"] error:NULL], @"favorite mutation");
	Require([archive clearHistory:NULL], @"clear known nonfavorites transaction");
	Require([[Page(archive, @"", NO, NO, 100, nil) objectForKey:@"items"] count] == 2, @"favorites survive clear");
	Require([archive itemWithID:[duplicate objectForKey:@"item_id"] error:NULL] == nil, @"clear tombstone hides representative");
	Require([archive deleteItemID:[favorite objectForKey:@"item_id"] error:NULL], @"delete favorite explicitly");
	NSString *literal = @"%_ Straße 😀\0tail";
	NSDictionary *exact = Capture(archive, literal, NO);
	Require([[exact objectForKey:@"text"] isEqual:literal], @"full exact Unicode and embedded NUL text");
	Require([[Page(archive, @"%_", NO, NO, 10, nil) objectForKey:@"items"] count] == 1, @"literal SQL metacharacters");
	Require([[Page(archive, @"TAIL", NO, NO, 10, nil) objectForKey:@"items"] count] == 1, @"search after embedded NUL");
	NSDictionary *fixtureEvent = [[[[fixtures objectForKey:@"cases"] firstObject] objectForKey:@"events"] firstObject];
	NSMutableDictionary *newEvent = [NSMutableDictionary dictionaryWithDictionary:fixtureEvent]; [newEvent setObject:collection forKey:@"collection_id"];
	NSUInteger failedCount = EventCount(archive), failedNotifications = probe->notifications;
	long long failedRevision = [archive revision];
	NSArray *previousEvents = [[archive eventsAfterSequence:0 limit:1000 error:NULL] objectForKey:@"events"];
	long long previousClock = [[[[previousEvents lastObject] objectForKey:@"clock"] description] longLongValue];
	FixtureSQL(path, "CREATE TRIGGER force_finish_failure BEFORE UPDATE OF revision ON archive_meta BEGIN SELECT RAISE(ABORT,'synthetic transaction-finish failure'); END");
	error = nil;
	Require(![archive ingestEvents:@[newEvent] backend:@"service" checkpoint:@"lost" error:&error] && [error code] == FlycutArchiveStorageError, @"transaction finish failure reports storage error");
	Require(EventCount(archive) == failedCount && [archive revision] == failedRevision && probe->notifications == failedNotifications, @"transaction finish failure rolls back reducer events revision notifications");
	Require([archive itemWithID:[newEvent objectForKey:@"item_id"] error:NULL] == nil && [[[archive checkpointForBackend:@"service" error:NULL] objectForKey:@"download_cursor"] isEqual:[NSNull null]], @"transaction finish failure rolls back materialization and checkpoint");
	FixtureSQL(path, "DROP TRIGGER force_finish_failure");
	Require([archive touchItemID:[exact objectForKey:@"item_id"] error:NULL], @"write recovers after failed transaction finish");
	NSArray *recoveredEvents = [[archive eventsAfterSequence:0 limit:1000 error:NULL] objectForKey:@"events"];
	Require([[[recoveredEvents lastObject] objectForKey:@"clock"] longLongValue] == previousClock + 1, @"failed transaction did not advance local clock");
	NSUInteger before = EventCount(archive);
	long long revision = [archive revision];
	NSUInteger notifications = probe->notifications;
	NSArray *exported = [[archive eventsAfterSequence:0 limit:1000 error:NULL] objectForKey:@"events"];
	NSMutableDictionary *conflict = [NSMutableDictionary dictionaryWithDictionary:[exported firstObject]];
	NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:[conflict objectForKey:@"payload"]];
	[payload setObject:@"different content" forKey:@"text"]; [conflict setObject:payload forKey:@"payload"];
	error = nil;
	Require(![archive ingestEvents:@[newEvent, conflict] backend:@"service" checkpoint:@"must-not-advance" error:&error] && [error code] == FlycutArchiveConflictingEvent, @"conflicting reuse rejects whole batch");
	Require(EventCount(archive) == before && [archive revision] == revision && probe->notifications == notifications, @"failed import rolls back events revision and notifications");
	Require([[[archive checkpointForBackend:@"service" error:NULL] objectForKey:@"download_cursor"] isEqual:[NSNull null]], @"failed import rolls back checkpoint");
	Require([archive ingestEvents:@[newEvent] backend:@"service" checkpoint:@"next" error:NULL], @"late low-clock upload ingestion");
	NSDictionary *late = [archive eventsAfterSequence:(long long)before limit:1 error:NULL];
	Require([[[late objectForKey:@"events"] firstObject] isEqual:newEvent], @"export insertion sequence delivers lower-clock event");
	Require([archive acknowledgeUploadThroughSequence:(long long)before backend:@"service" error:NULL], @"independent upload ack");
	Require([[[archive checkpointForBackend:@"service" error:NULL] objectForKey:@"download_cursor"] isEqual:@"next"], @"upload does not replace download cursor");
	Require([archive resetCheckpointForBackend:@"folder" error:NULL], @"reset separate backend");
	error = nil;
	Require(![archive ingestEvents:@[fixtureEvent] backend:nil checkpoint:nil error:&error] && [error code] == FlycutArchiveCollectionMismatch, @"no implicit collection merge");
	error = nil;
	Require(![archive adoptCollectionID:[fixtures objectForKey:@"collection_id"] sharingExistingEvents:NO error:&error], @"nonempty adoption requires explicit sharing");
	NSArray *beforeShare = [[archive eventsAfterSequence:0 limit:1000 error:NULL] objectForKey:@"events"];
	Require([archive adoptCollectionID:[fixtures objectForKey:@"collection_id"] sharingExistingEvents:YES error:NULL], @"transactional explicit share");
	Require(EventCount(archive) == before + 1 && [[archive deviceID] isEqual:device], @"sharing preserves events and device");
	Require([[[archive checkpointForBackend:@"service" error:NULL] objectForKey:@"upload_sequence"] longLongValue] == 0, @"sharing resets acknowledgements");
	Require([[[archive checkpointForBackend:@"service" error:NULL] objectForKey:@"download_cursor"] isEqual:[NSNull null]], @"sharing resets download cursor");
	NSArray *afterShare = [[archive eventsAfterSequence:0 limit:1000 error:NULL] objectForKey:@"events"];
	for (NSUInteger index = 0; index < [afterShare count]; index++) {
		NSDictionary *event = [afterShare objectAtIndex:index];
		NSMutableDictionary *expected = [NSMutableDictionary dictionaryWithDictionary:[beforeShare objectAtIndex:index]];
		[expected setObject:[fixtures objectForKey:@"collection_id"] forKey:@"collection_id"];
		Require([event isEqual:expected], @"sharing preserves exact IDs content metadata and stamps");
		Require([[event objectForKey:@"collection_id"] isEqual:[fixtures objectForKey:@"collection_id"]], @"sharing relabels every envelope");
		Require([FlycutArchive validateEvent:event error:NULL], @"shared envelope remains valid");
	}
	[[NSNotificationCenter defaultCenter] removeObserver:probe];
	[archive release];
	archive = [[FlycutArchive alloc] initWithPath:path error:NULL];
	Require(archive != nil && [[archive deviceID] isEqual:device] && EventCount(archive) == before + 1, @"restart durable IDs events checkpoints");
	Require([[archive itemWithID:[exact objectForKey:@"item_id"] error:NULL] objectForKey:@"text"] != nil, @"restart materialized content");
	[archive release]; [collection release]; [device release];
	FlycutArchive *overflow = Open(@":memory:");
	Require([overflow adoptCollectionID:[fixtures objectForKey:@"collection_id"] sharingExistingEvents:NO error:NULL], @"overflow collection");
	NSMutableDictionary *maxEvent = [NSMutableDictionary dictionaryWithDictionary:fixtureEvent]; [maxEvent setObject:@"9223372036854775807" forKey:@"clock"];
	Require([overflow ingestEvents:@[maxEvent] backend:nil checkpoint:nil error:NULL], @"maximum clock accepted");
	error = nil;
	Require([overflow captureText:@"not inserted" sourceApp:nil sourceID:nil capturedAtMS:nil favorite:NO error:&error] == nil && [error code] == FlycutArchiveClockExhausted, @"clock overflow rolls back without fallback");
	Require(EventCount(overflow) == 1, @"clock exhaustion no partial insertion");
	error = nil;
	FlycutArchive *bad = [[FlycutArchive alloc] initWithPath:[directory stringByAppendingPathComponent:@"missing/never.sqlite"] error:&error];
	Require(bad == nil && [error code] == FlycutArchiveStorageError, @"DB errors never writable defaults fallback");
	printf("PASS storage: mutations, reopen, keyset/revision, exact text, transaction-finish/corruption rollback, late uploads, exact explicit sharing, clock exhaustion, %lu post-commit notifications\n", (unsigned long)notifications);
}

static void RunMigration(NSString *directory) {
	NSMutableArray *history = [NSMutableArray array];
	for (NSUInteger i = 0; i < 10005; i++) [history addObject:@{@"Contents": [NSString stringWithFormat:@"history-%05lu", (unsigned long)i], @"Type": @"NSStringPboardType", @"Timestamp": @1700000000, @"Position": @(i)}];
	NSDictionary *repeat = @{@"Contents": @"repeat", @"Type": @"NSStringPboardType", @"AppLocalizedName": @"Synthetic", @"AppBundleURL": @"file:///Synthetic.app"};
	[history addObjectsFromArray:@[repeat, repeat, repeat]];
	NSDictionary *tupleA = @{@"Contents": @"tuple", @"Type": @"NSStringPboardType", @"Timestamp": @1};
	NSDictionary *tupleB = @{@"Contents": @"tuple", @"Type": @"NSStringPboardType", @"Timestamp": @2};
	[history addObjectsFromArray:@[tupleA, tupleB]];
	NSDictionary *orphan = @{@"Contents": @"unmatched", @"Type": @"NSStringPboardType"};
	NSDictionary *raw = @{@"store": @{@"jcList": history, @"favoritesList": @[repeat, repeat, tupleB, orphan], @"rememberNum": @2, @"favoritesRememberNum": @1}, @"otherPreference": @"raw backup retained"};
	NSString *path = [directory stringByAppendingPathComponent:@"migration.sqlite"];
	FlycutArchive *archive = [[FlycutArchive alloc] initWithPath:path error:NULL];
	Require(archive != nil, @"migration DB");
	NSError *error = nil;
	Require([archive migrateLegacyDefaults:raw error:&error], [NSString stringWithFormat:@"uncapped migration: %@", error]);
	Require([[archive legacyDefaultsBackup:NULL] isEqual:raw], @"entire raw defaults backup preserved");
	NSUInteger total = 0; NSDictionary *cursor = nil;
	while (YES) {
		NSDictionary *page = Page(archive, @"", NO, NO, 137, cursor);
		Require([[page objectForKey:@"items"] count] <= 137, @"large query bounded page");
		total += [[page objectForKey:@"items"] count];
		if (![[page objectForKey:@"has_more"] boolValue]) break;
		cursor = [page objectForKey:@"next_cursor"];
	}
	Require(total == 10011 && EventCount(archive) == 10011, @"migration does not honor remember caps or remove repetitions");
	Require([[Page(archive, @"repeat", NO, NO, 10, nil) objectForKey:@"items"] count] == 3, @"repeated legacy occurrences survive");
	Require([[Page(archive, @"repeat", YES, NO, 10, nil) objectForKey:@"items"] count] == 2, @"one-to-one repeated favorite matching");
	Require([[Page(archive, @"", YES, NO, 10, nil) objectForKey:@"items"] count] == 4, @"matched and unmatched favorites survive");
	NSArray *tuples = [Page(archive, @"tuple", YES, NO, 10, nil) objectForKey:@"items"];
	Require([tuples count] == 1 && [[[[tuples firstObject] objectForKey:@"captured_at_ms"] description] isEqual:@"2000"], @"full tuple matching and seconds conversion");
	NSArray *ordered = [Page(archive, @"history-", NO, NO, 3, nil) objectForKey:@"items"];
	Require([[[ordered firstObject] objectForKey:@"text"] isEqual:@"history-00000"] && [[[ordered objectAtIndex:2] objectForKey:@"text"] isEqual:@"history-00002"], @"legacy newest-first order preserved");
	Require([[[[Page(archive, @"repeat", NO, NO, 1, nil) objectForKey:@"items"] firstObject] objectForKey:@"captured_at_ms"] isEqual:[NSNull null]], @"missing timestamp remains null");
	long long revision = [archive revision];
	Require([archive migrateLegacyDefaults:@{} error:NULL] && [archive revision] == revision && EventCount(archive) == total, @"migration marker makes restart idempotent");
	[archive release];
	archive = [[FlycutArchive alloc] initWithPath:path error:NULL];
	Require(archive && EventCount(archive) == total && [[archive legacyDefaultsBackup:NULL] isEqual:raw], @"large migration durable after reopen");
	Require([[Page(archive, @"history-10004", NO, NO, 1, nil) objectForKey:@"items"] count] == 1, @"oldest beyond prior cap searchable");
	[archive release];
	FlycutArchive *rollback = Open(@":memory:");
	NSDictionary *bad = @{@"store": @{@"jcList": @[@{@"Contents": @"", @"Type": @"NSStringPboardType"}, repeat]}};
	error = nil;
	Require(![rollback migrateLegacyDefaults:bad error:&error] && [error code] == FlycutArchiveInvalidArgument, @"malformed migration yields stable error across inner pools");
	Require(EventCount(rollback) == 0 && [rollback legacyDefaultsBackup:NULL] == nil, @"migration backup and events rollback together");
	Require([rollback migrateLegacyDefaults:@{@"store": @{@"jcList": @[repeat]}} error:NULL] && EventCount(rollback) == 1, @"failed migration marker does not prevent retry");
	NSMutableDictionary *invalidFavorite = [NSMutableDictionary dictionaryWithDictionary:tupleA];
	[invalidFavorite setObject:@1.0 forKey:@"Timestamp"];
	for (NSArray *matchingHistory in @[@[tupleA], @[]]) {
		FlycutArchive *validation = Open(@":memory:");
		error = nil;
		Require(![validation migrateLegacyDefaults:@{@"store": @{@"jcList": matchingHistory, @"favoritesList": @[invalidFavorite]}} error:&error] && [error code] == FlycutArchiveInvalidArgument, @"matched and unmatched legacy favorites validated uniformly");
		Require(EventCount(validation) == 0 && [validation legacyDefaultsBackup:NULL] == nil, @"invalid favorite rolls back backup events and marker");
		Require([validation migrateLegacyDefaults:@{@"store": @{@"jcList": @[tupleA]}} error:NULL] && EventCount(validation) == 1, @"invalid favorite leaves migration retryable");
	}
	FlycutArchive *ordering = Open(@":memory:");
	NSDictionary *a = @{@"Contents": @"A", @"Type": @"NSStringPboardType"};
	NSDictionary *b = @{@"Contents": @"B", @"Type": @"NSStringPboardType"};
	NSDictionary *newestUnmatched = @{@"Contents": @"unmatched-newest", @"Type": @"NSStringPboardType"};
	NSDictionary *oldestUnmatched = @{@"Contents": @"unmatched-oldest", @"Type": @"NSStringPboardType"};
	Require([ordering migrateLegacyDefaults:@{@"store": @{@"jcList": @[a, b], @"favoritesList": @[newestUnmatched, b, oldestUnmatched, a]}} error:NULL], @"conflicting original favorite ordering migrates");
	NSArray *favoriteItems = [Page(ordering, @"", YES, NO, 10, nil) objectForKey:@"items"];
	Require([[favoriteItems valueForKey:@"text"] isEqual:@[@"unmatched-newest", @"unmatched-oldest", @"A", @"B"]], @"history recency authoritative for matched favorites; unmatched relative order preserved");
	Require(EventCount(ordering) == 4, @"conflicting list order neither duplicates IDs nor emits touches");
	printf("PASS migration: 10011 retained items from raw capped defaults, 4 favorites, repetitions/tuples/order/null dates, 137-item keyset pages, atomic backup/marker, reopen\n");
}

int main(int argc, const char **argv) {
	@autoreleasepool {
		if (argc == 2 && strcmp(argv[1], "--help") == 0) { puts("Usage: archive-driver <archive-v1.json>\nRuns isolated storage, migration, replay and search tests; never reads user preferences."); return 0; }
		if (argc != 2) { fputs("Usage: archive-driver <archive-v1.json>\n", stderr); return 2; }
		NSError *error = nil;
		NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
		Require(data != nil, @"fixture file readable");
		NSDictionary *fixtures = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
		Require(fixtures != nil, @"fixture JSON valid");
		NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"flycut-archive-driver-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
		Require([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:&error], @"isolated temporary directory");
		RunFixtures(fixtures);
		RunStorage(directory, fixtures);
		RunMigration(directory);
		Require([[NSFileManager defaultManager] removeItemAtPath:directory error:&error], @"remove owned synthetic DBs");
		puts("PASS archive end-to-end (no user history/defaults accessed)");
	}
	return 0;
}
