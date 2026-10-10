#import "FlycutSync.h"
#include <arpa/inet.h>

static BOOL ServerError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:FlycutSyncErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

@implementation FlycutServerSync {
    NSURL *_url;
    NSString *_collectionID;
    NSString *_credentialFile;
    NSURL *_credentialURL;
    BOOL _securedTailnetHTTP;
}
- (instancetype)initWithURL:(NSURL *)url collectionID:(NSString *)collectionID credentialFileURL:(NSURL *)credentialFile securedTailnetHTTP:(BOOL)securedTailnetHTTP {
    if ((self = [super init])) {
        _url = [url copy];
        _collectionID = [collectionID copy];
        _credentialURL = credentialFile;
        _credentialFile = [credentialFile.path copy];
        _securedTailnetHTTP = securedTailnetHTTP;
    }
    return self;
}
- (NSString *)backendID {
    return [NSString stringWithFormat:@"server:%@:%@", _url.absoluteString, _collectionID];
}
- (NSString *)credential:(NSError **)error {
    BOOL accessed = [_credentialURL startAccessingSecurityScopedResource];
    if (FlycutSyncIsSandboxed() && !accessed) { ServerError(error, 1, @"Credential sandbox access is unavailable. Choose the .env file again."); return nil; }
    @try { return [self credentialWithAccess:error]; }
    @finally { if (accessed) [_credentialURL stopAccessingSecurityScopedResource]; }
}
- (NSString *)credentialWithAccess:(NSError **)error {
    if (![_credentialFile.lastPathComponent hasPrefix:@".env"]) {
        ServerError(error, 1, @"Choose a dedicated .env file containing FLYCUT_SYNC_TOKEN."); return nil;
    }
    NSString *contents = [NSString stringWithContentsOfFile:_credentialFile encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [contents componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if ([line hasPrefix:@"FLYCUT_SYNC_TOKEN="]) {
            NSString *token = [line substringFromIndex:@"FLYCUT_SYNC_TOKEN=".length];
            NSCharacterSet *characters = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/="];
            if (token.length && [token rangeOfCharacterFromSet:characters.invertedSet].location == NSNotFound) return token;
        }
    }
    ServerError(error, 1, @"Credential file unavailable or FLYCUT_SYNC_TOKEN is missing. Credentials are never saved in preferences.");
    return nil;
}
- (NSDictionary *)requestMethod:(NSString *)method cursor:(NSString *)cursor events:(NSArray *)events error:(NSError **)error {
    NSURLComponents *components = [NSURLComponents componentsWithURL:_url resolvingAgainstBaseURL:NO];
    BOOL loopback = [@[@"localhost", @"127.0.0.1", @"::1", @"[::1]"] containsObject:components.host.lowercaseString];
    struct in_addr address;
    BOOL tailnet = components.host && inet_pton(AF_INET, components.host.UTF8String, &address) == 1 && (ntohl(address.s_addr) & 0xffc00000U) == 0x64400000U;
    if (![components.scheme.lowercaseString isEqual:@"https"] && !([components.scheme.lowercaseString isEqual:@"http"] && (loopback || (_securedTailnetHTTP && tailnet)))) {
        ServerError(error, 1, @"Sync requires HTTPS except on loopback or an explicitly secured tailnet connection."); return nil;
    }
    if (components.user || components.password || components.query || components.fragment ||
        (components.path.length && ![components.path isEqual:@"/"])) {
        ServerError(error, 1, @"Use a server origin URL without credentials, path, query, or fragment."); return nil;
    }
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:_collectionID];
    if (!uuid || ![uuid.UUIDString.lowercaseString isEqual:_collectionID]) {
        ServerError(error, 1, @"Collection must be a lowercase UUID."); return nil;
    }
    NSString *token = [self credential:error];
    if (!token) return nil;
    components.path = [NSString stringWithFormat:@"/v1/collections/%@%@", _collectionID, events || cursor ? @"/events" : @""];
    if ([method isEqual:@"GET"] && cursor) {
        NSMutableArray *query = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"200"]];
        if (cursor.length) [query addObject:[NSURLQueryItem queryItemWithName:@"after" value:cursor]];
        components.queryItems = query;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    request.HTTPMethod = method;
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    if (events) {
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:events options:0 error:error];
        if (!request.HTTPBody) return nil;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData *data;
    __block NSInteger status;
    __block NSError *networkError;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *received, NSURLResponse *response, NSError *failure) {
        data = received;
        status = [(NSHTTPURLResponse *)response statusCode];
        networkError = failure;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC))) {
        [task cancel]; [session invalidateAndCancel];
        ServerError(error, FlycutSyncTransientError, @"Server request timed out; it will be retried."); return nil;
    }
    [session finishTasksAndInvalidate];
    if (networkError) { ServerError(error, FlycutSyncTransientError, @"Server unavailable or TLS validation failed; it will be retried."); return nil; }
    if (status < 200 || status >= 300) {
        NSString *message = status == 400 ? @"Server rejected cursor or event. Reset this backend checkpoint explicitly to replay." :
            status == 401 ? @"Server authentication failed. Check the selected .env credential file." :
            status == 403 ? @"This credential is not authorized for the collection." :
            status == 409 ? @"Conflicting immutable event on server. No upload was acknowledged." : @"Server request failed; it will be retried.";
        ServerError(error, status >= 500 || status == 429 ? FlycutSyncTransientError : status, message); return nil;
    }
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class]) { ServerError(error, 1, @"Invalid server response."); return nil; }
    return json;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
