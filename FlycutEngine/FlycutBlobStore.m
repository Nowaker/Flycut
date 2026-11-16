//
//  FlycutBlobStore.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutBlobStore.h"
#import "FlycutClipping.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>

@implementation FlycutBlobStore

@synthesize directory;

+(NSString *) addressOfData:(NSData *)data
{
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256([data bytes], (CC_LONG)[data length], digest);
	NSMutableString *hex = [NSMutableString stringWithCapacity:2 * sizeof digest];
	for ( size_t i = 0; i < sizeof digest; i++ )
		[hex appendFormat:@"%02x", digest[i]];
	return hex;
}

+(BOOL) isAddress:(id)candidate
{
	if ( ![candidate isKindOfClass:[NSString class]] || [candidate length] != 2 * CC_SHA256_DIGEST_LENGTH )
		return NO;
	NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
	return [candidate rangeOfCharacterFromSet:notHex].location == NSNotFound;
}

-(instancetype) initWithDirectory:(NSString *)aDirectory
{
	self = [super init];
	if ( !self )
		return nil;
	directory = [aDirectory copy];
	[[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
											   attributes:@{NSFilePosixPermissions: @0700} error:nil];
	return self;
}

-(NSString *) pathForAddress:(NSString *)address
{
	return [FlycutBlobStore isAddress:address] ? [directory stringByAppendingPathComponent:address] : nil;
}

-(BOOL) hasAddress:(NSString *)address
{
	NSString *path = [self pathForAddress:address];
	return path && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

// Written beside its final name and renamed into place, so a reader never sees a partial blob.
-(NSString *) storeData:(NSData *)data
{
	if ( !data )
		return nil;
	NSString *address = [FlycutBlobStore addressOfData:data];
	NSString *path = [self pathForAddress:address];
	if ( [[NSFileManager defaultManager] fileExistsAtPath:path] )
		return address;
	NSString *temporary = [path stringByAppendingFormat:@".%@.partial", [[NSUUID UUID] UUIDString]];
	if ( ![data writeToFile:temporary atomically:NO]
		|| chmod([temporary fileSystemRepresentation], 0600) != 0
		|| rename([temporary fileSystemRepresentation], [path fileSystemRepresentation]) != 0 ) {
		[[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
		NSLog(@"Flycut: cannot store pasteboard data in %@", directory);
		return nil;
	}
	return address;
}

-(NSData *) dataAtAddress:(NSString *)address
{
	NSString *path = [self pathForAddress:address];
	return path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : nil;
}

-(BOOL) exportAddress:(NSString *)address toPath:(NSString *)path
{
	NSString *source = [self pathForAddress:address];
	if ( !source )
		return NO;
	if ( [[NSFileManager defaultManager] fileExistsAtPath:path] )
		return YES;
	if ( link([source fileSystemRepresentation], [path fileSystemRepresentation]) == 0 )
		return YES;
	NSString *temporary = [path stringByAppendingFormat:@".%@.partial", [[NSUUID UUID] UUIDString]];
	if ( [[NSFileManager defaultManager] copyItemAtPath:source toPath:temporary error:nil]
		&& rename([temporary fileSystemRepresentation], [path fileSystemRepresentation]) == 0 )
		return YES;
	[[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
	return NO;
}

-(NSUInteger) removeBlobsExcept:(NSSet *)keep olderThan:(NSTimeInterval)minimumAge
{
	NSUInteger removed = 0;
	NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-minimumAge];
	for ( NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil] ) {
		BOOL partial = [name hasSuffix:@".partial"];
		if ( !partial && (![FlycutBlobStore isAddress:name] || [keep containsObject:name]) )
			continue;
		NSString *path = [directory stringByAppendingPathComponent:name];
		NSDate *modified = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileModificationDate];
		if ( modified && [modified compare:cutoff] == NSOrderedDescending )
			continue;
		if ( [[NSFileManager defaultManager] removeItemAtPath:path error:nil] )
			removed++;
	}
	return removed;
}

-(NSDictionary *) sizesByAddress
{
	NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
	NSDirectoryEnumerator *files = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:directory]
										includingPropertiesForKeys:@[NSURLFileSizeKey]
														   options:NSDirectoryEnumerationSkipsSubdirectoryDescendants
													  errorHandler:nil];
	for ( NSURL *file in files ) {
		NSString *name = [file lastPathComponent];
		NSNumber *size = nil;
		if ( [FlycutBlobStore isAddress:name] && [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil] && size )
			[sizes setObject:size forKey:name];
	}
	return sizes;
}

-(unsigned long long) removeAddresses:(NSSet *)addresses alsoFromDirectories:(NSArray *)directories
{
	unsigned long long freed = 0;
	for ( NSString *address in addresses ) {
		NSString *path = [self pathForAddress:address];
		if ( !path )
			continue;
		freed += [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
		unlink([path fileSystemRepresentation]);
		for ( NSString *other in directories )
			unlink([[other stringByAppendingPathComponent:address] fileSystemRepresentation]);
	}
	return freed;
}

static NSTimeInterval const kProtectedAge = 24 * 60 * 60;
static NSUInteger const kProtectedNewest = 20;

-(NSSet *) addressesToEvictForHistory:(NSArray *)history favorites:(NSArray *)favorites
								limit:(unsigned long long)limit now:(NSTimeInterval)now evicted:(NSArray **)evicted
{
	*evicted = @[];
	NSDictionary *sizes = [self sizesByAddress];
	NSMutableSet *used = [NSMutableSet set];
	for ( NSArray *list in @[history, favorites] )
		for ( FlycutClipping *clipping in list )
			[used addObjectsFromArray:[clipping blobAddresses]];
	unsigned long long total = 0;
	for ( NSString *address in used )
		total += [[sizes objectForKey:address] unsignedLongLongValue];
	if ( total <= limit )
		return [NSSet set];

	NSMutableSet *kept = [NSMutableSet set];
	NSMutableArray *candidates = [NSMutableArray array];
	for ( FlycutClipping *clipping in favorites )
		[kept addObjectsFromArray:[clipping blobAddresses]];
	[history enumerateObjectsUsingBlock:^(FlycutClipping *clipping, NSUInteger position, BOOL *stop) {
		if ( position < kProtectedNewest || [clipping timestamp] >= now - kProtectedAge )
			[kept addObjectsFromArray:[clipping blobAddresses]];
		else if ( [[clipping blobAddresses] count] )
			[candidates addObject:clipping];
	}];

	NSMutableArray *scored = [NSMutableArray array];
	for ( FlycutClipping *clipping in candidates ) {
		unsigned long long bytes = 0;
		for ( NSString *address in [NSSet setWithArray:[clipping blobAddresses]] )
			if ( ![kept containsObject:address] )
				bytes += [[sizes objectForKey:address] unsignedLongLongValue];
		if ( bytes == 0 )
			continue;
		double ageDays = MAX(0, now - [clipping timestamp]) / 86400.0;
		[scored addObject:@{@"clipping": clipping, @"score": @(bytes * (1 + ageDays / 30))}];
	}
	[scored sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"score" ascending:NO]]];

	unsigned long long target = limit / 10 * 9;
	NSMutableSet *dropped = [NSMutableSet set];
	NSMutableArray *losing = [NSMutableArray array];
	for ( NSDictionary *entry in scored ) {
		if ( total < target )
			break;
		FlycutClipping *clipping = [entry objectForKey:@"clipping"];
		for ( NSString *address in [clipping blobAddresses] )
			if ( ![kept containsObject:address] && ![dropped containsObject:address] ) {
				[dropped addObject:address];
				total -= MIN(total, [[sizes objectForKey:address] unsignedLongLongValue]);
			}
		[losing addObject:clipping];
	}
	*evicted = losing;
	return dropped;
}

-(void) dealloc
{
	[directory release];
	[super dealloc];
}

@end
