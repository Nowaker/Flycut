#import "FlycutSync.h"
#import <Security/Security.h>

NSString * const FlycutSyncErrorDomain = @"net.nowaker.flycut.sync";
NSString * const FlycutSyncStatusDidChangeNotification = @"FlycutSyncStatusDidChangeNotification";

BOOL FlycutSyncValidateManifest(NSDictionary *manifest, NSError **error) {
    id version = manifest[@"version"];
    NSString *collection = manifest[@"collection_id"];
    NSUUID *uuid = [collection isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:collection] : nil;
    BOOL valid = manifest.count == 3 && [manifest[@"protocol"] isEqual:FlycutArchiveProtocol] &&
        [version isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)version) != CFBooleanGetTypeID() &&
        !CFNumberIsFloatType((__bridge CFNumberRef)version) && [version isEqual:@1] && uuid && [uuid.UUIDString.lowercaseString isEqual:collection];
    if (!valid && error) *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported or malformed sync collection manifest."}];
    return valid;
}

BOOL FlycutSyncIsSandboxed(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return NO;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.app-sandbox"), NULL);
    CFRelease(task);
    BOOL sandboxed = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
    if (value) CFRelease(value);
    return sandboxed;
}

BOOL FlycutSyncPerformBatch(BOOL (^operation)(NSError **), NSError **error) {
    NSError *failure = nil;
    BOOL success;
    @autoreleasepool { success = operation(&failure); }
    if (error) *error = failure;
    return success;
}

NSURL *FlycutSyncResolveFileURL(NSString *path, NSData *bookmark, BOOL readOnly,
                             NSData **refreshedBookmark, NSError **error) {
    if (!path.length) {
        if (error) *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"Choose an existing folder or credential file before connecting."}];
        return nil;
    }
    BOOL stale = NO;
    NSURL *url = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:error] : nil;
    if (bookmark && !url) return nil;
    if (url && ![url.path.stringByStandardizingPath isEqual:path.stringByStandardizingPath]) url = nil;
    if (!url) {
        if (FlycutSyncIsSandboxed()) {
            if (error) *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"Choose the folder or credential file again to grant sandbox access. A saved path is not authorization."}];
            return nil;
        }
        return [NSURL fileURLWithPath:path];
    }
    if (stale && refreshedBookmark) {
        BOOL accessed = [url startAccessingSecurityScopedResource];
        NSURLBookmarkCreationOptions options = NSURLBookmarkCreationWithSecurityScope | (readOnly ? NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess : 0);
        NSData *refreshed = [url bookmarkDataWithOptions:options includingResourceValuesForKeys:nil relativeToURL:nil error:error];
        if (accessed) [url stopAccessingSecurityScopedResource];
        if (!refreshed) return nil;
        *refreshedBookmark = refreshed;
    }
    return url;
}

@implementation FlycutSyncController {
    NSOperationQueue *_queue;
    id<FlycutSyncTransport> _transport;
    NSTimer *_timer;
    NSString *_status;
    BOOL _busy;
    NSUInteger _generation;
    NSString *_lastBackendID;
    id<FlycutSyncTransport> _pendingTransport;
    BOOL _pendingShare;
    void (^_pendingCompletion)(NSError *);
}

- (instancetype)initWithArchive:(FlycutArchive *)archive {
    if ((self = [super init])) {
        _archive = archive;
        _lastBackendID = [[[NSUserDefaults standardUserDefaults] stringForKey:@"archiveSyncLastBackendID"] copy];
        _status = @"Sync off";
        _queue = [[NSOperationQueue alloc] init];
        _queue.maxConcurrentOperationCount = 1;
        _queue.qualityOfService = NSQualityOfServiceUtility;
    }
    return self;
}

- (NSString *)status { return _status; }
- (BOOL)busy { return _busy; }
- (BOOL)connected { return _transport != nil; }

