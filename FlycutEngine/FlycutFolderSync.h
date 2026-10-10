//
//  FlycutFolderSync.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutFolderSync shares clipping history between machines through a folder that something else
// keeps in sync (iCloud Drive, Dropbox, Syncthing). Each machine only ever appends to its own file,
// <machine id>.jsonl, so the folder tool never has two writers for one file and never has a conflict.
// Every line is one JSON event:
//
//   {"v":1,"op":"put","list":0,"id":"<uuid>","at":<ms>,"m":"<machine>","rank":<n>,"contents":"...",
//    "type":"...","app":"...","appPath":"...","ts":<seconds>}
//   {"v":1,"op":"del","list":0,"id":"<uuid>","at":<ms>,"m":"<machine>"}
//   {"v":1,"op":"clear","list":0,"at":<ms>,"m":"<machine>"}
//
// list is 0 for history and 1 for favorites. For each clipping the event with the greatest
// (at, m) wins, whichever file it is read from and in whatever order, so every machine ends up
// with the same history. Removals by local retention (remember limit, age) are not shared:
// a machine keeping less history doesn't shorten anyone else's.

#import <Foundation/Foundation.h>
#import "FlycutStore.h"
#import "FlycutHistoryDB.h"

@interface FlycutFolderSync : NSObject <FlycutStorePersistence>

// Stores' changes go to the database as well as to the folder; set the sync as both stores' persistence.
-(instancetype) initWithFolder:(NSString *)folder
					 historyDB:(FlycutHistoryDB *)historyDB
				 clippingStore:(FlycutStore *)clippingStore
				favoritesStore:(FlycutStore *)favoritesStore;

// Reads what other machines wrote, shares this machine's history if the folder doesn't have it yet,
// and keeps checking the folder. Returns NO, with lastError set, if the folder can't be used.
-(BOOL) start;
-(void) stop;

// Reads new events from other machines now instead of at the next check.
-(void) poll;

@property (nonatomic, readonly) NSString *folder;
@property (nonatomic, readonly) NSString *machineId;
@property (nonatomic, readonly) NSString *lastError;
@property (nonatomic, readonly) NSUInteger otherMachineCount;
@property (nonatomic, assign) NSTimeInterval pollInterval;	// default 2 seconds
@property (nonatomic, assign) NSUInteger compactionThreshold;	// own-file lines before compacting; default 1000

// Called on the main thread after changes from other machines were applied to the stores.
@property (nonatomic, copy) void (^didApplyRemoteChanges)(void);

@end
