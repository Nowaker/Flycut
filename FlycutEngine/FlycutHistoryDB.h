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

@interface FlycutHistoryDB : NSObject <FlycutStorePersistence>

+(NSString *) defaultPath;

// Returns nil if the database cannot be opened or created.
-(instancetype) initWithPath:(NSString *)path;

-(NSArray *) clippingsInList:(FlycutHistoryList)list withDisplayLength:(int)displayLength;
-(void) replaceList:(FlycutHistoryList)list withClippings:(NSArray *)clippings;
-(void) clearAll;

-(NSString *) metaValueForKey:(NSString *)key;
-(void) setMetaValue:(NSString *)value forKey:(NSString *)key;

@end
