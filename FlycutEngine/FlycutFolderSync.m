//
//  FlycutFolderSync.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutFolderSync.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const kLogExtension = @"jsonl";
static const NSUInteger kTailLength = 32;

static int64_t NowMilliseconds(void)
{
	return (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);
}

// Whether a change made at (at, machine) beats one made at (otherAt, otherMachine).
static BOOL ChangeIsNewer(int64_t at, NSString *machine, int64_t otherAt, NSString *otherMachine)
{
	if ( at != otherAt )
		return at > otherAt;
	return [machine ?: @"" compare:otherMachine ?: @""] == NSOrderedDescending;
}

static NSString *HexString(NSData *data)
{
	NSMutableString *hex = [NSMutableString stringWithCapacity:[data length] * 2];
	const unsigned char *bytes = [data bytes];
	for ( NSUInteger i = 0; i < [data length]; i++ )
		[hex appendFormat:@"%02x", bytes[i]];
	return hex;
}

@implementation FlycutFolderSync {
	FlycutHistoryDB *historyDB;
	FlycutStore *clippingStore;
	FlycutStore *favoritesStore;
	NSTimer *pollTimer;
	BOOL applyingRemoteChanges;
	int64_t lastLocalAt;
	NSMutableSet *otherMachines;
	NSMutableDictionary *pendingChanges[2];	// per list: clip id -> clipping to place, or NSNull to remove
}

@synthesize folder, machineId, lastError, pollInterval, compactionThreshold, didApplyRemoteChanges;

-(instancetype) initWithFolder:(NSString *)aFolder
					 historyDB:(FlycutHistoryDB *)aHistoryDB
				 clippingStore:(FlycutStore *)aClippingStore
				favoritesStore:(FlycutStore *)aFavoritesStore
{
	self = [super init];
	if ( !self )
		return nil;
	folder = [[aFolder stringByStandardizingPath] copy];
	historyDB = [aHistoryDB retain];
	clippingStore = [aClippingStore retain];
	favoritesStore = [aFavoritesStore retain];
	otherMachines = [[NSMutableSet alloc] init];
	pendingChanges[FlycutHistoryListClippings] = [[NSMutableDictionary alloc] init];
	pendingChanges[FlycutHistoryListFavorites] = [[NSMutableDictionary alloc] init];
	pollInterval = 2.0;
	compactionThreshold = 1000;
	machineId = [[self loadOrCreateMachineId] copy];
	return self;
}

