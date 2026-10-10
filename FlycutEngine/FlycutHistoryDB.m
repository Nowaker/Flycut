//
//  FlycutHistoryDB.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutHistoryDB.h"
#import <sqlite3.h>
#import <sys/stat.h>

static const int kSchemaVersion = 1;

@implementation FlycutHistoryDB {
	sqlite3 *db;
	sqlite3_stmt *saveStatement;
	sqlite3_stmt *removeStatement;
	sqlite3_stmt *clearStatement;
}

+(NSString *) defaultPath
{
	NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
	NSString *directory = [appSupport stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]];
	return [directory stringByAppendingPathComponent:@"History.sqlite"];
}

-(instancetype) initWithPath:(NSString *)path
{
	self = [super init];
	if ( !self )
		return nil;

	// Clipboard history routinely holds secrets, so neither the directory nor the database is readable by other users.
	NSString *directory = [path stringByDeletingLastPathComponent];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory
							  withIntermediateDirectories:YES
											   attributes:@{NSFilePosixPermissions: @0700}
													error:nil];

	if ( sqlite3_open_v2([path fileSystemRepresentation], &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK ) {
		NSLog(@"Flycut: cannot open history database %@: %s", path, sqlite3_errmsg(db));
		[self release];
		return nil;
	}
	chmod([path fileSystemRepresentation], 0600);

	if ( ![self migrate] || ![self prepareStatements] ) {
		[self release];
		return nil;
	}
	return self;
}

-(BOOL) exec:(NSString *)sql
{
	char *error = NULL;
	if ( sqlite3_exec(db, [sql UTF8String], NULL, NULL, &error) != SQLITE_OK ) {
		NSLog(@"Flycut: history database error in \"%@\": %s", sql, error);
		sqlite3_free(error);
		return NO;
	}
	return YES;
}

-(int) schemaVersion
{
	sqlite3_stmt *statement = NULL;
	int version = 0;
	if ( sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, NULL) == SQLITE_OK
		&& sqlite3_step(statement) == SQLITE_ROW )
		version = sqlite3_column_int(statement, 0);
	sqlite3_finalize(statement);
	return version;
}

-(BOOL) migrate
{
	if ( ![self exec:@"PRAGMA journal_mode = WAL"] || ![self exec:@"PRAGMA synchronous = NORMAL"] )
		return NO;

	if ( [self schemaVersion] < 1 ) {
		BOOL created = [self exec:@"BEGIN"]
			&& [self exec:@"CREATE TABLE clips ("
				 "list INTEGER NOT NULL, "
				 "id TEXT NOT NULL, "
				 "rank REAL NOT NULL, "
				 "contents TEXT NOT NULL, "
				 "type TEXT, "
				 "app_name TEXT, "
				 "app_bundle_path TEXT, "
				 "timestamp INTEGER NOT NULL DEFAULT 0, "
				 "PRIMARY KEY (list, id))"]
			&& [self exec:@"CREATE INDEX clips_by_rank ON clips (list, rank)"]
			&& [self exec:@"CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)"]
			&& [self exec:[NSString stringWithFormat:@"PRAGMA user_version = %d", kSchemaVersion]]
			&& [self exec:@"COMMIT"];
		if ( !created ) {
			[self exec:@"ROLLBACK"];
			return NO;
		}
	}
	return YES;
}

-(BOOL) prepare:(const char *)sql into:(sqlite3_stmt **)statement
{
	if ( sqlite3_prepare_v2(db, sql, -1, statement, NULL) != SQLITE_OK ) {
		NSLog(@"Flycut: cannot prepare \"%s\": %s", sql, sqlite3_errmsg(db));
		return NO;
	}
	return YES;
}

-(BOOL) prepareStatements
{
	return [self prepare:"INSERT OR REPLACE INTO clips (list, id, rank, contents, type, app_name, app_bundle_path, timestamp) VALUES (?, ?, ?, ?, ?, ?, ?, ?)" into:&saveStatement]
		&& [self prepare:"DELETE FROM clips WHERE list = ? AND id = ?" into:&removeStatement]
		&& [self prepare:"DELETE FROM clips WHERE list = ?" into:&clearStatement];
}

static void bindString(sqlite3_stmt *statement, int column, NSString *value)
{
	if ( nil == value ) {
		sqlite3_bind_null(statement, column);
		return;
	}
	NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
	sqlite3_bind_text(statement, column, [utf8 bytes], (int)[utf8 length], SQLITE_TRANSIENT);
}

