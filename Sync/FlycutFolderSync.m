#import "FlycutSync.h"
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL FolderError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static NSData *ReadFileAt(int directory, NSString *name, NSError **error) {
    int fd = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { FolderError(error, @"Cannot read sync file (missing, unavailable, or symlink)."); return nil; }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode)) {
        close(fd); FolderError(error, @"Sync entry is not a regular file."); return nil;
    }
    NSMutableData *data = [NSMutableData data];
    char buffer[65536];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) [data appendBytes:buffer length:(NSUInteger)count];
    close(fd);
    if (count < 0) { FolderError(error, @"Sync file read failed; it will be retried."); return nil; }
    return data;
}

static NSDictionary *ReadJSONAt(int directory, NSString *name, NSError **error) {
    NSData *data = ReadFileAt(directory, name, error);
    if (!data) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:[NSDictionary class]]) { FolderError(error, @"Sync JSON must be an object."); return nil; }
    return json;
}

// linkat publishes without replacing another writer's immutable file. All child
// lookups are relative to open, non-symlink directory descriptors.
static BOOL PublishJSON(int directory, NSString *name, NSDictionary *json, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:error];
    if (!data) return NO;
    NSString *temporary = [@".flycut-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    int fd = openat(directory, temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return FolderError(error, @"Cannot create sync file.");
    const char *bytes = data.bytes;
    NSUInteger remaining = data.length;
    BOOL success = YES;
    while (remaining) {
        ssize_t written = write(fd, bytes, remaining);
        if (written <= 0) { success = NO; break; }
        remaining -= (NSUInteger)written;
        bytes += written;
    }
    if (fsync(fd)) success = NO;
    close(fd);
    if (success && linkat(directory, temporary.fileSystemRepresentation, directory, name.fileSystemRepresentation, 0)) {
        if (errno == EEXIST) {
            NSDictionary *existing = ReadJSONAt(directory, name, error);
            success = existing && (json[@"event_id"] ? [FlycutArchive validateEvent:existing error:error] : FlycutSyncValidateManifest(existing, error)) && [existing isEqual:json];
            if (!success) FolderError(error, @"Conflicting immutable sync file; nothing was overwritten.");
        } else success = NO;
    }
    unlinkat(directory, temporary.fileSystemRepresentation, 0);
    if (success && fsync(directory)) success = NO;
    if (!success && (!error || !*error)) FolderError(error, @"Sync file publication failed; it will be retried.");
    return success;
}

static int OpenDirectoryAt(int parent, NSString *name, BOOL create, NSError **error) {
    if (create && mkdirat(parent, name.fileSystemRepresentation, 0700) && errno != EEXIST) {
        FolderError(error, @"Cannot create sync directory."); return -1;
    }
    int fd = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) FolderError(error, @"Sync directory is unavailable or a symlink.");
    if (fd >= 0 && create && fsync(parent)) {
        close(fd); FolderError(error, @"Cannot durably publish sync directory; upload was not acknowledged."); return -1;
    }
    return fd;
}