-(NSString *) loadOrCreateMachineId
{
	NSString *existing = [historyDB metaValueForKey:@"sync-machine-id"];
	if ( [existing length] )
		return existing;

	// gethostname, not -[NSProcessInfo hostName], which can wait seconds on a DNS lookup.
	char hostBuffer[256] = "";
	gethostname(hostBuffer, sizeof hostBuffer - 1);
	NSString *host = [[[NSString stringWithUTF8String:hostBuffer] componentsSeparatedByString:@"."] firstObject];
	NSCharacterSet *unsafe = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"] invertedSet];
	host = [[host componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@""];
	if ( [host length] == 0 )
		host = @"mac";
	NSString *suffix = [[[[NSUUID UUID] UUIDString] substringToIndex:8] lowercaseString];
	NSString *created = [NSString stringWithFormat:@"%@-%@", [host lowercaseString], suffix];
	[historyDB setMetaValue:created forKey:@"sync-machine-id"];
	return created;
}

-(NSString *) ownLogPath
{
	return [folder stringByAppendingPathComponent:[machineId stringByAppendingPathExtension:kLogExtension]];
}

-(FlycutStore *) storeForList:(FlycutHistoryList)list
{
	return list == FlycutHistoryListFavorites ? favoritesStore : clippingStore;
}

-(void) setLastError:(NSString *)error
{
	if ( error )
		NSLog(@"Flycut sync: %@", error);
	[lastError release];
	lastError = [error copy];
}

#pragma mark Lifecycle

-(BOOL) start
{
	BOOL isDirectory = NO;
	if ( ![[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&isDirectory] || !isDirectory ) {
		[self setLastError:[NSString stringWithFormat:@"sync folder %@ does not exist", folder]];
		return NO;
	}
	if ( ![[NSFileManager defaultManager] isWritableFileAtPath:folder] ) {
		[self setLastError:[NSString stringWithFormat:@"sync folder %@ is not writable", folder]];
		return NO;
	}
	[self setLastError:nil];

	// Other machines' deletions are read before this machine's history is shared, so they aren't undone.
	[self poll];
	if ( ![[NSFileManager defaultManager] fileExistsAtPath:[self ownLogPath]] )
		[self exportHistory];
	else
		[self compactOwnLogIfNeeded];

	[pollTimer invalidate];
	[pollTimer release];
	pollTimer = [[NSTimer timerWithTimeInterval:pollInterval target:self selector:@selector(pollTimerFired:) userInfo:nil repeats:YES] retain];
	[[NSRunLoop mainRunLoop] addTimer:pollTimer forMode:NSRunLoopCommonModes];
	return YES;
}

-(void) stop
{
	[pollTimer invalidate];
	[pollTimer release];
	pollTimer = nil;
}

-(void) pollTimerFired:(NSTimer *)timer
{
	[self poll];
}

-(NSUInteger) otherMachineCount
{
	return [otherMachines count];
}

#pragma mark Writing this machine's events

-(int64_t) nextLocalAtAfter:(int64_t)seen
{
	lastLocalAt = MAX(MAX(NowMilliseconds(), seen + 1), lastLocalAt + 1);
	return lastLocalAt;
}

-(NSData *) lineForEvent:(NSDictionary *)event
{
	NSError *error = nil;
	NSMutableData *line = [[[NSJSONSerialization dataWithJSONObject:event options:0 error:&error] mutableCopy] autorelease];
	if ( !line ) {
		NSLog(@"Flycut sync: cannot encode event: %@", error);
		return nil;
	}
	[line appendBytes:"\n" length:1];
	return line;
}

// One write per batch of lines, appended, so a reader never sees half of a line that is still being written.
-(void) appendToOwnLog:(NSData *)lines
{
	if ( [lines length] == 0 )
		return;
	int fd = open([[self ownLogPath] fileSystemRepresentation], O_WRONLY | O_APPEND | O_CREAT, 0600);
	if ( fd < 0 ) {
		[self setLastError:[NSString stringWithFormat:@"cannot write %@: %s", [self ownLogPath], strerror(errno)]];
		return;
	}
	ssize_t written = write(fd, [lines bytes], [lines length]);
	close(fd);
	if ( written != (ssize_t)[lines length] )
		[self setLastError:[NSString stringWithFormat:@"short write to %@", [self ownLogPath]]];
}

-(NSDictionary *) putEventForClipping:(FlycutClipping *)clipping inList:(FlycutHistoryList)list at:(int64_t)at
{
	NSMutableDictionary *event = [NSMutableDictionary dictionaryWithDictionary:@{
		@"v": @1, @"op": @"put", @"list": @(list), @"id": [clipping clipId], @"at": @(at), @"m": machineId,
		@"rank": @([clipping rank]), @"contents": [clipping contents] ?: @"", @"ts": @([clipping timestamp])}];
	if ( [clipping type] )
		[event setObject:[clipping type] forKey:@"type"];
	if ( [clipping appLocalizedName] )
		[event setObject:[clipping appLocalizedName] forKey:@"app"];
	if ( [clipping appBundleURL] )
		[event setObject:[clipping appBundleURL] forKey:@"appPath"];
	return event;
}

-(NSData *) recordLocalPutOfClipping:(FlycutClipping *)clipping inList:(FlycutHistoryList)list
{
	FlycutSyncState state = [historyDB syncStateForClipId:[clipping clipId] inList:list];
	int64_t at = [self nextLocalAtAfter:MAX(state.at, [self clearMarkerForList:list].at)];
	FlycutSyncState newState = { at, machineId, NO };
	[historyDB setSyncState:newState forClipId:[clipping clipId] inList:list];
	return [self lineForEvent:[self putEventForClipping:clipping inList:list at:at]];
}

-(void) exportHistory
{
	NSMutableData *lines = [NSMutableData data];
	[historyDB beginTransaction];
	for ( FlycutStore *store in @[clippingStore, favoritesStore] )
		for ( FlycutClipping *clipping in [[store allClippings] reverseObjectEnumerator] )
			[lines appendData:[self recordLocalPutOfClipping:clipping inList:[store persistenceListId]] ?: [NSData data]];
	[historyDB commitTransaction];
	[self appendToOwnLog:lines];
	// An empty history still creates the file, so the folder shows this machine takes part.
	if ( [lines length] == 0 )
		[[NSData data] writeToFile:[self ownLogPath] atomically:NO];
}

#pragma mark FlycutStorePersistence

- (void)store:(FlycutStore *)store didSaveClipping:(FlycutClipping *)clipping
{
	[historyDB store:store didSaveClipping:clipping];
	if ( !applyingRemoteChanges )
		[self appendToOwnLog:[self recordLocalPutOfClipping:clipping inList:[store persistenceListId]]];
}

- (void)store:(FlycutStore *)store didRemoveClippings:(NSArray *)clippings
{
	[historyDB store:store didRemoveClippings:clippings];
	if ( applyingRemoteChanges )
		return;

	FlycutHistoryList list = [store persistenceListId];
	NSMutableData *lines = [NSMutableData data];
	for ( FlycutClipping *clipping in clippings ) {
		FlycutSyncState state = [historyDB syncStateForClipId:[clipping clipId] inList:list];
		int64_t at = [self nextLocalAtAfter:state.at];
		FlycutSyncState newState = { at, machineId, YES };
		[historyDB setSyncState:newState forClipId:[clipping clipId] inList:list];
		[lines appendData:[self lineForEvent:@{@"v": @1, @"op": @"del", @"list": @(list), @"id": [clipping clipId], @"at": @(at), @"m": machineId}] ?: [NSData data]];
	}
	[self appendToOwnLog:lines];
}

- (void)store:(FlycutStore *)store didDropClippings:(NSArray *)clippings
{
	[historyDB store:store didDropClippings:clippings];
}

- (void)storeDidClear:(FlycutStore *)store
{
	[historyDB storeDidClear:store];
	if ( applyingRemoteChanges )
		return;

	// The clear covers everything this machine has seen in the list, whatever the other machines' clocks say.
	FlycutHistoryList list = [store persistenceListId];
	int64_t at = [self nextLocalAtAfter:MAX([self clearMarkerForList:list].at, [historyDB latestSyncChangeInList:list])];
	[self setClearMarker:(FlycutSyncState){ at, machineId, YES } forList:list];
	[self appendToOwnLog:[self lineForEvent:@{@"v": @1, @"op": @"clear", @"list": @(list), @"at": @(at), @"m": machineId}]];
}

#pragma mark Clear markers

-(FlycutSyncState) clearMarkerForList:(FlycutHistoryList)list
{
	FlycutSyncState marker = { 0, nil, YES };
	NSArray *parts = [[historyDB metaValueForKey:[NSString stringWithFormat:@"sync-clear:%d", list]] componentsSeparatedByString:@" "];
	if ( [parts count] == 2 ) {
		marker.at = [[parts objectAtIndex:0] longLongValue];
		marker.machine = [parts objectAtIndex:1];
	}
	return marker;
}

-(void) setClearMarker:(FlycutSyncState)marker forList:(FlycutHistoryList)list
{
	[historyDB setMetaValue:[NSString stringWithFormat:@"%lld %@", marker.at, marker.machine]
					 forKey:[NSString stringWithFormat:@"sync-clear:%d", list]];
}

#pragma mark Reading other machines' events

-(NSString *) readPositionKeyForFile:(NSString *)name
{
	return [NSString stringWithFormat:@"sync-read:%@/%@", folder, name];
}

-(NSArray *) otherLogNames
{
	NSMutableArray *names = [NSMutableArray array];
	NSString *ownName = [[self ownLogPath] lastPathComponent];
	for ( NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:folder error:nil] ) {
		// iCloud Drive leaves ".<name>.icloud" in place of a file it hasn't downloaded; ask for it.
		if ( [name hasPrefix:@"."] && [name hasSuffix:@".jsonl.icloud"] ) {
			NSString *realName = [[name substringFromIndex:1] stringByDeletingPathExtension];
			[[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:realName]] error:nil];
			continue;
		}
		if ( [name hasPrefix:@"."] || ![[name pathExtension] isEqualToString:kLogExtension] || [name isEqualToString:ownName] )
			continue;
		[names addObject:name];
	}
	[names sortUsingSelector:@selector(compare:)];
	return names;
}

