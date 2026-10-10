//
//  FlycutHistoryDB.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutHistoryDB persists clipping lists in SQLite, one row per clipping,
// written as each change happens rather than rewriting the whole history.

#import <Foundation/Foundation.h>
#import "FlycutStore.h"

typedef struct {
	int64_t at;			// milliseconds since 1970 of the newest change seen; 0 if none
	NSString *machine;	// the machine that made it
	BOOL deleted;
} FlycutSyncState;

@interface FlycutHistoryDB : NSObject <FlycutStorePersistence>

+(NSString *) defaultPath;

// Returns nil if the database cannot be opened or created.
-(instancetype) initWithPath:(NSString *)path;

-(NSArray *) clippingsInList:(FlycutHistoryList)list withDisplayLength:(int)displayLength;
-(void) replaceList:(FlycutHistoryList)list withClippings:(NSArray *)clippings;
-(void) clearAll;

-(NSString *) metaValueForKey:(NSString *)key;
-(FlycutSyncState) syncStateForClipId:(NSString *)clipId inList:(FlycutHistoryList)list;
-(void) setSyncState:(FlycutSyncState)state forClipId:(NSString *)clipId inList:(FlycutHistoryList)list;
-(int64_t) latestSyncChangeInList:(FlycutHistoryList)list;
-(void) beginTransaction;
-(void) commitTransaction;
-(void) setMetaValue:(NSString *)value forKey:(NSString *)key;

@end
