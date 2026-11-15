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
// How long a line whose data hasn't arrived yet (the folder tool copies files in any order) is waited for.
static const int64_t kMissingBlobWaitMilliseconds = 10 * 60 * 1000;
static const NSTimeInterval kUnreferencedBlobAge = 600;

typedef NS_ENUM(int, FlycutEventOutcome) {
	FlycutEventIgnored = 0,
	FlycutEventApplied,
	FlycutEventWaiting,	// refers to data that isn't in the folder yet; read again from this line next time
};

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

@synthesize folder, machineId, lastError, pollInterval, compactionThreshold, didApplyRemoteChanges, crypto, credentialDetector, blobStore;

+(NSString *) blobDirectoryForMachine:(NSString *)machine inFolder:(NSString *)aFolder
{
	return [[aFolder stringByAppendingPathComponent:@"blobs"] stringByAppendingPathComponent:machine];
}

+(NSSet *) blobAddressesInLog:(NSData *)log
{
	NSMutableSet *addresses = [NSMutableSet set];
	const char *bytes = [log bytes];
	NSUInteger lineStart = 0, length = [log length];
	for ( NSUInteger i = 0; i < length; i++ ) {
		if ( bytes[i] != '\n' )
			continue;
		// Only lines with items are parsed; most are text clippings.
		NSData *line = [NSData dataWithBytesNoCopy:(void *)(bytes + lineStart) length:i - lineStart freeWhenDone:NO];
		lineStart = i + 1;
		if ( [line rangeOfData:[@"\"items\"" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, [line length])].location == NSNotFound )
			continue;
		NSDictionary *event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
		NSArray *items = [event isKindOfClass:[NSDictionary class]] ? [event objectForKey:@"items"] : nil;
		if ( ![items isKindOfClass:[NSArray class]] )
			continue;
		for ( NSArray *item in items )
			if ( [item isKindOfClass:[NSArray class]] )
				for ( NSDictionary *representation in item )
					if ( [representation isKindOfClass:[NSDictionary class]] && [FlycutBlobStore isAddress:[representation objectForKey:@"b"]] )
						[addresses addObject:[representation objectForKey:@"b"]];
	}
	return addresses;
}

-(FlycutBlobStore *) blobsOfMachine:(NSString *)machine
{
	return [[[FlycutBlobStore alloc] initWithDirectory:[FlycutFolderSync blobDirectoryForMachine:machine inFolder:folder]] autorelease];
}

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
	credentialDetector = [[FlycutCredentialDetector sharedDetector] retain];
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
	else {
		[self sealCredentialsInOwnLogIfNeeded];
		[self compactOwnLogIfNeeded];
		[self removeUnreferencedOwnBlobs];
	}

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
	if ( [clipping contentsDescribeItems] )
		[event setObject:@YES forKey:@"described"];
	NSArray *items = [self eventItemsForClipping:clipping sealed:[self eventNeedsSealing:event]];
	if ( [items count] )
		[event setObject:items forKey:@"items"];
	[self sealContentsOfEvent:event];
	if ( [clipping type] )
		[event setObject:[clipping type] forKey:@"type"];
	if ( [clipping appLocalizedName] )
		[event setObject:[clipping appLocalizedName] forKey:@"app"];
	if ( [clipping appBundleURL] )
		[event setObject:[clipping appBundleURL] forKey:@"appPath"];
	return event;
}

-(BOOL) eventNeedsSealing:(NSDictionary *)event
{
	NSString *contents = [event objectForKey:@"contents"];
	return crypto && ![[event objectForKey:@"described"] boolValue]
		&& [contents isKindOfClass:[NSString class]] && [credentialDetector isCredential:contents];
}

// Puts the items' data in this machine's blob directory, sealed or as hard links to the blob store.
// Data no longer in the blob store is left out.
-(NSArray *) eventItemsForClipping:(FlycutClipping *)clipping sealed:(BOOL)sealed
{
	if ( !blobStore || [[clipping items] count] == 0 )
		return nil;
	FlycutBlobStore *ownBlobs = [self blobsOfMachine:machineId];
	NSMutableArray *eventItems = [NSMutableArray arrayWithCapacity:[[clipping items] count]];
	for ( NSArray *item in [clipping items] ) {
		NSMutableArray *eventItem = [NSMutableArray arrayWithCapacity:[item count]];
		for ( NSDictionary *representation in item ) {
			NSString *address = [representation objectForKey:@"b"];
			NSMutableDictionary *eventRepresentation = [NSMutableDictionary dictionaryWithDictionary:representation];
			if ( sealed ) {
				NSData *data = [blobStore dataAtAddress:address];
				NSString *sealedAddress = data ? [ownBlobs storeData:[crypto sealData:data]] : nil;
				if ( !sealedAddress )
					continue;
				[eventRepresentation setObject:sealedAddress forKey:@"b"];
				[eventRepresentation setObject:@YES forKey:@"s"];
			} else if ( ![blobStore exportAddress:address toPath:[ownBlobs pathForAddress:address]] )
				continue;
			[eventItem addObject:eventRepresentation];
		}
		if ( [eventItem count] )
			[eventItems addObject:eventItem];
	}
	return eventItems;
}

