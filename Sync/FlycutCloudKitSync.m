#import "FlycutSync.h"
#if FLYCUT_CLOUDKIT
#import <CloudKit/CloudKit.h>
#import <Security/Security.h>

static BOOL CloudError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static BOOL CloudRetryError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:FlycutSyncTransientError userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static BOOL HasCloudEntitlements(NSString *identifier) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return NO;
    id containers = CFBridgingRelease(SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.icloud-container-identifiers"), NULL));
    id services = CFBridgingRelease(SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.icloud-services"), NULL));
    CFRelease(task);
    return [containers isKindOfClass:NSArray.class] && [containers containsObject:identifier] &&
        [services isKindOfClass:NSArray.class] && [services containsObject:@"CloudKit"];
}

@implementation FlycutCloudKitSync {
    NSString *_identifier;
    CKDatabase *_database;
    CKRecordZoneID *_zoneID;
    NSDate *_retryAfter;
    NSString *_accountID;
}
- (instancetype)initWithContainerIdentifier:(NSString *)identifier {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _zoneID = [[CKRecordZoneID alloc] initWithZoneName:@"FlycutArchiveV1" ownerName:CKCurrentUserDefaultName];
    }
    return self;
}
- (NSString *)backendID { return [NSString stringWithFormat:@"cloudkit:%@:%@", _identifier, _accountID ?: @"unconfigured"]; }
- (NSString *)currentAccount:(NSError **)error {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block CKRecordID *recordID;
    __block NSError *failure;
    [[CKContainer containerWithIdentifier:_identifier] fetchUserRecordIDWithCompletionHandler:^(CKRecordID *user, NSError *requestError) {
        recordID = user; failure = requestError; dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC))) {
        CloudRetryError(error, @"CloudKit account lookup timed out; connection will retry."); return nil;
    }
    if (!recordID) { [self reportError:failure output:error]; return nil; }
    return recordID.recordName;
}
- (BOOL)reportError:(NSError *)failure output:(NSError **)error {
    NSNumber *retry = failure.userInfo[CKErrorRetryAfterKey];
    if (retry) _retryAfter = [NSDate dateWithTimeIntervalSinceNow:retry.doubleValue];
    BOOL transient = retry || failure.code == CKErrorNetworkUnavailable || failure.code == CKErrorNetworkFailure ||
        failure.code == CKErrorServiceUnavailable || failure.code == CKErrorRequestRateLimited || failure.code == CKErrorZoneBusy;
    NSString *message = [NSString stringWithFormat:@"CloudKit request failed (code %ld). %@", (long)failure.code,
        transient ? @"Pending events retry after the server's delay." : @"Check sign-in and provisioning, then Apply to reconnect."];
    return transient ? CloudRetryError(error, message) : CloudError(error, message);
}
- (BOOL)runOperation:(CKDatabaseOperation *)operation semaphore:(dispatch_semaphore_t)done error:(NSError **)error {
    operation.configuration.timeoutIntervalForRequest = 30;
    operation.configuration.timeoutIntervalForResource = 60;
    [_database addOperation:operation];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 65 * NSEC_PER_SEC))) {
        [operation cancel];
        return CloudRetryError(error, @"CloudKit timed out; unacknowledged events will retry.");
    }
    return YES;
}
- (CKRecord *)fetchRecord:(CKRecordID *)recordID error:(NSError **)error {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block CKRecord *record;
    __block NSError *failure;
    CKFetchRecordsOperation *operation = [[CKFetchRecordsOperation alloc] initWithRecordIDs:@[recordID]];
    operation.fetchRecordsCompletionBlock = ^(NSDictionary<CKRecordID *, CKRecord *> *records, NSError *operationError) {
        record = records[recordID];
        failure = operationError;
        dispatch_semaphore_signal(done);
    };
    if (![self runOperation:operation semaphore:done error:error]) return nil;
    if (!record && failure) [self reportError:failure output:error];
    return record;
}
- (NSString *)prepareCollection:(NSString *)localCollection error:(NSError **)error {
    if (_retryAfter && [_retryAfter timeIntervalSinceNow] > 0) {
        CloudRetryError(error, @"CloudKit retry delay is active. Reconnection will retry after the server's delay."); return nil;
    }
    NSCharacterSet *characters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    if (![_identifier hasPrefix:@"iCloud."] || _identifier.length <= 7 || [_identifier rangeOfCharacterFromSet:characters.invertedSet].location != NSNotFound) {
        CloudError(error, @"Enter your provisioned iCloud container identifier."); return nil;
    }
    if (!HasCloudEntitlements(_identifier)) {
        CloudError(error, @"CloudKit is not provisioned. Install a signed build for this container."); return nil;
    }
    _accountID = [self currentAccount:error];
    if (!_accountID) return nil;
    if (!_database) _database = [[CKContainer containerWithIdentifier:_identifier] privateCloudDatabase];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *failure;
    CKModifyRecordZonesOperation *zones = [[CKModifyRecordZonesOperation alloc] initWithRecordZonesToSave:@[[[CKRecordZone alloc] initWithZoneID:_zoneID]] recordZoneIDsToDelete:nil];
    zones.modifyRecordZonesCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *operationError) {
        failure = operationError; dispatch_semaphore_signal(done);
    };
    if (![self runOperation:zones semaphore:done error:error]) return nil;
    if (failure) { [self reportError:failure output:error]; return nil; }
    CKRecordID *manifestID = [[CKRecordID alloc] initWithRecordName:@"manifest" zoneID:_zoneID];
    CKRecord *manifest = [[CKRecord alloc] initWithRecordType:@"FlycutManifest" recordID:manifestID];
    manifest[@"protocol"] = FlycutArchiveProtocol;
    manifest[@"version"] = @1;
    manifest[@"collection_id"] = localCollection;
    done = dispatch_semaphore_create(0);
    CKModifyRecordsOperation *save = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[manifest] recordIDsToDelete:nil];
    save.savePolicy = CKRecordSaveIfServerRecordUnchanged;
    save.atomic = YES;
    save.modifyRecordsCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *operationError) {
        failure = operationError; dispatch_semaphore_signal(done);
    };
    if (![self runOperation:save semaphore:done error:error]) return nil;
    if (failure) {
        NSError *itemFailure = failure.code == CKErrorPartialFailure ? failure.userInfo[CKPartialErrorsByItemIDKey][manifestID] : failure;
        if (itemFailure.code != CKErrorServerRecordChanged) { [self reportError:failure output:error]; return nil; }
        manifest = [self fetchRecord:manifestID error:error];
        if (!manifest) return nil;
    }
    NSString *collection = manifest[@"collection_id"];
    NSDictionary *fields = @{ @"protocol":manifest[@"protocol"] ?: NSNull.null, @"version":manifest[@"version"] ?: NSNull.null, @"collection_id":collection ?: NSNull.null };
    if (!FlycutSyncValidateManifest(fields, error)) return nil;
    return collection;
}
- (NSDictionary *)eventFromRecord:(CKRecord *)record error:(NSError **)error {
    if (![record.recordType isEqual:@"FlycutEvent"]) { CloudError(error, @"Unexpected CloudKit record type."); return nil; }
    CKAsset *asset = record[@"json"];
    if (![asset isKindOfClass:CKAsset.class] || !asset.fileURL) { CloudError(error, @"CloudKit event asset is unavailable; it will retry."); return nil; }
    NSData *data = [NSData dataWithContentsOfURL:asset.fileURL options:0 error:error];
    if (!data) return nil;
    id event = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![event isKindOfClass:NSDictionary.class] || ![FlycutArchive validateEvent:event error:error]) return nil;
    if (![record.recordID.recordName isEqual:event[@"event_id"]]) { CloudError(error, @"CloudKit event UUID does not match its record ID."); return nil; }
    return event;
}
- (BOOL)uploadEvents:(NSArray *)events error:(NSError **)error {
    NSMutableArray *records = [NSMutableArray array];
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"FlycutSync-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    BOOL success = YES;
    for (NSDictionary *event in events) {
        CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:event[@"event_id"] zoneID:_zoneID];
        CKRecord *record = [[CKRecord alloc] initWithRecordType:@"FlycutEvent" recordID:recordID];
        NSString *path = [directory stringByAppendingPathComponent:event[@"event_id"]];
        NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:error];
        if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) { success = NO; break; }
        record[@"json"] = [[CKAsset alloc] initWithFileURL:[NSURL fileURLWithPath:path]];
        [records addObject:record];
        byID[recordID] = event;
    }
    if (success) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSArray *savedRecords;
        __block NSError *failure;
        CKModifyRecordsOperation *save = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:records recordIDsToDelete:nil];
        save.atomic = NO;
        save.savePolicy = CKRecordSaveIfServerRecordUnchanged;
        save.modifyRecordsCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *operationError) {
            savedRecords = saved; failure = operationError; dispatch_semaphore_signal(done);
        };
        success = [self runOperation:save semaphore:done error:error];
        if (success) {
            NSMutableSet *confirmed = [NSMutableSet set];
            for (CKRecord *record in savedRecords) [confirmed addObject:record.recordID];
            NSDictionary *partial = failure.userInfo[CKPartialErrorsByItemIDKey];
            for (CKRecordID *recordID in byID) {
                if ([confirmed containsObject:recordID]) continue;
                NSError *itemError = partial[recordID] ?: failure;
                if (itemError.code == CKErrorServerRecordChanged) {
                    CKRecord *existing = [self fetchRecord:recordID error:error];
                    NSDictionary *remote = existing ? [self eventFromRecord:existing error:error] : nil;
                    if (remote && [remote isEqual:byID[recordID]]) continue;
                    if (remote) CloudError(error, @"Conflicting immutable CloudKit event. Nothing was overwritten.");
                } else if (itemError) [self reportError:itemError output:error];
                else CloudError(error, @"CloudKit did not confirm a durable event write.");
                success = NO;
                break;
            }
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    return success;
}
- (BOOL)synchronizeArchive:(FlycutArchive *)archive error:(NSError **)error {
    if (!_accountID) return CloudError(error, @"Connect an entitled CloudKit configuration before syncing.");
    if (_retryAfter && [_retryAfter timeIntervalSinceNow] > 0) return CloudError(error, @"CloudKit retry delay is active. Pending events remain local.");
    NSString *account = [self currentAccount:error];
    if (!account) return NO;
    if (![account isEqual:_accountID]) return CloudError(error, @"The iCloud account changed. Reconnect explicitly in Sync Settings before sharing history with that account.");
    CKRecord *manifest = [self fetchRecord:[[CKRecordID alloc] initWithRecordName:@"manifest" zoneID:_zoneID] error:error];
    if (!manifest) return NO;
    NSDictionary *fields = @{ @"protocol":manifest[@"protocol"] ?: NSNull.null, @"version":manifest[@"version"] ?: NSNull.null,
        @"collection_id":manifest[@"collection_id"] ?: NSNull.null };
    if (!FlycutSyncValidateManifest(fields, error)) return NO;
    if (![fields[@"collection_id"] isEqual:archive.collectionID]) return CloudError(error, @"CloudKit collection changed. Reconnect explicitly before sharing history.");
    NSDictionary *checkpoint = [archive checkpointForBackend:self.backendID error:error];
    if (!checkpoint) return NO;
    __block long long sequence = [checkpoint[@"upload_sequence"] longLongValue];
    while (YES) {
        __block BOOL more = NO;
        BOOL success = FlycutSyncPerformBatch(^BOOL(NSError **batchError) {
            NSDictionary *page = [archive eventsAfterSequence:sequence limit:200 error:batchError];
            if (!page) return NO;
            if ([page[@"events"] count] && ![self uploadEvents:page[@"events"] error:batchError]) return NO;
            sequence = [page[@"next_sequence"] longLongValue];
            if (![archive acknowledgeUploadThroughSequence:sequence backend:self.backendID error:batchError]) return NO;
            more = [page[@"has_more"] boolValue];
            return YES;
        }, error);
        if (!success) return NO;
        if (!more) break;
    }
    __block CKServerChangeToken *token = nil;
    if ([checkpoint[@"download_cursor"] isKindOfClass:NSString.class]) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:checkpoint[@"download_cursor"] options:0];
        token = data ? [NSKeyedUnarchiver unarchivedObjectOfClass:CKServerChangeToken.class fromData:data error:error] : nil;
        if (!token) return CloudError(error, @"Invalid CloudKit checkpoint. Explicitly reset this backend to replay.");
    }
    __block BOOL replayed = NO;
    while (YES) {
        __block BOOL more = NO;
        BOOL success = FlycutSyncPerformBatch(^BOOL(NSError **batchError) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            CKFetchRecordZoneChangesOperation *fetch;
            if (@available(macOS 10.14, *)) {
                CKFetchRecordZoneChangesConfiguration *configuration = [[CKFetchRecordZoneChangesConfiguration alloc] init];
                configuration.previousServerChangeToken = token;
                configuration.resultsLimit = 200;
                fetch = [[CKFetchRecordZoneChangesOperation alloc] initWithRecordZoneIDs:@[_zoneID] configurationsByRecordZoneID:@{_zoneID:configuration}];
            } else {
                CKFetchRecordZoneChangesOptions *options = [[CKFetchRecordZoneChangesOptions alloc] init];
                options.previousServerChangeToken = token;
                options.resultsLimit = 200;
                fetch = [[CKFetchRecordZoneChangesOperation alloc] initWithRecordZoneIDs:@[_zoneID] optionsByRecordZoneID:@{_zoneID:options}];
            }
            fetch.fetchAllChanges = NO;
            NSMutableArray *events = [NSMutableArray array];
            __block NSError *failure;
            __block NSError *eventError;
            __block CKServerChangeToken *next;
            void (^receiveRecord)(CKRecord *, NSError *) = ^(CKRecord *record, NSError *recordError) {
                if (eventError) return;
                if (recordError) { eventError = recordError; return; }
                if ([record.recordID.recordName isEqual:@"manifest"]) return;
                NSDictionary *event = [self eventFromRecord:record error:&eventError];
                if (event) [events addObject:event];
            };
            if (@available(macOS 12.0, *)) fetch.recordWasChangedBlock = ^(CKRecordID *recordID, CKRecord *record, NSError *recordError) { receiveRecord(record, recordError); };
            else fetch.recordChangedBlock = ^(CKRecord *record) { receiveRecord(record, nil); };
            fetch.recordWithIDWasDeletedBlock = ^(CKRecordID *recordID, NSString *type) {
                CloudError(&eventError, @"An immutable CloudKit record was removed outside Flycut. Sync requires repair; archive items remain intact.");
            };
            fetch.recordZoneFetchCompletionBlock = ^(CKRecordZoneID *zone, CKServerChangeToken *newToken, NSData *clientToken, BOOL hasMore, NSError *operationError) {
                next = newToken; more = hasMore; failure = operationError;
            };
            fetch.fetchRecordZoneChangesCompletionBlock = ^(NSError *operationError) {
                if (!failure) failure = operationError;
                dispatch_semaphore_signal(done);
            };
            if (![self runOperation:fetch semaphore:done error:batchError]) return NO;
            if (failure) {
                NSError *zoneError = failure.code == CKErrorPartialFailure ? failure.userInfo[CKPartialErrorsByItemIDKey][_zoneID] : failure;
                if (zoneError.code == CKErrorChangeTokenExpired && !replayed) { token = nil; replayed = YES; more = YES; return YES; }
                return [self reportError:failure output:batchError];
            }
            if (eventError) { if (batchError) *batchError = eventError; return NO; }
            if (!next) return CloudError(batchError, @"CloudKit did not return a durable change token.");
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:next requiringSecureCoding:YES error:batchError];
            if (!data || ![archive ingestEvents:events backend:self.backendID checkpoint:[data base64EncodedStringWithOptions:0] error:batchError]) return NO;
            token = next;
            return YES;
        }, error);
        if (!success) return NO;
        if (!more) break;
    }
    return YES;
}
@end
#endif
