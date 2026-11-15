//
//  FlycutBlobStore.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutBlobStore keeps pasteboard data (images, rich text, an app's private types) as files named by
// the SHA-256 of their bytes, in one directory readable only by the user. Equal data is stored once,
// a file never changes once written, and a clipping refers to its data by address.

#import <Foundation/Foundation.h>

@interface FlycutBlobStore : NSObject

// Lowercase hex SHA-256 of the data.
+(NSString *) addressOfData:(NSData *)data;
+(BOOL) isAddress:(id)candidate;

-(instancetype) initWithDirectory:(NSString *)directory;

@property (nonatomic, readonly) NSString *directory;

// Stores the data if it isn't there yet and returns its address, or nil if it can't be written.
-(NSString *) storeData:(NSData *)data;
-(NSData *) dataAtAddress:(NSString *)address;
-(BOOL) hasAddress:(NSString *)address;
-(NSString *) pathForAddress:(NSString *)address;

// Puts the blob at path too, as a hard link where the file system allows and a copy where it doesn't.
-(BOOL) exportAddress:(NSString *)address toPath:(NSString *)path;

// Deletes every blob not in keep that is older than minimumAge, so data written for a clipping that
// is still on its way into a list survives. Returns how many were deleted.
-(NSUInteger) removeBlobsExcept:(NSSet *)keep olderThan:(NSTimeInterval)minimumAge;

@end