@implementation FlycutFolderSync {
    NSString *_directory;
    NSURL *_directoryURL;
    NSString *_collectionID;
}
- (instancetype)initWithDirectoryURL:(NSURL *)directory {
    if ((self = [super init])) { _directoryURL = directory; _directory = [directory.path copy]; }
    return self;
}
- (NSString *)backendID { return [@"folder:" stringByAppendingString:_directory]; }
- (int)openRoot:(NSError **)error {
    int fd = open(_directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        int failure = errno;
        FolderError(error, @"Choose an existing, non-symlink sync folder.");
        if ((failure == ENOENT || failure == EIO || failure == ENXIO) && error)
            *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:FlycutSyncTransientError userInfo:@{NSLocalizedDescriptionKey:@"Choose an existing, non-symlink sync folder. Unavailable folders retry automatically."}];
    }
    return fd;
}
- (NSString *)prepareCollection:(NSString *)localCollection error:(NSError **)error {
    BOOL accessed = [_directoryURL startAccessingSecurityScopedResource];
    if (FlycutSyncIsSandboxed() && !accessed) { FolderError(error, @"Folder sandbox access is unavailable. Choose the folder again."); return nil; }
    @try { return [self prepareCollectionWithAccess:localCollection error:error]; }
    @finally { if (accessed) [_directoryURL stopAccessingSecurityScopedResource]; }
}
- (NSString *)prepareCollectionWithAccess:(NSString *)localCollection error:(NSError **)error {
    int root = [self openRoot:error];
    if (root < 0) return nil;
    struct stat st;
    if (fstatat(root, "manifest.json", &st, AT_SYMLINK_NOFOLLOW) && errno == ENOENT) {
        if (!PublishJSON(root, @"manifest.json", @{ @"protocol":FlycutArchiveProtocol, @"version":@1, @"collection_id":localCollection }, error)) { close(root); return nil; }
    }
    NSDictionary *manifest = ReadJSONAt(root, @"manifest.json", error);
    close(root);
    NSString *collection = manifest[@"collection_id"];
    if (!manifest || !FlycutSyncValidateManifest(manifest, error)) return nil;
    _collectionID = [collection copy];
    return collection;
}
- (BOOL)synchronizeArchive:(FlycutArchive *)archive error:(NSError **)error {
    BOOL accessed = [_directoryURL startAccessingSecurityScopedResource];
    if (FlycutSyncIsSandboxed() && !accessed) return FolderError(error, @"Folder sandbox access is unavailable. Choose the folder again.");
    @try { return [self synchronizeArchiveWithAccess:archive error:error]; }
    @finally { if (accessed) [_directoryURL stopAccessingSecurityScopedResource]; }
}
- (BOOL)synchronizeArchiveWithAccess:(FlycutArchive *)archive error:(NSError **)error {
    NSString *collection = [self prepareCollection:archive.collectionID error:error];
    if (!collection) return NO;
    if (![collection isEqual:archive.collectionID]) return FolderError(error, @"Folder collection changed. Reconnect explicitly before sharing history.");
    int root = [self openRoot:error];
    if (root < 0) return NO;
    int eventsDirectory = OpenDirectoryAt(root, @"events", YES, error);
    close(root);
    if (eventsDirectory < 0) return NO;
    NSDictionary *checkpoint = [archive checkpointForBackend:self.backendID error:error];
    BOOL success = checkpoint != nil;
    __block long long sequence = [checkpoint[@"upload_sequence"] longLongValue];
    while (success) {
        __block BOOL more = NO;
        success = FlycutSyncPerformBatch(^BOOL(NSError **batchError) {
            NSDictionary *page = [archive eventsAfterSequence:sequence limit:200 error:batchError];
            if (!page) return NO;
            for (NSDictionary *event in page[@"events"]) {
                NSString *eventID = event[@"event_id"];
                int shard = OpenDirectoryAt(eventsDirectory, [eventID substringToIndex:2], YES, batchError);
                if (shard < 0) return NO;
                BOOL published = PublishJSON(shard, [eventID stringByAppendingString:@".json"], event, batchError);
                close(shard);
                if (!published) return NO;
            }
            sequence = [page[@"next_sequence"] longLongValue];
            if (![archive acknowledgeUploadThroughSequence:sequence backend:self.backendID error:batchError]) return NO;
            more = [page[@"has_more"] boolValue];
            return YES;
        }, error);
        if (!more) break;
    }
    // Rescan all shards every time. No filename/mtime high-water mark can hide
    // delayed files or older Lamport events written by an offline device.
    DIR *shards = success ? fdopendir(dup(eventsDirectory)) : NULL;
    if (success && !shards) success = FolderError(error, @"Cannot enumerate sync folder.");
    struct dirent *entry;
    while (success && (entry = readdir(shards))) {
        NSString *name = @(entry->d_name);
        if ([name hasPrefix:@"."]) continue;
        NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        if (name.length != 2 || [name rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) continue;
        int shard = OpenDirectoryAt(eventsDirectory, name, NO, error);
        if (shard < 0) { success = NO; break; }
        DIR *files = fdopendir(dup(shard));
        if (!files) { close(shard); success = FolderError(error, @"Cannot enumerate sync shard."); break; }
        NSMutableArray *batch = [NSMutableArray arrayWithCapacity:200];
        struct dirent *file;
        while (success && (file = readdir(files))) {
            success = FlycutSyncPerformBatch(^BOOL(NSError **batchError) {
                NSString *filename = @(file->d_name);
                if (![filename.pathExtension isEqual:@"json"] || [filename hasPrefix:@"."]) return YES;
                NSDictionary *event = ReadJSONAt(shard, filename, batchError);
                if (!event || ![FlycutArchive validateEvent:event error:batchError]) return NO;
                if (![filename isEqual:[event[@"event_id"] stringByAppendingString:@".json"]] || ![event[@"event_id"] hasPrefix:name]) {
                    return FolderError(batchError, @"Event path does not match its immutable ID.");
                }
                [batch addObject:event];
                if (batch.count == 200) {
                    BOOL ingested = [archive ingestEvents:batch backend:nil checkpoint:nil error:batchError];
                    [batch removeAllObjects];
                    return ingested;
                }
                return YES;
            }, error);
        }
        if (success && batch.count) success = [archive ingestEvents:batch backend:nil checkpoint:nil error:error];
        closedir(files);
        close(shard);
    }
    if (shards) closedir(shards);
    close(eventsDirectory);
    return success;
}
@end
