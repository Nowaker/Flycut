//
//  FlycutServerMirror.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutServerMirror.h"
#import <Security/Security.h>
#include <sys/stat.h>
#include <netdb.h>
#include <arpa/inet.h>

static const NSUInteger kTailLength = 32;
static NSString *const kUploadStateName = @".upload-state.json";

@implementation FlycutServerMirror {
	NSString *token;
	NSString *machineId;
	NSURLSession *session;
	dispatch_queue_t queue;
	NSTimer *timer;
	BOOL roundInFlight;
}

@synthesize localFolder, serverURL, lastError;

+(NSString *) localFolderForServerURL:(NSURL *)aServerURL
{
	NSString *appSupport = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
	NSCharacterSet *unsafe = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-."] invertedSet];
	NSString *name = [[[NSString stringWithFormat:@"%@%@", [aServerURL host] ?: @"server", [aServerURL path] ?: @""]
					   componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
	if ( [aServerURL port] )
		name = [name stringByAppendingFormat:@"_%@", [aServerURL port]];
	return [[[appSupport stringByAppendingPathComponent:[[NSBundle mainBundle] bundleIdentifier]]
			 stringByAppendingPathComponent:@"ServerSync"] stringByAppendingPathComponent:name];
}

#pragma mark Keychain

+(NSDictionary *) keychainQueryForServerURL:(NSURL *)aServerURL
{
	return @{(id)kSecClass: (id)kSecClassGenericPassword,
			 (id)kSecAttrService: [[[NSBundle mainBundle] bundleIdentifier] stringByAppendingString:@".sync-server"],
			 (id)kSecAttrAccount: [aServerURL absoluteString] ?: @""};
}

+(NSString *) tokenForServerURL:(NSURL *)aServerURL
{
	if ( !aServerURL )
		return nil;
	NSMutableDictionary *query = [[[self keychainQueryForServerURL:aServerURL] mutableCopy] autorelease];
	[query setObject:@YES forKey:(id)kSecReturnData];
	[query setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];
	CFTypeRef data = NULL;
	if ( SecItemCopyMatching((CFDictionaryRef)query, &data) != errSecSuccess || !data )
		return nil;
	NSString *value = [[[NSString alloc] initWithData:(NSData *)data encoding:NSUTF8StringEncoding] autorelease];
	CFRelease(data);
	return value;
}

+(void) setToken:(NSString *)aToken forServerURL:(NSURL *)aServerURL
{
	if ( !aServerURL )
		return;
	NSDictionary *query = [self keychainQueryForServerURL:aServerURL];
	SecItemDelete((CFDictionaryRef)query);
	if ( [aToken length] == 0 )
		return;
	NSMutableDictionary *item = [[query mutableCopy] autorelease];
	[item setObject:[aToken dataUsingEncoding:NSUTF8StringEncoding] forKey:(id)kSecValueData];
	[item setObject:(id)kSecAttrAccessibleAfterFirstUnlock forKey:(id)kSecAttrAccessible];
	OSStatus status = SecItemAdd((CFDictionaryRef)item, NULL);
	if ( status != errSecSuccess )
		NSLog(@"Flycut sync: cannot store the server token in the keychain (%d)", (int)status);
}

#pragma mark Lifecycle

-(instancetype) initWithServerURL:(NSURL *)aServerURL token:(NSString *)aToken localFolder:(NSString *)aLocalFolder machineId:(NSString *)aMachineId
{
	self = [super init];
	if ( !self )
		return nil;
	serverURL = [aServerURL retain];
	token = [aToken copy];
	localFolder = [aLocalFolder copy];
	machineId = [aMachineId copy];
	NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	configuration.timeoutIntervalForRequest = 20;
	configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
	session = [[NSURLSession sessionWithConfiguration:configuration] retain];
	queue = dispatch_queue_create("net.nowaker.flycut.server-mirror", DISPATCH_QUEUE_SERIAL);
	[[NSFileManager defaultManager] createDirectoryAtPath:localFolder withIntermediateDirectories:YES
											   attributes:@{NSFilePosixPermissions: @0700} error:nil];
	return self;
}

-(void) startWithInterval:(NSTimeInterval)interval onDownload:(void (^)(void))onDownload
{
	[self stop];
	void (^handler)(void) = [[onDownload copy] autorelease];
	timer = [[NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) {
		[self syncWithCompletion:^(BOOL downloaded) {
			if ( downloaded && handler )
				handler();
		}];
	}] retain];
	[[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

-(void) stop
{
	[timer invalidate];
	[timer release];
	timer = nil;
}

-(void) syncWithCompletion:(void (^)(BOOL downloaded))completion
{
	// A slow server must not pile up rounds behind each other.
	if ( roundInFlight )
		return;
	roundInFlight = YES;
	void (^handler)(BOOL) = [[completion copy] autorelease];
	[self retain];
	dispatch_async(queue, ^{
		NSString *error = nil;
		BOOL downloaded = NO;
		@autoreleasepool {
			downloaded = [self runRoundWithError:&error];
			[error retain];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self setLastError:error];
			[error release];
			roundInFlight = NO;
			if ( handler )
				handler(downloaded);
			[self release];
		});
	});
}

-(void) setLastError:(NSString *)error
{
	if ( error && ![error isEqualToString:lastError] )
		NSLog(@"Flycut sync: %@", error);
	NSString *old = lastError;
	lastError = [error copy];
	[old release];
}

#pragma mark HTTP

-(NSURL *) URLForPath:(NSString *)path query:(NSString *)query
{
	NSURLComponents *components = [NSURLComponents componentsWithURL:serverURL resolvingAgainstBaseURL:NO];
	NSString *base = [components path] ?: @"";
	if ( [base hasSuffix:@"/"] )
		base = [base substringToIndex:[base length] - 1];
	components.path = [base stringByAppendingString:path];
	components.query = query;
	return [components URL];
}

// Synchronous, on the mirror's own queue.
-(NSData *) request:(NSString *)method path:(NSString *)path query:(NSString *)query body:(NSData *)body
			headers:(NSDictionary *)headers response:(NSHTTPURLResponse **)responseOut error:(NSString **)errorOut
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self URLForPath:path query:query]];
	request.HTTPMethod = method;
	request.HTTPBody = body;
	[request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
	for ( NSString *name in headers )
		[request setValue:[headers objectForKey:name] forHTTPHeaderField:name];

	__block NSData *result = nil;
	__block NSHTTPURLResponse *httpResponse = nil;
	__block NSError *failure = nil;
	dispatch_semaphore_t done = dispatch_semaphore_create(0);
	[[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		result = [data retain];
		httpResponse = [(NSHTTPURLResponse *)response retain];
		failure = [error retain];
		dispatch_semaphore_signal(done);
	}] resume];
	dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
	dispatch_release(done);
	[result autorelease];
	[httpResponse autorelease];
	[failure autorelease];

	if ( failure ) {
		*errorOut = [NSString stringWithFormat:@"cannot reach %@ (%@)", [serverURL host], [failure localizedDescription]];
		return nil;
	}
	if ( responseOut )
		*responseOut = httpResponse;
	if ( [httpResponse statusCode] == 401 )
		*errorOut = @"the server refused the token";
	return result;
}