- (NSString *)prepareCollection:(NSString *)localCollection error:(NSError **)error {
    NSDictionary *manifest = [self requestMethod:@"GET" cursor:nil events:nil error:error];
    if (!manifest) return nil;
    if (!FlycutSyncValidateManifest(manifest, error) || ![manifest[@"collection_id"] isEqual:_collectionID]) {
        ServerError(error, 1, @"Unsupported or mismatched server manifest."); return nil;
    }
    return _collectionID;
}
- (BOOL)synchronizeArchive:(FlycutArchive *)archive error:(NSError **)error {
    if (![archive.collectionID isEqual:_collectionID]) return ServerError(error, 1, @"Reconnect explicitly to select this collection.");
    NSDictionary *checkpoint = [archive checkpointForBackend:self.backendID error:error];
    if (!checkpoint) return NO;
    __block long long sequence = [checkpoint[@"upload_sequence"] longLongValue];
    while (YES) {
        __block BOOL more = NO;
        BOOL success = FlycutSyncPerformBatch(^BOOL(NSError **batchError) {
            NSUInteger limit = 200;
            NSDictionary *page;
            while (YES) {
                page = [archive eventsAfterSequence:sequence limit:limit error:batchError];
                if (!page) return NO;
                NSArray *events = page[@"events"];
                NSData *body = [NSJSONSerialization dataWithJSONObject:events options:0 error:batchError];
                if (!body) return NO;
                if (body.length <= 8 * 1024 * 1024) break;
                if (events.count <= 1) return ServerError(batchError, 413, @"One archive event exceeds the server's 8 MiB request limit. No upload was acknowledged; folder sync can retain larger events.");
                limit = MAX(1, events.count / 2);
            }
            NSArray *events = page[@"events"];
            if (events.count) {
                NSDictionary *response = [self requestMethod:@"POST" cursor:nil events:events error:batchError];
                if (!response) return NO;
                if (![response[@"accepted"] isKindOfClass:NSNumber.class] || [response[@"accepted"] unsignedIntegerValue] != events.count)
                    return ServerError(batchError, 1, @"Server did not acknowledge the complete event batch.");
            }
            sequence = [page[@"next_sequence"] longLongValue];
            if (![archive acknowledgeUploadThroughSequence:sequence backend:self.backendID error:batchError]) return NO;
            more = [page[@"has_more"] boolValue];
            return YES;
        }, error);
        if (!success) return NO;
        if (!more) break;
    }
    __block NSString *cursor = [checkpoint[@"download_cursor"] isKindOfClass:NSString.class] ? checkpoint[@"download_cursor"] : @"";
    while (YES) {
        __block BOOL more = NO;
        BOOL success = FlycutSyncPerformBatch(^BOOL(NSError **batchError) {
            NSDictionary *response = [self requestMethod:@"GET" cursor:cursor events:nil error:batchError];
            if (!response) return NO;
            NSArray *events = response[@"events"];
            NSString *next = response[@"next_cursor"];
            if (![events isKindOfClass:NSArray.class] || events.count > 200 || ![next isKindOfClass:NSString.class] || ![response[@"has_more"] isKindOfClass:NSNumber.class])
                return ServerError(batchError, 1, @"Malformed server event page.");
            if ([response[@"has_more"] boolValue] && [next isEqual:cursor]) return ServerError(batchError, 1, @"Server cursor did not advance.");
            if (![archive ingestEvents:events backend:self.backendID checkpoint:next error:batchError]) return NO;
            cursor = next;
            more = [response[@"has_more"] boolValue];
            return YES;
        }, error);
        if (!success) return NO;
        if (!more) break;
    }
    return YES;
}
@end
