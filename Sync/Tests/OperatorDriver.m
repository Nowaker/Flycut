#ifndef FLYCUT_MAC
#define FLYCUT_MAC
#endif
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "../../FlycutOperator.h"
#import "../../FlycutEngine/FlycutArchive.h"
#import "../FlycutSync.h"

static NSUserDefaults *isolatedDefaults;
@interface NSUserDefaults (Driver)
+ (NSUserDefaults *)driverDefaults;
@end
@implementation NSUserDefaults (Driver)
+ (NSUserDefaults *)driverDefaults { return isolatedDefaults; }
@end

@interface AppController : NSObject
+ (BOOL)isAppSandboxed;
@end
@implementation AppController
+ (BOOL)isAppSandboxed { return NO; }
@end

static NSUInteger checks;
static FlycutOperator *liveOperator;
static NSString *liveOwnedID;
static void Check(BOOL condition, const char *name) {
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", name);
        if (liveOwnedID && [[liveOperator archive] itemWithID:liveOwnedID error:NULL]) {
            [[liveOperator archive] deleteItemID:liveOwnedID error:NULL];
            [[liveOperator syncController] synchronize];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:40];
            while ([liveOperator syncController].busy && deadline.timeIntervalSinceNow > 0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        exit(1);
    }
    ++checks;
}
static BOOL AwaitFor(NSTimeInterval seconds, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}
static BOOL Await(BOOL (^condition)(void)) { return AwaitFor(25, condition); }
static NSUInteger Count(FlycutOperator *operator) {
    return [[[operator archive] searchText:@"" favoritesOnly:NO groupDuplicates:NO limit:1000 cursor:nil error:NULL][@"items"] count];
}