static long long LogSize(NSHTTPURLResponse *response)
{
	return [[[response allHeaderFields] objectForKey:@"X-Log-Size"] longLongValue];
}

static NSData *ReadRange(NSString *path, unsigned long long offset, unsigned long long length)
{
	NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
	if ( !file )
		return nil;
	[file seekToFileOffset:offset];
	NSData *data = [file readDataOfLength:(NSUInteger)length];
	[file closeFile];
	return data;
}

static unsigned long long FileSize(NSString *path)
{
	return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
}

// Written beside the file and renamed over it, so FlycutFolderSync never reads a half-written copy.
static BOOL ReplaceFile(NSString *path, NSData *data)
{
	NSString *temporary = [path stringByAppendingPathExtension:@"downloading"];
	if ( ![data writeToFile:temporary atomically:NO] )
		return NO;
	chmod([temporary fileSystemRepresentation], 0600);
	return rename([temporary fileSystemRepresentation], [path fileSystemRepresentation]) == 0;
}

static BOOL AppendToFile(NSString *path, NSData *data)
{
	NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
	if ( !file )
		return NO;
	[file seekToEndOfFile];
	[file writeData:data];
	[file closeFile];
	return YES;
}

#pragma mark Rounds

// Plain HTTP is only trusted where the network itself encrypts: loopback, and Tailscale, whose
// WireGuard tunnel covers 100.64.0.0/10 and fd7a:115c:a1e0::/48. Every address the name resolves to must be one.
static BOOL HostIsLoopbackOrTailnet(NSString *host)
{
	struct addrinfo hints = { 0 }, *results = NULL;
	hints.ai_socktype = SOCK_STREAM;
	if ( [host length] == 0 || getaddrinfo([host UTF8String], NULL, &hints, &results) != 0 || !results )
		return NO;
	BOOL allPrivate = YES;
	for ( struct addrinfo *a = results; a; a = a->ai_next ) {
		if ( a->ai_family == AF_INET ) {
			uint32_t ip = ntohl(((struct sockaddr_in *)a->ai_addr)->sin_addr.s_addr);
			allPrivate &= (ip >> 24) == 127 || (ip & 0xFFC00000) == 0x64400000;
		} else if ( a->ai_family == AF_INET6 ) {
			const uint8_t *ip = ((struct sockaddr_in6 *)a->ai_addr)->sin6_addr.s6_addr;
			static const uint8_t tailnet[6] = { 0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0 };
			allPrivate &= IN6_IS_ADDR_LOOPBACK(&((struct sockaddr_in6 *)a->ai_addr)->sin6_addr) || memcmp(ip, tailnet, 6) == 0;
		} else {
			allPrivate = NO;
		}
	}
	freeaddrinfo(results);
	return allPrivate;
}

