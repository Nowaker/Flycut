#import "../FlycutSync.h"
#include <stdio.h>
#include <errno.h>
#include <unistd.h>

static NSUInteger checks;
static NSString *testPrefix;
static NSString *ownershipPath;
static NSMutableArray *ownedItems;
static BOOL liveService;
static id<FlycutSyncTransport> liveFirst, liveSecond;
static FlycutArchive *liveA, *liveB;
static BOOL failDirectoryFlush;

int FlycutTestFsync(int fd) {
    if (failDirectoryFlush) { errno = EIO; return -1; }
    return fsync(fd);
}

static BOOL CleanupLive(void) {
    if (!liveService || !ownedItems.count) return YES;
    BOOL success = YES;
    for (NSDictionary *owned in ownedItems) {
        FlycutArchive *archive = owned[@"archive"];
        NSError *error = nil;
        if ([archive itemWithID:owned[@"id"] error:&error]) success &= [archive deleteItemID:owned[@"id"] error:&error];
    }
    NSError *error = nil;
    success &= [liveFirst synchronizeArchive:liveA error:&error];
    success &= [liveSecond synchronizeArchive:liveB error:&error];
    success &= [liveFirst synchronizeArchive:liveA error:&error];
    success &= [liveSecond synchronizeArchive:liveB error:&error];
    return success;
}

static void Require(BOOL condition, NSString *description) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", description.UTF8String);
        if (!CleanupLive()) fprintf(stderr, "Owned synthetic cleanup failed; retry with the IDs in the test ownership plist.\n");
        exit(1);
    }
    ++checks;
}

static NSDictionary *Capture(FlycutArchive *archive, NSString *text) {
    NSError *error = nil;
    NSDictionary *item = [archive captureText:[testPrefix stringByAppendingString:text] sourceApp:@"Sync driver" sourceID:nil capturedAtMS:@0 favorite:NO error:&error];
    Require(item != nil && !error, @"capture commits");
    [ownedItems addObject:@{@"archive":archive, @"id":item[@"item_id"]}];
    return item;
}

static NSUInteger Count(FlycutArchive *archive) {
    NSError *error = nil;
    NSDictionary *page = [archive searchText:testPrefix favoritesOnly:NO groupDuplicates:NO limit:1000 cursor:nil error:&error];
    Require(page != nil && !error, @"query completes");
    Require(![page[@"has_more"] boolValue], @"driver result fits bounded page");
    return [page[@"items"] count];
}

static void Exchange(id<FlycutSyncTransport> first, id<FlycutSyncTransport> second, FlycutArchive *a, FlycutArchive *b) {
    if (liveService) {
        NSMutableArray *ids = [NSMutableArray array];
        for (NSDictionary *owned in ownedItems) [ids addObject:owned[@"id"]];
        Require([ids writeToFile:ownershipPath atomically:YES], @"owned synthetic IDs recorded before upload");
    }
    NSError *error = nil;
    Require([first synchronizeArchive:a error:&error], @"first replica sync succeeds");
    Require([second synchronizeArchive:b error:&error], @"second replica sync succeeds");
    Require([first synchronizeArchive:a error:&error], @"first replica imports second");
    Require([second synchronizeArchive:b error:&error], @"idempotent second retry succeeds");
}