// Replaces a credential's "contents" with its sealed form "enc", and its items' data with sealed data,
// read from this machine's blob directory. Returns whether it did.
-(BOOL) sealContentsOfEvent:(NSMutableDictionary *)event
{
	if ( ![self eventNeedsSealing:event] )
		return NO;
	NSString *sealed = [crypto seal:[event objectForKey:@"contents"]];
	if ( !sealed )
		return NO;
	[event setObject:sealed forKey:@"enc"];
	[event removeObjectForKey:@"contents"];

	FlycutBlobStore *ownBlobs = [self blobsOfMachine:machineId];
	NSMutableArray *sealedItems = [NSMutableArray array];
	for ( NSArray *item in [event objectForKey:@"items"] ) {
		NSMutableArray *sealedItem = [NSMutableArray array];
		for ( NSDictionary *representation in item ) {
			if ( [[representation objectForKey:@"s"] boolValue] ) {
				[sealedItem addObject:representation];
				continue;
			}
			NSData *data = [ownBlobs dataAtAddress:[representation objectForKey:@"b"]];
			NSString *sealedAddress = data ? [ownBlobs storeData:[crypto sealData:data]] : nil;
			if ( !sealedAddress )
				continue;
			NSMutableDictionary *sealedRepresentation = [[representation mutableCopy] autorelease];
			[sealedRepresentation setObject:sealedAddress forKey:@"b"];
			[sealedRepresentation setObject:@YES forKey:@"s"];
			[sealedItem addObject:sealedRepresentation];
		}
		if ( [sealedItem count] )
			[sealedItems addObject:sealedItem];
	}
	if ( [event objectForKey:@"items"] )
		[event setObject:sealedItems forKey:@"items"];
	return YES;
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

// Reads the complete lines appended since the last read, each as {"event", "position"}: the read position
// just past its line. A file that no longer has the bytes the last read ended with was rewritten (compacted,
// or replaced by the sync tool), so it is read from the start; applying an event twice changes nothing.
-(NSArray *) newEventsInFile:(NSString *)name
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
		id event = nil;
		if ( i > lineStart ) {
			NSData *line = [NSData dataWithBytesNoCopy:(void *)(bytes + lineStart) length:i - lineStart freeWhenDone:NO];
			event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
			if ( !([event isKindOfClass:[NSDictionary class]] && [[event objectForKey:@"v"] intValue] == 1) ) {
				NSLog(@"Flycut sync: skipping an unreadable line in %@ at byte %llu", name, offset + lineStart);
				event = nil;
			}
		}
		NSUInteger lineEnd = i + 1;
		lineStart = lineEnd;
		// The last line always gets a position, so the read moves past trailing unreadable lines too.
		if ( !event && lineEnd < end )
			continue;
		NSUInteger tailLength = MIN((NSUInteger)kTailLength, (NSUInteger)(offset + lineEnd));
		NSData *tail = lineEnd >= tailLength ? [data subdataWithRange:NSMakeRange(lineEnd - tailLength, tailLength)] : nil;
		if ( !tail ) {
			// The tail reaches back before this read's start; take it from the file.
			NSFileHandle *again = [NSFileHandle fileHandleForReadingAtPath:path];
			[again seekToFileOffset:offset + lineEnd - tailLength];
			tail = [again readDataOfLength:tailLength];
			[again closeFile];
		}
		[events addObject:@{@"event": event ?: [NSNull null],
							@"position": [NSString stringWithFormat:@"%llu %@", offset + lineEnd, HexString(tail)]}];
	}
	return events;
}

-(void) poll
{
	BOOL changed = NO;
	for ( NSString *name in [self otherLogNames] ) {
		[otherMachines addObject:[name stringByDeletingPathExtension]];
		NSArray *events = [self newEventsInFile:name];
		if ( [events count] == 0 )
			continue;

		NSString *nextPosition = nil;
		[historyDB beginTransaction];
		applyingRemoteChanges = YES;
		for ( NSDictionary *entry in events ) {
			NSDictionary *event = [entry objectForKey:@"event"];
			FlycutEventOutcome outcome = event == (id)[NSNull null] ? FlycutEventIgnored : [self applyEvent:event];
			if ( outcome == FlycutEventWaiting )
				break;
			changed |= outcome == FlycutEventApplied;
			nextPosition = [entry objectForKey:@"position"];
		}
		[self applyPendingChanges];
		applyingRemoteChanges = NO;
		if ( nextPosition )
			[historyDB setMetaValue:nextPosition forKey:[self readPositionKeyForFile:name]];
		[historyDB commitTransaction];
	}
	if ( changed && didApplyRemoteChanges )
		didApplyRemoteChanges();
}