-(BOOL) runRoundWithError:(NSString **)errorOut
{
	{
		if ( [[[serverURL scheme] lowercaseString] isEqualToString:@"http"] && !HostIsLoopbackOrTailnet([serverURL host]) ) {
			*errorOut = [NSString stringWithFormat:@"%@ isn't on your tailnet, so its address must start with https://", [serverURL host]];
			return NO;
		}
		NSHTTPURLResponse *response = nil;
		NSData *listing = [self request:@"GET" path:@"/v1/logs" query:nil body:nil headers:nil response:&response error:errorOut];
		if ( *errorOut )
			return NO;
		NSArray *logs = listing ? [NSJSONSerialization JSONObjectWithData:listing options:0 error:nil] : nil;
		if ( [response statusCode] != 200 || ![logs isKindOfClass:[NSArray class]] ) {
			*errorOut = [NSString stringWithFormat:@"unexpected answer from %@ (HTTP %ld)", [serverURL host], (long)[response statusCode]];
			return NO;
		}

		BOOL downloaded = NO;
		long long ownServerSize = -1;
		for ( NSDictionary *entry in logs ) {
			NSString *machine = [entry isKindOfClass:[NSDictionary class]] ? [entry objectForKey:@"machine"] : nil;
			if ( ![machine isKindOfClass:[NSString class]] || [machine length] == 0 || [machine containsString:@"/"] || [machine hasPrefix:@"."] )
				continue;
			long long size = [[entry objectForKey:@"size"] longLongValue];
			if ( [machine isEqualToString:machineId] ) {
				ownServerSize = size;
				continue;
			}
			downloaded |= [self downloadLogOf:machine serverSize:size error:errorOut];
			if ( *errorOut )
				return downloaded;
		}
		[self uploadOwnLogKnowingServerSize:ownServerSize error:errorOut];
		return downloaded;
	}
}

// Fetches from a little before the end of the local copy; if those bytes no longer match, the
// server's log was rewritten (compacted), so the whole log replaces the copy.
-(BOOL) downloadLogOf:(NSString *)machine serverSize:(long long)serverSize error:(NSString **)errorOut
{
	NSString *path = [localFolder stringByAppendingPathComponent:[machine stringByAppendingPathExtension:@"jsonl"]];
	unsigned long long localSize = FileSize(path);
	if ( (long long)localSize == serverSize && localSize > 0 )
		return NO;

	unsigned long long overlap = MIN((unsigned long long)kTailLength, localSize);
	unsigned long long from = (long long)localSize <= serverSize ? localSize - overlap : 0;
	NSHTTPURLResponse *response = nil;
	NSData *data = [self request:@"GET" path:[@"/v1/logs/" stringByAppendingString:machine]
						   query:[NSString stringWithFormat:@"from=%llu", from] body:nil headers:nil response:&response error:errorOut];
	if ( *errorOut || [response statusCode] == 404 )
		return NO;
	if ( [response statusCode] != 200 || !data ) {
		*errorOut = [NSString stringWithFormat:@"cannot download %@'s history (HTTP %ld)", machine, (long)[response statusCode]];
		return NO;
	}
	if ( LogSize(response) != (long long)from + (long long)[data length] )
		return NO;	// changed while being read; the next round gets a consistent copy

	if ( from > 0 && [data length] >= overlap && [[data subdataWithRange:NSMakeRange(0, (NSUInteger)overlap)] isEqualToData:ReadRange(path, from, overlap)] ) {
		NSData *appended = [data subdataWithRange:NSMakeRange((NSUInteger)overlap, [data length] - (NSUInteger)overlap)];
		if ( [appended length] == 0 )
			return NO;
		if ( !AppendToFile(path, appended) )
			*errorOut = [NSString stringWithFormat:@"cannot write %@", path];
		return YES;
	}
	if ( from > 0 ) {
		data = [self request:@"GET" path:[@"/v1/logs/" stringByAppendingString:machine] query:@"from=0" body:nil headers:nil response:&response error:errorOut];
		if ( *errorOut || [response statusCode] != 200 || !data || LogSize(response) != (long long)[data length] )
			return NO;
	}
	if ( !ReplaceFile(path, data) )
		*errorOut = [NSString stringWithFormat:@"cannot write %@", path];
	return YES;
}