static NSString *columnString(sqlite3_stmt *statement, int column)
{
	const void *bytes = sqlite3_column_text(statement, column);
	if ( NULL == bytes )
		return nil;
	return [[[NSString alloc] initWithBytes:bytes length:sqlite3_column_bytes(statement, column) encoding:NSUTF8StringEncoding] autorelease];
}

-(void) step:(sqlite3_stmt *)statement
{
	if ( sqlite3_step(statement) != SQLITE_DONE )
		NSLog(@"Flycut: history database write failed: %s", sqlite3_errmsg(db));
	sqlite3_reset(statement);
	sqlite3_clear_bindings(statement);
}

-(void) saveClipping:(FlycutClipping *)clipping inList:(int)list
{
	sqlite3_bind_int(saveStatement, 1, list);
	bindString(saveStatement, 2, [clipping clipId]);
	sqlite3_bind_double(saveStatement, 3, [clipping rank]);
	bindString(saveStatement, 4, [clipping contents] ?: @"");
	bindString(saveStatement, 5, [clipping type]);
	bindString(saveStatement, 6, [clipping appLocalizedName]);
	bindString(saveStatement, 7, [clipping appBundleURL]);
	sqlite3_bind_int64(saveStatement, 8, [clipping timestamp]);
	[self step:saveStatement];
}

-(void) clearList:(int)list
{
	sqlite3_bind_int(clearStatement, 1, list);
	[self step:clearStatement];
}

-(NSArray *) clippingsInList:(FlycutHistoryList)list withDisplayLength:(int)displayLength
{
	NSMutableArray *clippings = [NSMutableArray array];
	sqlite3_stmt *statement = NULL;
	if ( ![self prepare:"SELECT id, rank, contents, type, app_name, app_bundle_path, timestamp FROM clips WHERE list = ? ORDER BY rank DESC" into:&statement] )
		return clippings;

	sqlite3_bind_int(statement, 1, list);
	while ( sqlite3_step(statement) == SQLITE_ROW ) {
		FlycutClipping *clipping = [[FlycutClipping alloc] initWithContents:columnString(statement, 2) ?: @""
																   withType:columnString(statement, 3)
														  withDisplayLength:displayLength
													   withAppLocalizedName:columnString(statement, 4)
														   withAppBundleURL:columnString(statement, 5)
															  withTimestamp:(NSInteger)sqlite3_column_int64(statement, 6)];
		[clipping setClipId:columnString(statement, 0)];
		[clipping setRank:sqlite3_column_double(statement, 1)];
		[clippings addObject:clipping];
		[clipping release];
	}
	sqlite3_finalize(statement);
	return clippings;
}

-(void) replaceList:(FlycutHistoryList)list withClippings:(NSArray *)clippings
{
	[self exec:@"BEGIN IMMEDIATE"];
	[self clearList:list];
	for ( FlycutClipping *clipping in clippings )
		[self saveClipping:clipping inList:list];
	[self exec:@"COMMIT"];
}

-(void) clearAll
{
	[self exec:@"DELETE FROM clips"];
}

-(NSString *) metaValueForKey:(NSString *)key
{
	sqlite3_stmt *statement = NULL;
	NSString *value = nil;
	if ( [self prepare:"SELECT value FROM meta WHERE key = ?" into:&statement] ) {
		bindString(statement, 1, key);
		if ( sqlite3_step(statement) == SQLITE_ROW )
			value = columnString(statement, 0);
	}
	sqlite3_finalize(statement);
	return value;
}

-(void) setMetaValue:(NSString *)value forKey:(NSString *)key
{
	sqlite3_stmt *statement = NULL;
	if ( [self prepare:"INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)" into:&statement] ) {
		bindString(statement, 1, key);
		bindString(statement, 2, value);
		[self step:statement];
	}
	sqlite3_finalize(statement);
}

#pragma mark FlycutStorePersistence

- (void)store:(FlycutStore *)store didSaveClipping:(FlycutClipping *)clipping
{
	[self saveClipping:clipping inList:[store persistenceListId]];
}

- (void)store:(FlycutStore *)store didRemoveClippings:(NSArray *)clippings
{
	[self exec:@"BEGIN IMMEDIATE"];
	for ( FlycutClipping *clipping in clippings ) {
		sqlite3_bind_int(removeStatement, 1, [store persistenceListId]);
		bindString(removeStatement, 2, [clipping clipId]);
		[self step:removeStatement];
	}
	[self exec:@"COMMIT"];
}

- (void)storeDidClear:(FlycutStore *)store
{
	[self clearList:[store persistenceListId]];
}

-(void) dealloc
{
	sqlite3_finalize(saveStatement);
	sqlite3_finalize(removeStatement);
	sqlite3_finalize(clearStatement);
	sqlite3_close(db);
	[super dealloc];
}

@end
