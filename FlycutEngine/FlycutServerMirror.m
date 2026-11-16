//
//  FlycutServerMirror.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutServerMirror.h"
#import "FlycutFolderSync.h"
#import "FlycutBlobStore.h"
#import "FlycutClipping.h"
#import "FlycutSyncCrypto.h"
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
	components.percentEncodedQuery = query;
	return [components URL];
}

// Percent-encoded, '+' included: the server reads it as a space otherwise.
static NSString *QueryString(NSDictionary *parameters)
{
	NSMutableCharacterSet *allowed = [[[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy] autorelease];
	[allowed removeCharactersInString:@"&=+#?"];
	NSMutableArray *pairs = [NSMutableArray array];
	for ( NSString *name in [[parameters allKeys] sortedArrayUsingSelector:@selector(compare:)] )
		[pairs addObject:[NSString stringWithFormat:@"%@=%@", name,
						  [[[parameters objectForKey:name] description] stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
	return [pairs componentsJoinedByString:@"&"];
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

#pragma mark Web history

// Runs work on the mirror's queue, where request: may block, and hands its error to the main thread.
-(void) inBackground:(NSString *(^)(void))work then:(void (^)(NSString *error))done
{
	[self retain];
	void (^finish)(NSString *) = [[done copy] autorelease];
	dispatch_async(queue, ^{
		NSString *error = nil;
		@autoreleasepool {
			error = [work() retain];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			finish(error);
			[error release];
			[self release];
		});
	});
}

-(void) requestWebAdmission:(void (^)(NSURL *link, NSString *error))completion
{
	__block NSURL *link = nil;
	[self inBackground:^NSString *{
		NSString *error = nil;
		NSHTTPURLResponse *response = nil;
		NSData *data = [self request:@"POST" path:@"/v1/web/admission" query:nil body:nil headers:nil response:&response error:&error];
		if ( error )
			return error;
		NSDictionary *answer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
		NSString *path = [answer isKindOfClass:[NSDictionary class]] ? [answer objectForKey:@"path"] : nil;
		if ( [response statusCode] != 200 || ![path isKindOfClass:[NSString class]] || ![path hasPrefix:@"/web/"] )
			return [NSString stringWithFormat:@"%@ has no web history yet (HTTP %ld); update flycut-sync-server", [serverURL host], (long)[response statusCode]];
		NSURLComponents *components = [NSURLComponents componentsWithString:path];
		NSString *base = [[self URLForPath:@"" query:nil] absoluteString];
		link = [[NSURL URLWithString:[NSString stringWithFormat:@"%@%@?%@", base, [components path], [components percentEncodedQuery]]] retain];
		return nil;
	} then:^(NSString *error) {
		completion([link autorelease], error);
	}];
}

-(void) fetchWebLogin:(void (^)(NSString *login, BOOL hasPassword, NSString *error))completion
{
	__block NSString *login = nil;
	__block BOOL hasPassword = NO;
	[self inBackground:^NSString *{
		NSString *error = nil;
		NSHTTPURLResponse *response = nil;
		NSData *data = [self request:@"GET" path:@"/v1/web/login" query:nil body:nil headers:nil response:&response error:&error];
		if ( error )
			return error;
		NSDictionary *answer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
		if ( [response statusCode] != 200 || ![answer isKindOfClass:[NSDictionary class]] )
			return [NSString stringWithFormat:@"%@ has no web history yet (HTTP %ld); update flycut-sync-server", [serverURL host], (long)[response statusCode]];
		login = [[answer objectForKey:@"login"] isKindOfClass:[NSString class]] ? [[answer objectForKey:@"login"] copy] : nil;
		hasPassword = [[answer objectForKey:@"password"] boolValue];
		return nil;
	} then:^(NSString *error) {
		completion([login autorelease], hasPassword, error);
	}];
}

-(void) setWebLogin:(NSString *)login password:(NSString *)password completion:(void (^)(NSString *error))completion
{
	NSData *body = password ? [NSJSONSerialization dataWithJSONObject:@{@"login": login ?: @"", @"password": password} options:0 error:nil] : nil;
	[self inBackground:^NSString *{
		NSString *error = nil;
		NSHTTPURLResponse *response = nil;
		[self request:password ? @"PUT" : @"DELETE" path:@"/v1/web/login" query:nil body:body
			  headers:@{@"Content-Type": @"application/json"} response:&response error:&error];
		if ( !error && [response statusCode] != 204 )
			error = [NSString stringWithFormat:@"%@ didn't take it (HTTP %ld)", [serverURL host], (long)[response statusCode]];
		return error;
	} then:completion];
}

#pragma mark Archive

static NSString *StringIn(NSDictionary *dictionary, NSString *key)
{
	id value = [dictionary isKindOfClass:[NSDictionary class]] ? [dictionary objectForKey:key] : nil;
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL IsMachineName(NSString *machine)
{
	return [machine length] > 0 && ![machine containsString:@"/"] && ![machine hasPrefix:@"."];
}

-(FlycutSyncCrypto *) crypto
{
	return [[[FlycutSyncCrypto alloc] initWithToken:token] autorelease];
}

-(FlycutClipping *) clippingFromArchiveEvent:(NSDictionary *)event crypto:(FlycutSyncCrypto *)crypto
{
	NSString *contents = StringIn(event, @"contents");
	if ( !contents && StringIn(event, @"enc") )
		contents = [crypto open:StringIn(event, @"enc")];
	if ( [contents length] == 0 || [StringIn(event, @"id") length] == 0 )
		return nil;
	FlycutClipping *clipping = [[[FlycutClipping alloc] initWithContents:contents withType:StringIn(event, @"type") withDisplayLength:40
													withAppLocalizedName:StringIn(event, @"app") withAppBundleURL:StringIn(event, @"appPath")
														   withTimestamp:[[event objectForKey:@"ts"] integerValue]] autorelease];
	[clipping setClipId:StringIn(event, @"id")];
	[clipping setRank:[[event objectForKey:@"rank"] doubleValue]];
	[clipping setContentsDescribeItems:[[event objectForKey:@"described"] boolValue]];
	return clipping;
}

-(void) searchArchive:(NSString *)words inList:(int)list limit:(NSUInteger)limit
		   completion:(void (^)(NSArray *clippings, NSArray *events, NSUInteger matched, NSString *error))completion
{
	NSString *query = QueryString(@{@"q": words ?: @"", @"list": @(list), @"limit": @(limit)});
	NSMutableArray *clippings = [NSMutableArray array], *events = [NSMutableArray array];
	__block NSUInteger matched = 0;
	[self inBackground:^NSString *{
		NSString *error = nil;
		NSHTTPURLResponse *response = nil;
		NSData *data = [self request:@"GET" path:@"/v1/archive/search" query:query body:nil headers:nil response:&response error:&error];
		if ( error )
			return error;
		NSDictionary *answer = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
		NSArray *found = [answer isKindOfClass:[NSDictionary class]] ? [answer objectForKey:@"clippings"] : nil;
		if ( [response statusCode] != 200 || ![found isKindOfClass:[NSArray class]] )
			return [NSString stringWithFormat:@"%@ can't search its archive (HTTP %ld); update flycut-sync-server", [serverURL host], (long)[response statusCode]];
		FlycutSyncCrypto *crypto = [self crypto];
		for ( NSDictionary *event in found ) {
			FlycutClipping *clipping = [self clippingFromArchiveEvent:event crypto:crypto];
			if ( !clipping )
				continue;	// sealed with another token
			[clippings addObject:clipping];
			[events addObject:event];
		}
		matched = [[answer objectForKey:@"matched"] unsignedIntegerValue];
		return nil;
	} then:^(NSString *error) {
		completion(clippings, events, matched, error);
	}];
}

// The blob, checked against its address; nil without an error when the server doesn't have it.
-(NSData *) blobOf:(NSString *)machine address:(NSString *)address error:(NSString **)errorOut
{
	NSHTTPURLResponse *response = nil;
	NSData *data = [self request:@"GET" path:[self blobPathOf:machine address:address] query:nil body:nil headers:nil response:&response error:errorOut];
	if ( *errorOut || [response statusCode] == 404 )
		return nil;
	if ( [response statusCode] != 200 || !data || ![[FlycutBlobStore addressOfData:data] isEqualToString:address] ) {
		*errorOut = [NSString stringWithFormat:@"cannot download pasteboard data from %@ (HTTP %ld)", [serverURL host], (long)[response statusCode]];
		return nil;
	}
	return data;
}

-(void) importItemsOfArchiveEvent:(NSDictionary *)event intoStore:(FlycutBlobStore *)store
					   completion:(void (^)(NSArray *items, NSString *error))completion
{
	NSMutableArray *items = [NSMutableArray array];
	[self inBackground:^NSString *{
		NSString *machine = StringIn(event, @"m");
		NSArray *eventItems = [event objectForKey:@"items"];
		if ( !IsMachineName(machine) || ![eventItems isKindOfClass:[NSArray class]] )
			return nil;
		FlycutSyncCrypto *crypto = [self crypto];
		for ( NSArray *eventItem in eventItems ) {
			if ( ![eventItem isKindOfClass:[NSArray class]] )
				continue;
			NSMutableArray *item = [NSMutableArray array];
			for ( NSDictionary *representation in eventItem ) {
				NSString *type = StringIn(representation, @"t"), *address = StringIn(representation, @"b");
				if ( !type || ![FlycutBlobStore isAddress:address] )
					continue;
				NSString *error = nil;
				NSData *data = [self blobOf:machine address:address error:&error];
				if ( error )
					return error;
				if ( data && [[representation objectForKey:@"s"] boolValue] )
					data = [crypto openData:data];
				NSString *local = data ? [store storeData:data] : nil;
				if ( local )
					[item addObject:@{@"t": type, @"b": local, @"n": @([data length])}];
			}
			if ( [item count] )
				[items addObject:item];
		}
		return nil;
	} then:^(NSString *error) {
		completion([items count] ? items : nil, error);
	}];
}

// The newest put event with items of each of the clipping ids, in the local copies of every machine's log.
-(NSDictionary *) newestPutEventsOfIds:(NSSet *)ids
{
	NSMutableDictionary *found = [NSMutableDictionary dictionary];
	NSData *itemsKey = [@"\"items\"" dataUsingEncoding:NSUTF8StringEncoding];
	for ( NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:localFolder error:nil] ) {
		if ( [name hasPrefix:@"."] || ![[name pathExtension] isEqualToString:@"jsonl"] )
			continue;
		NSData *log = [NSData dataWithContentsOfFile:[localFolder stringByAppendingPathComponent:name] options:NSDataReadingMappedIfSafe error:nil];
		const char *bytes = [log bytes];
		NSUInteger lineStart = 0, length = [log length];
		for ( NSUInteger i = 0; i < length; i++ ) {
			if ( bytes[i] != '\n' )
				continue;
			NSData *line = [NSData dataWithBytesNoCopy:(void *)(bytes + lineStart) length:i - lineStart freeWhenDone:NO];
			lineStart = i + 1;
			if ( [line rangeOfData:itemsKey options:0 range:NSMakeRange(0, [line length])].location == NSNotFound )
				continue;
			NSDictionary *event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
			NSString *clipId = StringIn(event, @"id");
			if ( !clipId || ![ids containsObject:clipId] || ![StringIn(event, @"op") isEqualToString:@"put"] )
				continue;
			NSDictionary *existing = [found objectForKey:clipId];
			long long at = [[event objectForKey:@"at"] longLongValue], existingAt = [[existing objectForKey:@"at"] longLongValue];
			if ( !existing || at > existingAt || (at == existingAt && [StringIn(event, @"m") compare:StringIn(existing, @"m") ?: @""] == NSOrderedDescending) )
				[found setObject:event forKey:clipId];
		}
	}
	return found;
}

// The representation of an event that holds a local representation's data: the same data, or sealed data of
// the same type (preferably in the same item), which only opening it can confirm.
static NSDictionary *SourceInEvent(NSString *address, NSString *type, NSUInteger itemIndex, NSArray *eventItems)
{
	NSDictionary *sealed = nil;
	for ( NSUInteger i = 0; i < [eventItems count]; i++ ) {
		NSArray *item = [eventItems objectAtIndex:i];
		if ( ![item isKindOfClass:[NSArray class]] )
			continue;
		for ( NSDictionary *representation in item ) {
			NSString *remote = StringIn(representation, @"b");
			if ( ![FlycutBlobStore isAddress:remote] || ![StringIn(representation, @"t") isEqualToString:type] )
				continue;
			if ( ![[representation objectForKey:@"s"] boolValue] ) {
				if ( [remote isEqualToString:address] )
					return @{@"b": remote};
			} else if ( !sealed || i == itemIndex )
				sealed = @{@"b": remote, @"s": @YES};
		}
	}
	return sealed;
}

// Snapshots are {"id", "items"}, taken on the main thread.
-(NSDictionary *) sourcesForSnapshots:(NSArray *)snapshots error:(NSString **)errorOut
{
	NSDictionary *events = [self newestPutEventsOfIds:[NSSet setWithArray:[snapshots valueForKey:@"id"]]];
	NSMutableDictionary *held = [NSMutableDictionary dictionary];
	NSMutableDictionary *sources = [NSMutableDictionary dictionary];
	for ( NSDictionary *snapshot in snapshots ) {
		NSDictionary *event = [events objectForKey:[snapshot objectForKey:@"id"]];
		NSString *machine = StringIn(event, @"m");
		if ( !IsMachineName(machine) )
			continue;
		NSSet *onServer = [held objectForKey:machine];
		if ( !onServer ) {
			NSHTTPURLResponse *response = nil;
			NSData *listing = [self request:@"GET" path:[@"/v1/blobs/" stringByAppendingString:machine] query:nil body:nil headers:nil response:&response error:errorOut];
			if ( *errorOut )
				return nil;
			NSArray *addresses = listing ? [NSJSONSerialization JSONObjectWithData:listing options:0 error:nil] : nil;
			onServer = [addresses isKindOfClass:[NSArray class]] && [response statusCode] == 200 ? [NSSet setWithArray:addresses] : [NSSet set];
			[held setObject:onServer forKey:machine];
		}
		NSMutableDictionary *found = [NSMutableDictionary dictionary];
		[[snapshot objectForKey:@"items"] enumerateObjectsUsingBlock:^(NSArray *item, NSUInteger index, BOOL *stop) {
			for ( NSDictionary *representation in item ) {
				NSString *address = [representation objectForKey:@"b"];
				NSDictionary *source = SourceInEvent(address, [representation objectForKey:@"t"], index, [event objectForKey:@"items"]);
				if ( source && [onServer containsObject:[source objectForKey:@"b"]] ) {
					NSMutableDictionary *located = [[source mutableCopy] autorelease];
					[located setObject:machine forKey:@"m"];
					[found setObject:located forKey:address];
				}
			}
		}];
		if ( [found count] )
			[sources setObject:found forKey:[snapshot objectForKey:@"id"]];
	}
	return sources;
}

static NSArray *Snapshots(NSArray *clippings)
{
	NSMutableArray *snapshots = [NSMutableArray arrayWithCapacity:[clippings count]];
	for ( FlycutClipping *clipping in clippings )
		if ( [clipping clipId] && [[clipping items] count] )
			[snapshots addObject:@{@"id": [clipping clipId], @"items": [clipping items]}];
	return snapshots;
}

-(void) locateDataOfClippings:(NSArray *)clippings completion:(void (^)(NSDictionary *sources, NSString *error))completion
{
	NSArray *snapshots = Snapshots(clippings);
	__block NSDictionary *sources = nil;
	[self inBackground:^NSString *{
		NSString *error = nil;
		sources = [[self sourcesForSnapshots:snapshots error:&error] retain];
		return error;
	} then:^(NSString *error) {
		completion([sources autorelease] ?: @{}, error);
	}];
}

-(void) restoreDataOfClipping:(FlycutClipping *)clipping inStore:(FlycutBlobStore *)store
				   completion:(void (^)(BOOL complete, NSString *error))completion
{
	NSArray *snapshots = Snapshots(@[clipping]);
	__block BOOL complete = NO;
	[self inBackground:^NSString *{
		NSMutableSet *missing = [NSMutableSet set];
		for ( NSArray *item in [[snapshots firstObject] objectForKey:@"items"] )
			for ( NSDictionary *representation in item )
				if ( ![store hasAddress:[representation objectForKey:@"b"]] )
					[missing addObject:[representation objectForKey:@"b"]];
		if ( [missing count] == 0 ) {
			complete = YES;
			return nil;
		}
		NSString *error = nil;
		NSDictionary *sources = [[self sourcesForSnapshots:snapshots error:&error] objectForKey:[[snapshots firstObject] objectForKey:@"id"]];
		if ( error )
			return error;
		FlycutSyncCrypto *crypto = [self crypto];
		for ( NSString *address in [[missing copy] autorelease] ) {
			NSDictionary *source = [sources objectForKey:address];
			NSData *data = source ? [self blobOf:[source objectForKey:@"m"] address:[source objectForKey:@"b"] error:&error] : nil;
			if ( error )
				return error;
			if ( data && [[source objectForKey:@"s"] boolValue] )
				data = [crypto openData:data];
			if ( data && [[FlycutBlobStore addressOfData:data] isEqualToString:address] && [store storeData:data] )
				[missing removeObject:address];
		}
		complete = [missing count] == 0;
		return nil;
	} then:^(NSString *error) {
		completion(complete, error);
	}];
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
		if ( ![self downloadBlobsOf:machine referencedBy:appended error:errorOut] )
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
	if ( ![self downloadBlobsOf:machine referencedBy:data error:errorOut] )
		return NO;
	if ( !ReplaceFile(path, data) )
		*errorOut = [NSString stringWithFormat:@"cannot write %@", path];
	return YES;
}

#pragma mark Blobs

-(FlycutBlobStore *) blobsOfMachine:(NSString *)machine
{
	return [[[FlycutBlobStore alloc] initWithDirectory:[FlycutFolderSync blobDirectoryForMachine:machine inFolder:localFolder]] autorelease];
}

-(NSString *) blobPathOf:(NSString *)machine address:(NSString *)address
{
	return [NSString stringWithFormat:@"/v1/blobs/%@/%@", machine, address];
}

// Fetches the blobs the lines refer to that aren't here yet, before the lines are written, so FolderSync finds
// a line's data when it reads the line. A blob the server doesn't have is skipped: blobs are uploaded before
// their lines, so it is gone for good. Any other failure leaves the lines for the next round.
-(BOOL) downloadBlobsOf:(NSString *)machine referencedBy:(NSData *)lines error:(NSString **)errorOut
{
	FlycutBlobStore *blobs = nil;
	for ( NSString *address in [FlycutFolderSync blobAddressesInLog:lines] ) {
		blobs = blobs ?: [self blobsOfMachine:machine];
		if ( [blobs hasAddress:address] )
			continue;
		NSHTTPURLResponse *response = nil;
		NSData *data = [self request:@"GET" path:[self blobPathOf:machine address:address] query:nil body:nil headers:nil response:&response error:errorOut];
		if ( *errorOut )
			return NO;
		if ( [response statusCode] == 404 )
			continue;
		if ( [response statusCode] != 200 || !data || ![[FlycutBlobStore addressOfData:data] isEqualToString:address] ) {
			*errorOut = [NSString stringWithFormat:@"cannot download %@'s pasteboard data (HTTP %ld)", machine, (long)[response statusCode]];
			return NO;
		}
		if ( ![blobs storeData:data] ) {
			*errorOut = [NSString stringWithFormat:@"cannot write %@", [blobs directory]];
			return NO;
		}
	}
	return YES;
}

// Sends this machine's blobs the lines refer to and the server lacks; known lists what it has, or nil to ask.
-(BOOL) uploadBlobsReferencedBy:(NSData *)lines serverHas:(NSSet *)known error:(NSString **)errorOut
{
	NSSet *addresses = [FlycutFolderSync blobAddressesInLog:lines];
	if ( [addresses count] == 0 )
		return YES;
	FlycutBlobStore *blobs = [self blobsOfMachine:machineId];
	for ( NSString *address in addresses ) {
		if ( [known containsObject:address] )
			continue;
		NSString *path = [self blobPathOf:machineId address:address];
		NSHTTPURLResponse *response = nil;
		if ( !known ) {
			[self request:@"HEAD" path:path query:nil body:nil headers:nil response:&response error:errorOut];
			if ( *errorOut )
				return NO;
			if ( [response statusCode] == 200 )
				continue;
		}
		NSData *data = [blobs dataAtAddress:address];
		if ( !data )
			continue;	// gone locally too; readers skip it
		[self request:@"PUT" path:path query:nil body:data headers:nil response:&response error:errorOut];
		if ( *errorOut )
			return NO;
		// Too large for the server or its proxy: left out rather than retried forever; readers skip it.
		if ( [response statusCode] == 413 ) {
			NSLog(@"Flycut sync: %@ refused %lu bytes of pasteboard data as too large; synced without it", [serverURL host], (unsigned long)[data length]);
			continue;
		}
		if ( [response statusCode] != 204 ) {
			*errorOut = [NSString stringWithFormat:@"cannot upload pasteboard data (HTTP %ld)", (long)[response statusCode]];
			return NO;
		}
	}
	return YES;
}

-(NSSet *) serverBlobsWithError:(NSString **)errorOut
{
	NSHTTPURLResponse *response = nil;
	NSData *listing = [self request:@"GET" path:[@"/v1/blobs/" stringByAppendingString:machineId] query:nil body:nil headers:nil response:&response error:errorOut];
	if ( *errorOut )
		return nil;
	NSArray *addresses = listing ? [NSJSONSerialization JSONObjectWithData:listing options:0 error:nil] : nil;
	if ( [response statusCode] != 200 || ![addresses isKindOfClass:[NSArray class]] ) {
		*errorOut = [NSString stringWithFormat:@"cannot list this machine's pasteboard data on the server (HTTP %ld)", (long)[response statusCode]];
		return nil;
	}
	return [NSSet setWithArray:addresses];
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
	// The file number tells a rewritten file (compacted, or with credentials sealed) from one that only grew.
	NSNumber *fileNumber = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] objectForKey:NSFileSystemFileNumber];
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
		&& [[state objectForKey:@"file"] isEqual:fileNumber]
		&& [HexString([local subdataWithRange:NSMakeRange((NSUInteger)(sent - MIN(sent, kTailLength)), (NSUInteger)MIN(sent, kTailLength))]) isEqualToString:sentTail ?: @""];
	BOOL serverAsSent = serverSize == recordedServerSize && serverSize >= 0;
	if ( localUnchangedSinceSent && serverAsSent && sent == complete )
		return;

	NSString *logPath = [@"/v1/logs/" stringByAppendingString:machineId];
	NSHTTPURLResponse *response = nil;
	long long newServerSize = 0;
	if ( localUnchangedSinceSent && serverAsSent ) {
		NSData *appended = [local subdataWithRange:NSMakeRange((NSUInteger)sent, complete - (NSUInteger)sent)];
		if ( ![self uploadBlobsReferencedBy:appended serverHas:nil error:errorOut] )
			return;
		[self request:@"POST" path:logPath query:nil body:appended
			  headers:@{@"X-Log-Offset": [NSString stringWithFormat:@"%lld", serverSize]} response:&response error:errorOut];
		if ( *errorOut )
			return;
		newServerSize = LogSize(response);
	}
	if ( !(localUnchangedSinceSent && serverAsSent) || [response statusCode] == 409 ) {
		NSData *whole = [local subdataWithRange:NSMakeRange(0, complete)];
		NSSet *serverBlobs = [[FlycutFolderSync blobAddressesInLog:whole] count] ? [self serverBlobsWithError:errorOut] : [NSSet set];
		if ( *errorOut || ![self uploadBlobsReferencedBy:whole serverHas:serverBlobs error:errorOut] )
			return;
		[self request:@"PUT" path:logPath query:nil body:[local subdataWithRange:NSMakeRange(0, complete)] headers:nil response:&response error:errorOut];
		if ( *errorOut )
			return;
		newServerSize = LogSize(response);
	}
	if ( [response statusCode] != 204 ) {
		*errorOut = [NSString stringWithFormat:@"cannot upload this machine's history (HTTP %ld)", (long)[response statusCode]];
		return;
	}

	NSDictionary *newState = @{@"sent": @(complete), @"serverSize": @(newServerSize), @"file": fileNumber ?: @0,
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