// Reads the complete lines appended since the last read. A file that no longer has the bytes the last
// read ended with was rewritten (compacted, or replaced by the sync tool), so it is read from the start;
// applying an event twice changes nothing.
-(NSArray *) newEventsInFile:(NSString *)name nextPosition:(NSString **)nextPosition
{
	NSString *path = [folder stringByAppendingPathComponent:name];
	NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
	if ( !file )
		return nil;

	unsigned long long offset = 0;
	NSArray *saved = [[historyDB metaValueForKey:[self readPositionKeyForFile:name]] componentsSeparatedByString:@" "];
	if ( [saved count] == 2 ) {
		unsigned long long savedOffset = strtoull([[saved objectAtIndex:0] UTF8String], NULL, 10);
		NSString *savedTail = [saved objectAtIndex:1];
		unsigned long long tailLength = MIN((unsigned long long)kTailLength, savedOffset);
		[file seekToFileOffset:savedOffset - tailLength];
		NSData *tail = [file readDataOfLength:(NSUInteger)tailLength];
		if ( [tail length] == tailLength && [HexString(tail) isEqualToString:savedTail] )
			offset = savedOffset;
	}

	[file seekToFileOffset:offset];
	NSData *data = [file readDataToEndOfFile];
	[file closeFile];

	const char *bytes = [data bytes];
	NSUInteger end = [data length];
	while ( end > 0 && bytes[end - 1] != '\n' )
		end--;
	if ( end == 0 )
		return @[];

	NSMutableArray *events = [NSMutableArray array];
	NSUInteger lineStart = 0;
	for ( NSUInteger i = 0; i < end; i++ ) {
		if ( bytes[i] != '\n' )
			continue;
		if ( i > lineStart ) {
			NSData *line = [NSData dataWithBytesNoCopy:(void *)(bytes + lineStart) length:i - lineStart freeWhenDone:NO];
			id event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
			if ( [event isKindOfClass:[NSDictionary class]] && [[event objectForKey:@"v"] intValue] == 1 )
				[events addObject:event];
			else
				NSLog(@"Flycut sync: skipping an unreadable line in %@ at byte %llu", name, offset + lineStart);
		}
		lineStart = i + 1;
	}

	NSUInteger tailLength = MIN(kTailLength, end);
	*nextPosition = [NSString stringWithFormat:@"%llu %@", offset + end,
					 HexString([data subdataWithRange:NSMakeRange(end - tailLength, tailLength)])];
	return events;
}