static void ExerciseReplicas(id<FlycutSyncTransport> first, id<FlycutSyncTransport> second, FlycutArchive *a, FlycutArchive *b) {
    NSError *error = nil;
    NSString *collection = [first prepareCollection:a.collectionID error:&error];
    Require(collection != nil && !error, @"backend manifest opens");
    if (![a.collectionID isEqual:collection]) Require([a adoptCollectionID:collection sharingExistingEvents:YES error:&error], @"explicit first collection sharing");
    NSString *other = [second prepareCollection:b.collectionID error:&error];
    Require([other isEqual:collection], @"both transports identify same collection");
    Capture(b, @"captured before explicit join");
    Require(![b adoptCollectionID:collection sharingExistingEvents:NO error:&error], @"nonempty join without sharing rejects");
    error = nil;
    Require([b adoptCollectionID:collection sharingExistingEvents:YES error:&error], @"explicit second sharing preserves items");
    NSDictionary *favorite = Capture(a, @"favorite retained across clear");
    Require([a setFavorite:YES forItemID:favorite[@"item_id"] error:&error], @"favorite uses stable identity");
    NSDictionary *deleted = Capture(a, @"deleted before remote arrival");
    Require([a deleteItemID:deleted[@"item_id"] error:&error], @"permanent tombstone commits");
    for (NSUInteger index = 0; index < 405; ++index) Capture(a, [NSString stringWithFormat:@"batch item %lu", (unsigned long)index]);
    Capture(b, @"Unicode: \u03bb \u65e5\u672c\u8a9e \U0001f642");
    Exchange(first, second, a, b);
    Require(Count(a) == 408 && Count(b) == 408, @"bounded multiple batches converge with tombstone");
    NSDictionary *remoteFavorite = [b itemWithID:favorite[@"item_id"] error:&error];
    Require([remoteFavorite[@"favorite"] boolValue], @"favorite stable ID converges");
    Require([b itemWithID:deleted[@"item_id"] error:&error] == nil, @"delete stays hidden");
    error = nil;
    NSString *lateID = NSUUID.UUID.UUIDString.lowercaseString;
    NSDictionary *late = @{@"protocol":FlycutArchiveProtocol, @"version":@1, @"collection_id":collection,
        @"event_id":lateID, @"device_id":NSUUID.UUID.UUIDString.lowercaseString, @"clock":@"1", @"op":@"create",
        @"item_id":lateID, @"payload":@{@"text":[testPrefix stringByAppendingString:@"late low-clock event"], @"content_type":@"text/plain", @"captured_at_ms":NSNull.null, @"source_app":NSNull.null, @"source_id":NSNull.null, @"favorite":@NO}};
    Require([b ingestEvents:@[late] backend:nil checkpoint:nil error:&error], @"late lower Lamport event ingests");
    [ownedItems addObject:@{@"archive":b, @"id":lateID}];
    Exchange(second, first, b, a);
    Require(Count(a) == 409 && Count(b) == 409, @"late lower clock delivered after previous sync");
    Require([a resetCheckpointForBackend:first.backendID error:&error], @"explicit replay resets only checkpoint");
    Require([first synchronizeArchive:a error:&error], @"full event replay is idempotent");
    Require(Count(a) == 409, @"replay does not duplicate items");
    if (liveService) {
        for (NSDictionary *owned in ownedItems) {
            if ([owned[@"id"] isEqual:favorite[@"item_id"]]) continue;
            if ([a itemWithID:owned[@"id"] error:&error]) Require([a deleteItemID:owned[@"id"] error:&error], @"only owned nonfavorite IDs are deleted on live service");
        }
    } else Require([a clearHistory:&error], @"clear emits nonfavorite deletes");
    Exchange(first, second, a, b);
    Require(Count(a) == 1 && Count(b) == 1, @"clear converges while favorite survives");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || !strcmp(argv[1], "--help")) {
            puts("usage: sync-driver TEST-DIRECTORY [SERVER-URL COLLECTION-UUID CREDENTIAL-.env [secured-tailnet]]");
            return argc < 2 ? 2 : 0;
        }
        NSString *root = @(argv[1]);
        testPrefix = [NSString stringWithFormat:@"flycut-sync-qa-%@ ", NSUUID.UUID.UUIDString.lowercaseString];
        ownershipPath = [root stringByAppendingPathComponent:@"owned-item-ids.plist"];
        ownedItems = [NSMutableArray array];
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        Require([files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error], @"isolated root created");
        FlycutArchive *a = [[FlycutArchive alloc] initWithPath:[root stringByAppendingPathComponent:@"a.sqlite"] error:&error];
        FlycutArchive *b = [[FlycutArchive alloc] initWithPath:[root stringByAppendingPathComponent:@"b.sqlite"] error:&error];
        Require(a && b && !error, @"isolated archives open");
        NSString *invalidCredentialPath = [root stringByAppendingPathComponent:@".env.invalid-header"];
        Require([@"FLYCUT_SYNC_TOKEN=invalid\0header" writeToFile:invalidCredentialPath atomically:YES encoding:NSUTF8StringEncoding error:&error], @"own invalid-header credential fixture created");
        FlycutServerSync *invalidCredential = [[FlycutServerSync alloc] initWithURL:[NSURL URLWithString:@"http://127.0.0.1:1"] collectionID:a.collectionID credentialFileURL:[NSURL fileURLWithPath:invalidCredentialPath] securedTailnetHTTP:NO];
        error = nil;
        Require([invalidCredential prepareCollection:a.collectionID error:&error] == nil && [error.localizedDescription containsString:@"FLYCUT_SYNC_TOKEN"], @"control characters cannot reach authorization headers");
        Require([files removeItemAtPath:invalidCredentialPath error:&error], @"owned invalid credential fixture removed");
        if (argc >= 5) {
            BOOL tailnet = argc >= 6 && !strcmp(argv[5], "secured-tailnet");
            FlycutServerSync *first = [[FlycutServerSync alloc] initWithURL:[NSURL URLWithString:@(argv[2])] collectionID:@(argv[3]) credentialFileURL:[NSURL fileURLWithPath:@(argv[4])] securedTailnetHTTP:tailnet];
            FlycutServerSync *second = [[FlycutServerSync alloc] initWithURL:[NSURL URLWithString:@(argv[2])] collectionID:@(argv[3]) credentialFileURL:[NSURL fileURLWithPath:@(argv[4])] securedTailnetHTTP:tailnet];
            liveService = YES;
            liveFirst = first; liveSecond = second; liveA = a; liveB = b;
            ExerciseReplicas(first, second, a, b);
            NSString *large = [@"x" stringByPaddingToLength:500 * 1024 withString:@"x" startingAtIndex:0];
            for (NSUInteger index = 0; index < 20; ++index) Capture(a, [NSString stringWithFormat:@"large-%lu %@", (unsigned long)index, large]);
            Exchange(first, second, a, b);
            Require(Count(a) == 21 && Count(b) == 21, @"more than 8 MiB of individually valid events converge through byte-bounded POST batches");
            FlycutServerSync *bad = [[FlycutServerSync alloc] initWithURL:[NSURL URLWithString:@"http://public.example.invalid"] collectionID:a.collectionID credentialFileURL:[NSURL fileURLWithPath:@(argv[4])] securedTailnetHTTP:YES];
            error = nil;
            Require([bad prepareCollection:a.collectionID error:&error] == nil && error != nil, @"public plaintext endpoint rejects before I/O");
            Require(CleanupLive(), @"all owned synthetic IDs tombstoned and uploaded without clearing unrelated history");
            Require(Count(a) == 0 && Count(b) == 0, @"no owned synthetic item remains visible");
            NSString *oversized = [@"y" stringByPaddingToLength:8 * 1024 * 1024 + 1024 withString:@"y" startingAtIndex:0];
            Capture(a, oversized);
            long long before = [[a checkpointForBackend:first.backendID error:&error][@"upload_sequence"] longLongValue];
            error = nil;
            Require(![first synchronizeArchive:a error:&error] && error.code == 413, @"single unsupported event gets explicit size error");
            Require([[a checkpointForBackend:first.backendID error:NULL][@"upload_sequence"] longLongValue] == before, @"unsupported size never advances upload checkpoint");
            liveService = NO;
        } else {
            NSString *faultFolder = [root stringByAppendingPathComponent:@"fault-folder"];
            Require([files createDirectoryAtPath:faultFolder withIntermediateDirectories:NO attributes:nil error:&error], @"fault-injection folder created");
            FlycutArchive *faultArchive = [[FlycutArchive alloc] initWithPath:[root stringByAppendingPathComponent:@"fault.sqlite"] error:&error];
            FlycutFolderSync *faultTransport = [[FlycutFolderSync alloc] initWithDirectoryURL:[NSURL fileURLWithPath:faultFolder]];
            Require([faultTransport prepareCollection:faultArchive.collectionID error:&error] != nil, @"fault manifest established before flush failure");
            Capture(faultArchive, @"unacknowledged parent flush test");
            failDirectoryFlush = YES;
            error = nil;
            Require(![faultTransport synchronizeArchive:faultArchive error:&error] && error != nil, @"parent directory flush failure surfaces safely");
            failDirectoryFlush = NO;
            Require([[faultArchive checkpointForBackend:faultTransport.backendID error:NULL][@"upload_sequence"] longLongValue] == 0, @"failed parent flush cannot advance durable upload acknowledgement");
            error = nil;
            Require([faultTransport synchronizeArchive:faultArchive error:&error], @"existing child directory flush retries before acknowledgement");
            [ownedItems removeAllObjects];
            NSString *folder = [root stringByAppendingPathComponent:@"folder"];
            Require([files createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:&error], @"explicit sync folder created");
            FlycutFolderSync *first = [[FlycutFolderSync alloc] initWithDirectoryURL:[NSURL fileURLWithPath:folder]];
            FlycutFolderSync *second = [[FlycutFolderSync alloc] initWithDirectoryURL:[NSURL fileURLWithPath:folder]];
            ExerciseReplicas(first, second, a, b);
            NSString *events = [folder stringByAppendingPathComponent:@"events"];
            NSString *saved = [folder stringByAppendingPathComponent:@"saved-events"];
            Require([files moveItemAtPath:events toPath:saved error:&error], @"test moves its own event tree");
            NSString *outside = [root stringByAppendingPathComponent:@"outside"];
            Require([files createDirectoryAtPath:outside withIntermediateDirectories:NO attributes:nil error:&error], @"outside sentinel directory created");
            Require([files createSymbolicLinkAtPath:events withDestinationPath:outside error:&error], @"test creates malicious events symlink");
            Capture(a, @"must not escape selected folder");
            error = nil;
            Require(![first synchronizeArchive:a error:&error] && error != nil, @"symlink traversal fails explicitly");
            Require([[files contentsOfDirectoryAtPath:outside error:&error] count] == 0, @"no event escaped confinement");
            Require([files removeItemAtPath:events error:&error] && [files moveItemAtPath:saved toPath:events error:&error], @"owned symlink restored safely");
            error = nil;
            Require([first synchronizeArchive:a error:&error], @"failed unacknowledged publication retries");
            NSDictionary *page = [a eventsAfterSequence:0 limit:1 error:&error];
            NSDictionary *event = [page[@"events"] firstObject];
            NSString *eventID = event[@"event_id"];
            NSString *eventPath = [[events stringByAppendingPathComponent:[eventID substringToIndex:2]] stringByAppendingPathComponent:[eventID stringByAppendingString:@".json"]];
            NSMutableDictionary *conflict = [event mutableCopy];
            NSMutableDictionary *payload = [event[@"payload"] mutableCopy];
            payload[@"text"] = @"conflicting immutable text";
            conflict[@"payload"] = payload;
            NSData *data = [NSJSONSerialization dataWithJSONObject:conflict options:0 error:&error];
            Require([data writeToFile:eventPath atomically:YES], @"test corrupts only its own event");
            error = nil;
            Require(![first synchronizeArchive:a error:&error] && error != nil, @"conflicting rescan fails instead of overwrite");
        }
        NSDictionary *manifest = @{@"protocol":FlycutArchiveProtocol, @"version":@YES, @"collection_id":a.collectionID};
        error = nil;
        Require(!FlycutSyncValidateManifest(manifest, &error), @"boolean protocol version is rejected");
        printf("PASS: %lu transport checks; isolated replicas, immutable retries, late clocks, favorites, tombstones and safe replay\n", (unsigned long)checks);
    }
    return 0;
}