-(NSString *) uploadStatePath
{
	return [localFolder stringByAppendingPathComponent:kUploadStateName];
}

static NSString *HexString(NSData *data)
{
	NSMutableString *hex = [NSMutableString stringWithCapacity:[data length] * 2];
	const unsigned char *bytes = [data bytes];
	for ( NSUInteger i = 0; i < [data length]; i++ )
		[hex appendFormat:@"%02x", bytes[i]];
	return hex;
}

// The local own log is the authority: appended lines are sent as appends, and whenever the local
// file was rewritten (compacted) or the server's copy isn't what was last sent, the whole file replaces it.
-(void) uploadOwnLogKnowingServerSize:(long long)serverSize error:(NSString **)errorOut
{
	NSString *path = [localFolder stringByAppendingPathComponent:[machineId stringByAppendingPathExtension:@"jsonl"]];
	NSData *local = [NSData dataWithContentsOfFile:path];
	if ( !local )
		return;
	NSUInteger complete = [local length];
	const char *bytes = [local bytes];
	while ( complete > 0 && bytes[complete - 1] != '\n' )
		complete--;

	NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[self uploadStatePath]] ?: [NSData data] options:0 error:nil];
	unsigned long long sent = [[state objectForKey:@"sent"] unsignedLongLongValue];
	NSString *sentTail = [state objectForKey:@"tail"];
	long long recordedServerSize = [[state objectForKey:@"serverSize"] longLongValue];

	BOOL localUnchangedSinceSent = sent <= complete && [state isKindOfClass:[NSDictionary class]]
		&& [HexString([local subdataWithRange:NSMakeRange((NSUInteger)(sent - MIN(sent, kTailLength)), (NSUInteger)MIN(sent, kTailLength))]) isEqualToString:sentTail ?: @""];
	BOOL serverAsSent = serverSize == recordedServerSize && serverSize >= 0;
	if ( localUnchangedSinceSent && serverAsSent && sent == complete )
		return;

	NSString *logPath = [@"/v1/logs/" stringByAppendingString:machineId];
	NSHTTPURLResponse *response = nil;
	long long newServerSize = 0;
	if ( localUnchangedSinceSent && serverAsSent ) {
		NSData *appended = [local subdataWithRange:NSMakeRange((NSUInteger)sent, complete - (NSUInteger)sent)];
		[self request:@"POST" path:logPath query:nil body:appended
			  headers:@{@"X-Log-Offset": [NSString stringWithFormat:@"%lld", serverSize]} response:&response error:errorOut];
		if ( *errorOut )
			return;
		newServerSize = LogSize(response);
	}
	if ( !(localUnchangedSinceSent && serverAsSent) || [response statusCode] == 409 ) {
		[self request:@"PUT" path:logPath query:nil body:[local subdataWithRange:NSMakeRange(0, complete)] headers:nil response:&response error:errorOut];
		if ( *errorOut )
			return;
		newServerSize = LogSize(response);
	}
	if ( [response statusCode] != 204 ) {
		*errorOut = [NSString stringWithFormat:@"cannot upload this machine's history (HTTP %ld)", (long)[response statusCode]];
		return;
	}

	NSDictionary *newState = @{@"sent": @(complete), @"serverSize": @(newServerSize),
							   @"tail": HexString([local subdataWithRange:NSMakeRange(complete - MIN(complete, kTailLength), MIN(complete, kTailLength))])};
	[[NSJSONSerialization dataWithJSONObject:newState options:0 error:nil] writeToFile:[self uploadStatePath] atomically:YES];
}

-(void) dealloc
{
	[timer invalidate];
	[timer release];
	[session invalidateAndCancel];
	[session release];
	dispatch_release(queue);
	[serverURL release];
	[token release];
	[localFolder release];
	[machineId release];
	[lastError release];
	[super dealloc];
}

@end