-(void) poll
{
	BOOL changed = NO;
	for ( NSString *name in [self otherLogNames] ) {
		[otherMachines addObject:[name stringByDeletingPathExtension]];
		NSString *nextPosition = nil;
		NSArray *events = [self newEventsInFile:name nextPosition:&nextPosition];
		if ( !nextPosition )
			continue;

		[historyDB beginTransaction];
		applyingRemoteChanges = YES;
		for ( NSDictionary *event in events )
			changed |= [self applyEvent:event];
		[self applyPendingChanges];
		applyingRemoteChanges = NO;
		[historyDB setMetaValue:nextPosition forKey:[self readPositionKeyForFile:name]];
		[historyDB commitTransaction];
	}
	if ( changed && didApplyRemoteChanges )
		didApplyRemoteChanges();
}

-(BOOL) applyEvent:(NSDictionary *)event
{
	NSString *op = [event objectForKey:@"op"];
	int listNumber = [[event objectForKey:@"list"] intValue];
	if ( listNumber != FlycutHistoryListClippings && listNumber != FlycutHistoryListFavorites )
		return NO;
	FlycutHistoryList list = (FlycutHistoryList)listNumber;
	int64_t at = [[event objectForKey:@"at"] longLongValue];
	NSString *machine = [event objectForKey:@"m"];
	if ( ![machine isKindOfClass:[NSString class]] || [machine isEqualToString:machineId] )
		return NO;

	if ( [op isEqualToString:@"clear"] ) {
		[self applyPendingChanges];
		return [self applyClearOfList:list at:at by:machine];
	}

	NSString *clipId = [event objectForKey:@"id"];
	if ( ![clipId isKindOfClass:[NSString class]] || [clipId length] == 0 )
		return NO;
	FlycutSyncState cleared = [self clearMarkerForList:list];
	if ( !ChangeIsNewer(at, machine, cleared.at, cleared.machine) )
		return NO;
	FlycutSyncState state = [historyDB syncStateForClipId:clipId inList:list];
	if ( state.at != 0 && !ChangeIsNewer(at, machine, state.at, state.machine) )
		return NO;

	if ( [op isEqualToString:@"put"] ) {
		NSString *contents = [event objectForKey:@"contents"];
		if ( ![contents isKindOfClass:[NSString class]] || [contents length] == 0 )
			return NO;
		[historyDB setSyncState:(FlycutSyncState){ at, machine, NO } forClipId:clipId inList:list];
		FlycutClipping *clipping = [[FlycutClipping alloc] initWithContents:contents
																   withType:[self stringIn:event forKey:@"type"]
														  withDisplayLength:[[self storeForList:list] displayLen]
													   withAppLocalizedName:[self stringIn:event forKey:@"app"]
														   withAppBundleURL:[self stringIn:event forKey:@"appPath"]
															  withTimestamp:[[event objectForKey:@"ts"] integerValue]];
		[clipping setClipId:clipId];
		[clipping setRank:[[event objectForKey:@"rank"] doubleValue]];
		[pendingChanges[list] setObject:clipping forKey:clipId];
		[clipping release];
		return YES;
	}
	if ( [op isEqualToString:@"del"] ) {
		[historyDB setSyncState:(FlycutSyncState){ at, machine, YES } forClipId:clipId inList:list];
		[pendingChanges[list] setObject:[NSNull null] forKey:clipId];
		return YES;
	}
	return NO;
}

