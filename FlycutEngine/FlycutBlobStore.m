//
//  FlycutBlobStore.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutBlobStore.h"
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

-(void) dealloc
{
	[directory release];
	[super dealloc];
}

@end