-(FlycutEventOutcome) applyEvent:(NSDictionary *)event
{
	NSString *op = [event objectForKey:@"op"];
	int listNumber = [[event objectForKey:@"list"] intValue];
	if ( listNumber != FlycutHistoryListClippings && listNumber != FlycutHistoryListFavorites )
		return FlycutEventIgnored;
	FlycutHistoryList list = (FlycutHistoryList)listNumber;
	int64_t at = [[event objectForKey:@"at"] longLongValue];
	NSString *machine = [event objectForKey:@"m"];
	if ( ![machine isKindOfClass:[NSString class]] || [machine isEqualToString:machineId] || [machine containsString:@"/"] || [machine hasPrefix:@"."] )
		return FlycutEventIgnored;

	if ( [op isEqualToString:@"clear"] ) {
		[self applyPendingChanges];
		return [self applyClearOfList:list at:at by:machine] ? FlycutEventApplied : FlycutEventIgnored;
	}

	NSString *clipId = [event objectForKey:@"id"];
	if ( ![clipId isKindOfClass:[NSString class]] || [clipId length] == 0 )
		return FlycutEventIgnored;
	FlycutSyncState cleared = [self clearMarkerForList:list];
	if ( !ChangeIsNewer(at, machine, cleared.at, cleared.machine) )
		return FlycutEventIgnored;
	FlycutSyncState state = [historyDB syncStateForClipId:clipId inList:list];
	if ( state.at != 0 && !ChangeIsNewer(at, machine, state.at, state.machine) )
		return FlycutEventIgnored;

	if ( [op isEqualToString:@"put"] ) {
		NSString *contents = [event objectForKey:@"contents"];
		if ( nil == contents && nil != [event objectForKey:@"enc"] )
			contents = [crypto open:[event objectForKey:@"enc"]];
		if ( ![contents isKindOfClass:[NSString class]] || [contents length] == 0 )
			return FlycutEventIgnored;
		BOOL missingData = NO;
		NSArray *items = [self clippingItemsOfEvent:event fromMachine:machine missingData:&missingData];
		if ( missingData && NowMilliseconds() - at < kMissingBlobWaitMilliseconds )
			return FlycutEventWaiting;
		[historyDB setSyncState:(FlycutSyncState){ at, machine, NO } forClipId:clipId inList:list];
		FlycutClipping *clipping = [[FlycutClipping alloc] initWithContents:contents
																   withType:[self stringIn:event forKey:@"type"]
														  withDisplayLength:[[self storeForList:list] displayLen]
													   withAppLocalizedName:[self stringIn:event forKey:@"app"]
														   withAppBundleURL:[self stringIn:event forKey:@"appPath"]
															  withTimestamp:[[event objectForKey:@"ts"] integerValue]];
		[clipping setClipId:clipId];
		[clipping setRank:[[event objectForKey:@"rank"] doubleValue]];
		[clipping setItems:items];
		[clipping setContentsDescribeItems:[[event objectForKey:@"described"] boolValue]];
		[pendingChanges[list] setObject:clipping forKey:clipId];
		[clipping release];
		return FlycutEventApplied;
	}
	if ( [op isEqualToString:@"del"] ) {
		[historyDB setSyncState:(FlycutSyncState){ at, machine, YES } forClipId:clipId inList:list];
		[pendingChanges[list] setObject:[NSNull null] forKey:clipId];
		return FlycutEventApplied;
	}
	return FlycutEventIgnored;
}

