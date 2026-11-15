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
//    "type":"...","app":"...","appPath":"...","ts":<seconds>,
//    "items":[[{"t":"<pasteboard type>","b":"<sha256>","n":<bytes>,"s":true}, ...], ...],"described":true}
//   {"v":1,"op":"del","list":0,"id":"<uuid>","at":<ms>,"m":"<machine>"}
//   {"v":1,"op":"clear","list":0,"at":<ms>,"m":"<machine>"}
//
// list is 0 for history and 1 for favorites. For each clipping the event with the greatest
// (at, m) wins, whichever file it is read from and in whatever order, so every machine ends up
// with the same history. Removals by local retention (remember limit, age) are not shared:
// a machine keeping less history doesn't shorten anyone else's.
//
// items (only when the copy had more than plain text) are its pasteboard items, each a list of
// representations whose data is the file blobs/<machine>/<b>, named by the SHA-256 of its bytes and
// written before the line that refers to it. "s" marks data sealed with the crypto; "described" says the
// contents only describe the items. A machine removes its blobs once no line of its file refers to them.

#import <Foundation/Foundation.h>
#import "FlycutStore.h"
#import "FlycutHistoryDB.h"
#import "FlycutSyncCrypto.h"
#import "FlycutCredentialDetector.h"
#import "FlycutBlobStore.h"

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

// With a crypto, credential clippings are written as {"enc": sealed text} instead of "contents", and
// sealed clippings from other machines are opened; without one, sealed clippings can't be read and are skipped.
// The first start with a crypto (and again whenever the credential rules change) rewrites this machine's file so
// credentials it wrote before are sealed too.
@property (nonatomic, retain) FlycutSyncCrypto *crypto;
@property (nonatomic, retain) FlycutCredentialDetector *credentialDetector;	// default: the shared one
// Where clippings' pasteboard data is kept on this machine; without one, only text is shared.
@property (nonatomic, retain) FlycutBlobStore *blobStore;

// The blob addresses lines of a log refer to, for removing blobs nothing refers to any more.
+(NSSet *) blobAddressesInLog:(NSData *)log;
// A machine's blob directory in a sync folder.
+(NSString *) blobDirectoryForMachine:(NSString *)machine inFolder:(NSString *)folder;

// Called on the main thread after changes from other machines were applied to the stores.
@property (nonatomic, copy) void (^didApplyRemoteChanges)(void);

@end