static void RunLiveOperator(NSString *root, NSString *url, NSString *collection, NSString *credentialFile, NSString *marker) {
    NSString *emptyLegacy = [root stringByAppendingPathComponent:@"empty-legacy.plist"];
    [@{} writeToFile:emptyLegacy atomically:YES];
    setenv("FLYCUT_LEGACY_DEFAULTS_PATH", emptyLegacy.UTF8String, 1);
    setenv("FLYCUT_ARCHIVE_PATH", [root stringByAppendingPathComponent:@"live-operator.sqlite"].UTF8String, 1);
    liveOperator = [[FlycutOperator alloc] init];
    [liveOperator awakeFromNibDisplaying:10 withDisplayLength:40 withSaveSelector:NULL forTarget:nil];
    [liveOperator seedObservedClipboard:@"private-driver-startup-baseline"];
    NSString *macText = [marker stringByAppendingString:@" mac"];
    Check([liveOperator addClipping:macText ofType:@"text/plain" fromApp:@"Mac Operator QA" withAppBundleURL:nil target:nil clippingAddedSelector:NULL], "actual Operator capture queued for cross-platform sync");
    Check(Await(^BOOL{ return [liveOperator archive] != nil && [liveOperator jcListCount] == 1; }), "actual Operator archive capture and projection ready");
    liveOwnedID = [[[liveOperator clippingAtStackPosition] itemID] copy];
    Check(liveOwnedID != nil, "actual Operator capture has stable UUID");
    [@{@"mac_item_id":liveOwnedID, @"marker":marker} writeToFile:[root stringByAppendingPathComponent:@"owned-live-item.plist"] atomically:YES];
    FlycutSyncController *controller = [liveOperator syncController];
    FlycutServerSync *transport = [[FlycutServerSync alloc] initWithURL:[NSURL URLWithString:url] collectionID:collection credentialFileURL:[NSURL fileURLWithPath:credentialFile] securedTailnetHTTP:YES];
    [controller configureTransport:transport sharingExistingEvents:YES completion:nil];
    Check(AwaitFor(120, ^BOOL{ return controller.connected && !controller.busy; }), "actual Operator sync controller uploads to live Linux host service");
    puts("PROGRESS: actual Mac Operator uploaded its owned item; awaiting Linux peer capture");
    fflush(stdout);
    NSString *linuxText = [marker stringByAppendingString:@" linux"];
    __block NSString *linuxID = nil;
    Check(AwaitFor(180, ^BOOL {
        NSDictionary *page = [[liveOperator archive] searchText:linuxText favoritesOnly:NO groupDuplicates:NO limit:10 cursor:nil error:NULL];
        for (NSDictionary *item in page[@"items"]) if ([item[@"text"] isEqual:linuxText]) { linuxID = [item[@"item_id"] copy]; return YES; }
        return NO;
    }), "actual Operator imports real Linux peer event through live service");
    Check(![linuxID isEqual:liveOwnedID], "cross-platform capture identities remain distinct");
    Check(Await(^BOOL{
        for (int index = 0; index < [liveOperator jcListCount]; ++index) {
            if ([[liveOperator clippingStringWithCount:index] isEqual:macText]) return [liveOperator setStackPositionTo:index];
        }
        return NO;
    }), "actual Operator locates its stable item after remote projection refresh");
    Check([liveOperator saveFromStackToFavorites], "actual Operator favorite action targets original UUID");
    Check(Await(^BOOL{ return [[[liveOperator archive] itemWithID:liveOwnedID error:NULL][@"favorite"] boolValue]; }), "favorite commits in actual Operator archive");
    Check(AwaitFor(120, ^BOOL{ return !controller.busy; }), "live controller finishes existing poll before explicit upload");
    [controller synchronize];
    Check(AwaitFor(120, ^BOOL{ return !controller.busy; }) && [controller.status isEqual:@"Up to date"], "actual Operator favorite replicated to live service");
    [@{@"mac_item_id":liveOwnedID, @"linux_item_id":linuxID, @"phase":@"mac-favorited"} writeToFile:[root stringByAppendingPathComponent:@"live-phase.plist"] atomically:YES];
    Check(AwaitFor(180, ^BOOL {
        NSDictionary *page = [[liveOperator archive] searchText:[marker stringByAppendingString:@" linux-saw-favorite"] favoritesOnly:NO groupDuplicates:NO limit:10 cursor:nil error:NULL];
        return [page[@"items"] count] > 0;
    }), "Linux peer observes stable favorite before own Mac tombstone");
    Check(Await(^BOOL{
        for (int index = 0; index < [liveOperator jcListCount]; ++index) {
            if ([[liveOperator clippingStringWithCount:index] isEqual:macText]) return [liveOperator setStackPositionTo:index];
        }
        return NO;
    }), "actual Operator resolves same UUID before explicit delete");
    Check([liveOperator clearItemAtStackPosition], "actual Operator deletes only owned Mac item");
    Check(Await(^BOOL{ return [[liveOperator archive] itemWithID:liveOwnedID error:NULL] == nil; }), "owned Mac tombstone committed");
    [controller synchronize];
    Check(AwaitFor(120, ^BOOL{ return !controller.busy; }) && [controller.status isEqual:@"Up to date"], "owned Mac tombstone uploaded");
    [@{@"mac_item_id":liveOwnedID, @"linux_item_id":linuxID, @"phase":@"mac-deleted"} writeToFile:[root stringByAppendingPathComponent:@"live-phase.plist"] atomically:YES];
    puts("PROGRESS: actual Mac Operator imported Linux capture and uploaded own tombstone; awaiting Linux cleanup");
    fflush(stdout);
    Check(AwaitFor(180, ^BOOL{ return [[liveOperator archive] itemWithID:linuxID error:NULL] == nil; }), "actual Operator imports Linux peer tombstone");
    Check(AwaitFor(180, ^BOOL {
        return [[[liveOperator archive] searchText:marker favoritesOnly:NO groupDuplicates:NO limit:10 cursor:nil error:NULL][@"items"] count] == 0;
    }), "all owned cross-platform synthetic items hidden without unrelated history deletion");
    [liveOperator applicationWillTerminate];
    liveOwnedID = nil;
    printf("PASS %lu actual Operator-to-Linux live-service checks; no clipboard or real preferences accessed\n", (unsigned long)checks);
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2 && argc != 6) return 2;
        NSString *root = @(argv[1]);
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *suite = [@"net.nowaker.flycut.operator-qa." stringByAppendingString:NSUUID.UUID.UUIDString];
        isolatedDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        method_exchangeImplementations(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), class_getClassMethod(NSUserDefaults.class, @selector(driverDefaults)));
        if (argc == 6) {
            RunLiveOperator(root, @(argv[2]), @(argv[3]), @(argv[4]), @(argv[5]));
            [isolatedDefaults removePersistentDomainForName:suite];
            return 0;
        }
        [isolatedDefaults setInteger:2 forKey:@"rememberNum"];
        [isolatedDefaults setInteger:2 forKey:@"favoritesRememberNum"];
        [isolatedDefaults setObject:@{@"sentinel":@"unchanged"} forKey:@"store"];
        NSMutableArray *rows = [NSMutableArray array];
        for (int index = 7; index >= 0; --index) [rows addObject:@{@"Contents":[NSString stringWithFormat:@"legacy-%d",index], @"Type":@"public.utf8-plain-text", @"Timestamp":@(index)}];
        NSDictionary *raw = @{@"rememberNum":@2, @"store":@{@"jcList":rows, @"favoritesList":@[rows[3]]}};
        NSString *legacy = [root stringByAppendingPathComponent:@"legacy.plist"];
        [raw writeToFile:legacy atomically:YES];
        setenv("FLYCUT_LEGACY_DEFAULTS_PATH", legacy.UTF8String, 1);
        setenv("FLYCUT_ARCHIVE_PATH", [root stringByAppendingPathComponent:@"archive.sqlite"].UTF8String, 1);
        FlycutOperator *operator = [[FlycutOperator alloc] init];
        [operator awakeFromNibDisplaying:10 withDisplayLength:30 withSaveSelector:NULL forTarget:nil];
        [operator seedObservedClipboard:@"startup-seed"];
        Check(![operator addClipping:@"startup-seed" ofType:@"text/plain" fromApp:nil withAppBundleURL:nil target:nil clippingAddedSelector:NULL], "startup baseline not recaptured");
        Check([operator addClipping:@"queued-before-ready" ofType:@"text/plain" fromApp:nil withAppBundleURL:nil target:nil clippingAddedSelector:NULL], "early capture queued");
        Check(Await(^BOOL{ return [operator syncController] != nil && Count(operator) == 9 && [operator jcListCount] == 2; }), "early capture and uncapped migration durable, projection bounded");
        Check([[operator clippingAtStackPosition] itemID] != nil, "projection stable identity");
        Check([[[operator archive] legacyDefaultsBackup:NULL] isEqual:raw], "entire raw defaults backup retained");
        FlycutArchive *remote = [[FlycutArchive alloc] initWithPath:[root stringByAppendingPathComponent:@"remote.sqlite"] error:NULL];
        [remote adoptCollectionID:[operator archive].collectionID sharingExistingEvents:NO error:NULL];
        [remote captureText:@"same-as-import" sourceApp:nil sourceID:nil capturedAtMS:nil favorite:NO error:NULL];
        [[operator archive] ingestEvents:[remote eventsAfterSequence:0 limit:200 error:NULL][@"events"] backend:nil checkpoint:nil error:NULL];
        Check(Await(^BOOL{ return Count(operator) == 10; }), "remote import retained");
        Check([operator addClipping:@"same-as-import" ofType:@"text/plain" fromApp:nil withAppBundleURL:nil target:nil clippingAddedSelector:NULL], "global imported latest does not suppress local capture");
        Check(Await(^BOOL{ return Count(operator) == 11; }), "local duplicate content has new identity");
        Check(![operator addClipping:@"same-as-import" ofType:@"text/plain" fromApp:nil withAppBundleURL:nil target:nil clippingAddedSelector:NULL], "consecutive local content suppressed");
        [operator seedObservedClipboard:@"app-pasted-other"];
        Check([operator addClipping:@"same-as-import" ofType:@"text/plain" fromApp:nil withAppBundleURL:nil target:nil clippingAddedSelector:NULL], "recopy after own paste has separate capture");
        Check(Await(^BOOL{ return Count(operator) == 12; }), "recopy durable");
        Check(Await(^BOOL{ return [[[operator clippingAtStackPosition] contents] isEqual:@"same-as-import"]; }), "projection refreshes committed capture");
        NSString *favoriteID = [[[operator clippingAtStackPosition] itemID] copy];
        Check([operator saveFromStackToFavorites], "favorite action queued");
        Check(Await(^BOOL{ return [[[operator archive] itemWithID:favoriteID error:NULL][@"favorite"] boolValue]; }), "favorite references same item instead of delete/create");
        [operator setRememberNum:1 forPrimaryStore:YES];
        Check(Await(^BOOL{ return [operator jcListCount] == 1; }) && Count(operator) == 12, "projection shrink never deletes archive");
        [operator saveEngine];
        Check([[isolatedDefaults dictionaryForKey:@"store"] isEqual:@{@"sentinel":@"unchanged"}], "legacy history defaults writes stopped");
        [operator clearList];
        Check(Await(^BOOL{ return Count(operator) == 2; }), "clear retains both migrated and new favorites");
        [operator setRememberNum:2 forPrimaryStore:YES];
        Check(Await(^BOOL{ return [operator jcListCount] == 2; }), "two-row projection for selection regression");
        Check([operator setStackPositionTo:1], "nonzero selection established");
        NSArray *remaining = [[operator archive] searchText:@"" favoritesOnly:NO groupDuplicates:NO limit:10 cursor:nil error:NULL][@"items"];
        for (NSDictionary *item in remaining) [[operator archive] deleteItemID:item[@"item_id"] error:NULL];
        Check(Await(^BOOL{ return [operator jcListCount] == 0; }) && [operator stackPosition] == 0, "empty projection clamps selection to zero");
        [remote captureText:@"remote-after-empty" sourceApp:nil sourceID:nil capturedAtMS:nil favorite:NO error:NULL];
        [[operator archive] ingestEvents:[remote eventsAfterSequence:0 limit:200 error:NULL][@"events"] backend:nil checkpoint:nil error:NULL];
        Check(Await(^BOOL{ return [operator jcListCount] == 1; }) && [operator stackPositionIsInBounds], "imported nonempty projection keeps valid selection");
        Check([operator clippingAtStackPosition] != nil && ![operator setStackPositionTo:-1] && ![operator setStackPositionTo:1], "stable item action rejects lower and upper invalid indexes");
        FlycutSyncController *controller = [[FlycutSyncController alloc] initWithArchive:[operator archive]];
        NSString *folderA = [root stringByAppendingPathComponent:@"sync-a"];
        NSString *folderB = [root stringByAppendingPathComponent:@"sync-b"];
        [[NSFileManager defaultManager] createDirectoryAtPath:folderA withIntermediateDirectories:NO attributes:nil error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:folderB withIntermediateDirectories:NO attributes:nil error:NULL];
        FlycutFolderSync *transportB = [[FlycutFolderSync alloc] initWithDirectoryURL:[NSURL fileURLWithPath:folderB]];
        [controller configureTransport:transportB sharingExistingEvents:NO completion:nil];
        Check(Await(^BOOL{ return controller.connected && !controller.busy; }), "first backend synchronizes");
        Check([[[operator archive] checkpointForBackend:transportB.backendID error:NULL][@"upload_sequence"] longLongValue] > 0, "first backend acknowledgement established");
        [controller configureTransport:[[FlycutFolderSync alloc] initWithDirectoryURL:[NSURL fileURLWithPath:folderA]] sharingExistingEvents:NO completion:nil];
        Check(Await(^BOOL{ return controller.connected && !controller.busy; }), "second backend selected and remembered");
        [controller stop];
        FlycutSyncController *restarted = [[FlycutSyncController alloc] initWithArchive:[operator archive]];
        __block BOOL completionCalled = NO, resetObserved = NO;
        [restarted configureTransport:transportB sharingExistingEvents:NO completion:^(NSError *error) {
            completionCalled = YES;
            resetObserved = !error && [[[operator archive] checkpointForBackend:transportB.backendID error:NULL][@"upload_sequence"] longLongValue] == 0;
        }];
        Check(Await(^BOOL{ return completionCalled; }) && resetObserved, "backend switch resets destination checkpoint across controller restart");
        Check(Await(^BOOL{ return !restarted.busy; }), "restart replay finishes");
        [restarted stop];
        NSString *offlineFolder = [root stringByAppendingPathComponent:@"offline-folder"];
        FlycutSyncController *offline = [[FlycutSyncController alloc] initWithArchive:[operator archive]];
        __block NSUInteger connectCallbacks = 0;
        [offline configureTransport:[[FlycutFolderSync alloc] initWithDirectoryURL:[NSURL fileURLWithPath:offlineFolder]] sharingExistingEvents:NO completion:^(NSError *error) {
            ++connectCallbacks;
        }];
        Check(Await(^BOOL{ return connectCallbacks == 1 && !offline.busy; }) && !offline.connected, "offline connect failure is visible and pending, not falsely connected");
        [[NSFileManager defaultManager] createDirectoryAtPath:offlineFolder withIntermediateDirectories:NO attributes:nil error:NULL];
        Check(Await(^BOOL{ return offline.connected && !offline.busy; }) && connectCallbacks == 2, "real retry timer reconnects when folder becomes available without relaunch");
        [offline stop];
        [operator applicationWillTerminate];
        NSString *blocked = [root stringByAppendingPathComponent:@"blocked-parent"];
        [@"not a directory" writeToFile:blocked atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        setenv("FLYCUT_ARCHIVE_PATH", [blocked stringByAppendingPathComponent:@"archive.sqlite"].UTF8String, 1);
        FlycutOperator *failed = [[FlycutOperator alloc] init];
        [failed awakeFromNibDisplaying:10 withDisplayLength:30 withSaveSelector:NULL forTarget:nil];
        Check(Await(^BOOL{ return [failed archiveError] != nil; }) && [failed storeDisabled] && [failed jcListCount] == 0, "storage failure disables capture without writable legacy fallback");
        Check(![failed addClipping:@"must not enter legacy fallback" ofType:@"text/plain" fromApp:nil withAppBundleURL:nil target:nil clippingAddedSelector:NULL], "failed storage cannot report accepted capture");
        [failed applicationWillTerminate];
        [isolatedDefaults removePersistentDomainForName:suite];
        printf("PASS %lu operator checks; async migration/capture, stable favorites, local suppression, bounded projection and no defaults history writes; no clipboard accessed\n", (unsigned long)checks);
    }
    return 0;
}