// Stores take changes in batches: placing one clipping at a time costs a pass over the whole list each.
-(void) applyPendingChanges
{
	for ( FlycutHistoryList list = FlycutHistoryListClippings; list <= FlycutHistoryListFavorites; list++ ) {
		NSMutableSet *removed = [NSMutableSet set];
		NSMutableArray *placed = [NSMutableArray array];
		[pendingChanges[list] enumerateKeysAndObjectsUsingBlock:^(NSString *clipId, id change, BOOL *stop) {
			if ( change == [NSNull null] )
				[removed addObject:clipId];
			else
				[placed addObject:change];
		}];
		[pendingChanges[list] removeAllObjects];
		if ( [removed count] )
			[[self storeForList:list] removeClippingsWithIds:removed];
		[[self storeForList:list] placeClippings:placed];
	}
}

-(NSString *) stringIn:(NSDictionary *)event forKey:(NSString *)key
{
	id value = [event objectForKey:key];
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

// Removes every clipping last changed before the clear; later changes, from any machine, survive it.
-(BOOL) applyClearOfList:(FlycutHistoryList)list at:(int64_t)at by:(NSString *)machine
{
	FlycutSyncState cleared = [self clearMarkerForList:list];
	if ( !ChangeIsNewer(at, machine, cleared.at, cleared.machine) )
		return NO;
	[self setClearMarker:(FlycutSyncState){ at, machine, YES } forList:list];

	NSMutableSet *removed = [NSMutableSet set];
	for ( FlycutClipping *clipping in [[self storeForList:list] allClippings] ) {
		FlycutSyncState state = [historyDB syncStateForClipId:[clipping clipId] inList:list];
		if ( state.at == 0 || ChangeIsNewer(at, machine, state.at, state.machine) )
			[removed addObject:[clipping clipId]];
	}
	[[self storeForList:list] removeClippingsWithIds:removed];
	return [removed count] > 0;
}

#pragma mark Compaction

// Keeps only the newest event per clipping (and the newest clear per list) once the file has grown to
// more than twice that. Written beside the file and renamed over it, so readers see the old or the new one.
-(void) compactOwnLogIfNeeded
{
	NSData *data = [NSData dataWithContentsOfFile:[self ownLogPath]];
	NSArray *lines = [[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] componentsSeparatedByString:@"\n"];
	if ( [lines count] < compactionThreshold )
		return;

	NSMutableDictionary *latest = [NSMutableDictionary dictionary];
	NSMutableArray *order = [NSMutableArray array];
	NSUInteger eventCount = 0;
	for ( NSString *line in lines ) {
		if ( [line length] == 0 )
			continue;
		NSDictionary *event = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
		if ( ![event isKindOfClass:[NSDictionary class]] )
			continue;
		eventCount++;
		NSString *key = [[event objectForKey:@"op"] isEqualToString:@"clear"]
			? [NSString stringWithFormat:@"clear/%@", [event objectForKey:@"list"]]
			: [NSString stringWithFormat:@"%@/%@", [event objectForKey:@"list"], [event objectForKey:@"id"]];
		if ( ![latest objectForKey:key] )
			[order addObject:key];
		[latest setObject:@{@"line": line, @"event": event} forKey:key];
	}
	if ( [latest count] * 2 > eventCount )
		return;

	NSMutableData *compacted = [NSMutableData data];
	for ( NSString *key in order ) {
		NSDictionary *entry = [latest objectForKey:key];
		NSDictionary *event = [entry objectForKey:@"event"];
		if ( ![[event objectForKey:@"op"] isEqualToString:@"clear"] ) {
			NSDictionary *clear = [[latest objectForKey:[NSString stringWithFormat:@"clear/%@", [event objectForKey:@"list"]]] objectForKey:@"event"];
			if ( clear && !ChangeIsNewer([[event objectForKey:@"at"] longLongValue], [event objectForKey:@"m"],
										  [[clear objectForKey:@"at"] longLongValue], [clear objectForKey:@"m"]) )
				continue;
		}
		[compacted appendData:[[entry objectForKey:@"line"] dataUsingEncoding:NSUTF8StringEncoding]];
		[compacted appendBytes:"\n" length:1];
	}

	NSString *temporaryPath = [[self ownLogPath] stringByAppendingPathExtension:@"compacting"];
	if ( ![compacted writeToFile:temporaryPath atomically:NO]
		|| rename([temporaryPath fileSystemRepresentation], [[self ownLogPath] fileSystemRepresentation]) != 0 ) {
		[[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
		[self setLastError:[NSString stringWithFormat:@"cannot compact %@", [self ownLogPath]]];
		return;
	}
	chmod([[self ownLogPath] fileSystemRepresentation], 0600);
	NSLog(@"Flycut sync: compacted %@ from %lu to %lu events", [self ownLogPath], (unsigned long)eventCount, (unsigned long)[latest count]);
}

-(void) dealloc
{
	[pollTimer invalidate];
	[pollTimer release];
	[folder release];
	[machineId release];
	[lastError release];
	[didApplyRemoteChanges release];
	[historyDB release];
	[clippingStore release];
	[favoritesStore release];
	[otherMachines release];
	[pendingChanges[FlycutHistoryListClippings] release];
	[pendingChanges[FlycutHistoryListFavorites] release];
	[super dealloc];
}

@end
