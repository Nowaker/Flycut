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

// Every stored blob's size in bytes, by address.
-(NSDictionary *) sizesByAddress;
// Deletes the blobs, and files of the same names in the other directories (copies and hard links of them, as in
// a sync folder), returning how many bytes the store held for them.
-(unsigned long long) removeAddresses:(NSSet *)addresses alsoFromDirectories:(NSArray *)directories;

// Which data to drop locally when what the clippings use is over limit bytes. Protected are favorites, the
// 20 newest clippings of history (newest first) and anything copied in the last 24 hours; data a protected
// clipping uses stays. The others lose their data bulkiest first, by bytes × (1 + age in days / 30), until
// the total is under 90% of the limit. Returns the addresses to drop; *evicted gets the clippings losing
// data, in eviction order.
-(NSSet *) addressesToEvictForHistory:(NSArray *)history favorites:(NSArray *)favorites
								limit:(unsigned long long)limit now:(NSTimeInterval)now evicted:(NSArray **)evicted;

@end