// Copies the items' data from the machine's blob directory into the blob store, opening sealed data.
// Data that isn't there sets missingData and is left out, as is data that doesn't open or match its address.
-(NSArray *) clippingItemsOfEvent:(NSDictionary *)event fromMachine:(NSString *)machine missingData:(BOOL *)missingData
{
	NSArray *eventItems = [event objectForKey:@"items"];
	if ( !blobStore || ![eventItems isKindOfClass:[NSArray class]] || [eventItems count] == 0 )
		return nil;
	FlycutBlobStore *machineBlobs = [self blobsOfMachine:machine];
	NSMutableArray *items = [NSMutableArray arrayWithCapacity:[eventItems count]];
	for ( NSArray *eventItem in eventItems ) {
		if ( ![eventItem isKindOfClass:[NSArray class]] )
			continue;
		NSMutableArray *item = [NSMutableArray arrayWithCapacity:[eventItem count]];
		for ( NSDictionary *representation in eventItem ) {
			NSString *type = [representation isKindOfClass:[NSDictionary class]] ? [representation objectForKey:@"t"] : nil;
			NSString *address = [representation isKindOfClass:[NSDictionary class]] ? [representation objectForKey:@"b"] : nil;
			if ( ![type isKindOfClass:[NSString class]] || ![FlycutBlobStore isAddress:address] )
				continue;
			NSData *data = [machineBlobs dataAtAddress:address];
			if ( !data ) {
				*missingData = YES;
				NSString *placeholder = [[machineBlobs directory] stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.icloud", address]];
				if ( [[NSFileManager defaultManager] fileExistsAtPath:placeholder] )
					[[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:[NSURL fileURLWithPath:[machineBlobs pathForAddress:address]] error:nil];
				continue;
			}
			if ( ![[FlycutBlobStore addressOfData:data] isEqualToString:address] )
				continue;
			if ( [[representation objectForKey:@"s"] boolValue] )
				data = [crypto openData:data];
			NSString *localAddress = data ? [blobStore storeData:data] : nil;
			if ( localAddress )
				[item addObject:@{@"t": type, @"b": localAddress, @"n": @([data length])}];
		}
		if ( [item count] )
			[items addObject:item];
	}
	return [items count] ? items : nil;
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

#pragma mark Sealing

// Seals credentials this machine wrote in plain text, once per version of the credential rules, so they
// disappear from the file (and from the server, which the file is mirrored to) rather than only from new lines.
-(void) sealCredentialsInOwnLogIfNeeded
{
	if ( !crypto || !credentialDetector )
		return;
	NSString *doneKey = [NSString stringWithFormat:@"sync-sealed:%d:%@", [credentialDetector rulesVersion], folder];
	if ( nil != [historyDB metaValueForKey:doneKey] )
		return;

	NSData *data = [NSData dataWithContentsOfFile:[self ownLogPath]];
	NSString *text = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
	if ( !text ) {
		[self setLastError:[NSString stringWithFormat:@"cannot read %@ to seal its credentials", [self ownLogPath]]];
		return;
	}
	NSMutableData *rewritten = [NSMutableData dataWithCapacity:[data length]];
	NSUInteger sealedCount = 0;
	for ( NSString *line in [text componentsSeparatedByString:@"\n"] ) {
		if ( [line length] == 0 )
			continue;
		NSMutableDictionary *event = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding]
																	 options:NSJSONReadingMutableContainers error:nil];
		if ( [event isKindOfClass:[NSMutableDictionary class]] && [[event objectForKey:@"op"] isEqual:@"put"] && [self sealContentsOfEvent:event] ) {
			[rewritten appendData:[self lineForEvent:event]];
			sealedCount++;
			continue;
		}
		[rewritten appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
		[rewritten appendBytes:"\n" length:1];
	}
	if ( sealedCount > 0 && ![self replaceOwnLogWith:rewritten] )
		return;
	[historyDB setMetaValue:[NSString stringWithFormat:@"%lu", (unsigned long)sealedCount] forKey:doneKey];
	if ( sealedCount > 0 )
		NSLog(@"Flycut sync: sealed %lu credential clipping(s) in %@", (unsigned long)sealedCount, [self ownLogPath]);
}

// Written beside the file and renamed over it, so readers see the old or the new one.
-(BOOL) replaceOwnLogWith:(NSData *)data
{
	NSString *temporaryPath = [[self ownLogPath] stringByAppendingPathExtension:@"rewriting"];
	if ( ![data writeToFile:temporaryPath atomically:NO]
		|| chmod([temporaryPath fileSystemRepresentation], 0600) != 0
		|| rename([temporaryPath fileSystemRepresentation], [[self ownLogPath] fileSystemRepresentation]) != 0 ) {
		[[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:nil];
		[self setLastError:[NSString stringWithFormat:@"cannot rewrite %@", [self ownLogPath]]];
		return NO;
	}
	return YES;
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

	if ( ![self replaceOwnLogWith:compacted] )
		return;
	NSLog(@"Flycut sync: compacted %@ from %lu to %lu events", [self ownLogPath], (unsigned long)eventCount, (unsigned long)[latest count]);
}

-(void) removeUnreferencedOwnBlobs
{
	NSData *log = [NSData dataWithContentsOfFile:[self ownLogPath]];
	if ( !log )
		return;
	NSUInteger removed = [[self blobsOfMachine:machineId] removeBlobsExcept:[FlycutFolderSync blobAddressesInLog:log] olderThan:kUnreferencedBlobAge];
	if ( removed )
		NSLog(@"Flycut sync: removed %lu blob(s) no line of %@ refers to", (unsigned long)removed, [self ownLogPath]);
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
	[crypto release];
	[credentialDetector release];
	[blobStore release];
	[pendingChanges[FlycutHistoryListClippings] release];
	[pendingChanges[FlycutHistoryListFavorites] release];
	[super dealloc];
}

@end