- (void)setStatus:(NSString *)status busy:(BOOL)busy {
    NSAssert([NSThread isMainThread], @"Sync status belongs to the main thread");
    _status = [status copy];
    _busy = busy;
    [[NSNotificationCenter defaultCenter] postNotificationName:FlycutSyncStatusDidChangeNotification object:self];
}

- (void)configureTransport:(id<FlycutSyncTransport>)transport sharingExistingEvents:(BOOL)share
               completion:(void (^)(NSError *))completion {
    [self stop];
    NSUInteger generation = _generation;
    [self setStatus:@"Connecting..." busy:YES];
    [_queue addOperationWithBlock:^{
        NSError *error = nil;
        NSString *collection = [transport prepareCollection:self.archive.collectionID error:&error];
        if (!collection && !error) error = [NSError errorWithDomain:FlycutSyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:@"No usable sync backend is configured."}];
        if (collection && ![collection isEqualToString:self.archive.collectionID]) {
            [self.archive adoptCollectionID:collection sharingExistingEvents:share error:&error];
        }
        if (collection && !error && self->_lastBackendID && ![self->_lastBackendID isEqual:transport.backendID]) {
            [self.archive resetCheckpointForBackend:transport.backendID error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            if (error || !collection) {
                [self setStatus:[NSString stringWithFormat:@"Sync error: %@", error.localizedDescription ?: @"No collection"] busy:NO];
                if ([error.domain isEqual:FlycutSyncErrorDomain] && error.code == FlycutSyncTransientError) {
                    self->_pendingTransport = transport;
                    self->_pendingShare = share;
                    self->_pendingCompletion = [completion copy];
                    self->_timer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(retryConnection) userInfo:nil repeats:NO];
                }
            } else {
                self->_transport = transport;
                self->_lastBackendID = [transport.backendID copy];
                [[NSUserDefaults standardUserDefaults] setObject:self->_lastBackendID forKey:@"archiveSyncLastBackendID"];
                [self setStatus:@"Connected" busy:NO];
                self->_timer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(synchronize) userInfo:nil repeats:YES];
            }
            if (completion) completion(error);
            if (!error && collection) [self synchronize];
        });
    }];
}

- (void)resetCheckpoint {
    if (!_transport || _busy) return;
    id<FlycutSyncTransport> transport = _transport;
    NSUInteger generation = _generation;
    [self setStatus:@"Resetting checkpoint for full replay..." busy:YES];
    [_queue addOperationWithBlock:^{
        NSError *error = nil;
        BOOL success = [self.archive resetCheckpointForBackend:transport.backendID error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            [self setStatus:success ? @"Checkpoint reset" : [NSString stringWithFormat:@"Sync error: %@", error.localizedDescription] busy:NO];
            if (success) [self synchronize];
        });
    }];
}

- (void)synchronize {
    if (!_transport || _busy) return;
    NSUInteger generation = _generation;
    id<FlycutSyncTransport> transport = _transport;
    [self setStatus:@"Syncing..." busy:YES];
    [_queue addOperationWithBlock:^{
        NSError *error = nil;
        BOOL success = [transport synchronizeArchive:self.archive error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            [self setStatus:success ? @"Up to date" : [NSString stringWithFormat:@"Sync error: %@", error.localizedDescription ?: @"Transport failed"] busy:NO];
        });
    }];
}

- (void)retryConnection {
    if (!_pendingTransport || _busy) return;
    id<FlycutSyncTransport> transport = _pendingTransport;
    BOOL share = _pendingShare;
    void (^completion)(NSError *) = _pendingCompletion;
    [self configureTransport:transport sharingExistingEvents:share completion:completion];
}

- (void)stop {
    ++_generation;
    [_timer invalidate];
    _timer = nil;
    _transport = nil;
    _pendingTransport = nil;
    _pendingCompletion = nil;
    [self setStatus:@"Sync off" busy:NO];
}

- (void)failConfiguration:(NSError *)error {
    [self stop];
    [self setStatus:[NSString stringWithFormat:@"Sync error: %@", error.localizedDescription] busy:NO];
}

- (void)dealloc { [_timer invalidate]; }
@end
