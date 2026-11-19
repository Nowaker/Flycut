//
//  FlycutOperator.h
//  Flycut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutOperator owns and interacts with the FlycutStores, providing
// manipulation of the stores.

#ifndef FlycutOperator_h
#define FlycutOperator_h

#import "FlycutStore.h"

@class FlycutHistoryDB;
@class FlycutFolderSync;
@class FlycutServerMirror;
@class FlycutBlobStore;

@protocol FlycutOperatorDelegate <NSObject>
@optional
- (NSString*)alertWithMessageText:(NSString*)message informationText:(NSString*)information buttonsTexts:(NSArray*)buttons;
@end

@interface FlycutOperator : NSObject <FlycutStoreDeleteDelegate> {
    int							stackPosition;
    int							favoritesStackPosition;
    int							stashedStackPosition;

    FlycutStore				*clippingStore;
    FlycutStore				*favoritesStore;
    FlycutStore				*stashedStore;

	FlycutHistoryDB			*historyDB;
	FlycutFolderSync		*folderSync;
	NSString				*folderSyncError;
	FlycutServerMirror		*serverMirror;
	FlycutBlobStore			*blobStore;
	NSTimer					*expiryTimer;

	SEL saveSelector;
	NSObject* saveTarget;
	int displayNum;
	int displayLength;

	NSArray *settingsSyncList;

    BOOL disableStore;
	BOOL inhibitSaveEngineAfterListModification;
	BOOL firstClippingsSyncAfterEnabling;
	BOOL inhibitAutosaveClippings;

	//Preferences
	BOOL issuedRememberResizeWarning;
}

// Basic functionality
-(int)indexOfClipping:(NSString*)contents ofType:(NSString*)type fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL;
-(bool)addClipping:(NSString*)contents ofType:(NSString*)type fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL target:(id)selectorTarget clippingAddedSelector:(SEL)clippingAddedSelectorclippingAddedSelector;
// Items as in FlycutClipping -items. A copy is new unless the top clipping has the same contents and items.
-(bool)addClipping:(NSString*)contents ofType:(NSString*)type items:(NSArray *)items contentsDescribeItems:(BOOL)described fromApp:(NSString *)appName withAppBundleURL:(NSString *)bundleURL target:(id)selectorTarget clippingAddedSelector:(SEL)clippingAddedSelector;
-(int)stackPosition;
-(NSString*)getPasteFromStackPosition;
-(NSString*)getPasteFromIndex:(int) position;
-(FlycutClipping*)clippingForPasteFromStackPosition;
-(FlycutClipping*)clippingForPasteFromIndex:(int) position;
#ifdef FLYCUT_MAC
-(FlycutBlobStore *)blobStore;
-(void)removeUnusedBlobs;
// The server sync, while history syncs through a server; nil otherwise.
-(FlycutServerMirror *)serverMirror;
// Keeps the pasteboard data clippings use under historyBinaryLimitMB (see FlycutBlobStore for which goes).
// Syncing through a server, clippings keep their items and fetch the data back on demand; otherwise it's gone.
-(void)enforceBinaryLimit;
// Some of the clipping's data was dropped here and can be fetched from the server.
-(BOOL)clippingHasDataOnServer:(FlycutClipping *)clipping;
-(BOOL)isRestoringDataOfClipping:(FlycutClipping *)clipping;
// Fetches it back; the completion runs on the main thread whether or not it all came back.
-(void)restoreDataOfClipping:(FlycutClipping *)clipping completion:(void (^)(void))completion;
// A clipping from the server's archive (FlycutServerMirror -searchArchive:...) becomes a new copy at the top of
// history, with its data fetched; the completion gets that top clipping.
-(void)addArchivedClipping:(FlycutClipping *)clipping fromEvent:(NSDictionary *)event completion:(void (^)(FlycutClipping *added))completion;
#endif
-(bool) saveFromStack;
-(bool)clearItemAtStackPosition;
-(void)clearList;
-(void)mergeList;

// Stack position manipulation functionality
-(bool)setStackPositionToOneMoreRecent;
-(bool)setStackPositionToOneLessRecent;
-(bool)setStackPositionToFirstItem;
-(bool)setStackPositionToLastItem;
-(bool)setStackPositionToTenMoreRecent;
-(bool)setStackPositionToTenLessRecent;
-(bool)setStackPositionTo:(int) newStackPosition;
-(void)adjustStackPositionIfOutOfBounds;
-(bool)stackPositionIsInBounds;

// Stack related
-(BOOL) isValidClippingNumber:(NSNumber *)number;
-(NSString *) clippingStringWithCount:(int)count;

// Save and load
-(void) saveEngine;
-(bool) loadEngineFromPList;
-(void) registerOrDeregisterICloudSync;
-(void) checkCloudKitUpdates;

// Preference related
-(void) willShowPreferences;
-(int) setRememberNum:(int)newRemember forPrimaryStore:(BOOL) isPrimaryStore;
-(void) savePreferenceDidChange;
-(void) pruneExpiredClippings;

// Initialization / cleanup related
-(void)applicationWillTerminate;;

// Starts, restarts or stops sharing history as the sync preferences say: through the folder in
// syncFolderEnabled/syncFolderPath, or through the server in syncServerEnabled/syncServerURL with its token (keychain, or syncServerTokenFile).
-(void)syncPreferenceDidChange;
// Same, but starts over even if the folder or server didn't change, as after a new token.
-(void)restartSync;
-(NSString *)syncStatus;
-(void)awakeFromNibDisplaying:(int) displayNum withDisplayLength:(int) displayLength withSaveSelector:(SEL) selector forTarget:(NSObject*) target;

// Favorites Store related
-(bool)favoritesStoreIsSelected;
-(void)switchToFavoritesStore;
-(bool)restoreStashedStore;
-(void)toggleToFromFavoritesStore;
-(bool)saveFromStackToFavorites;

// Clippings Store related
-(int)jcListCount;
-(int)rememberNum;
-(FlycutClipping*)clippingAtStackPosition;
-(NSArray *) previousDisplayStrings:(int)howMany containing:(NSString*)search;
-(NSArray *) previousIndexes:(int)howMany containing:(NSString*)search; // This method is in newest-first order.
-(NSArray *) clippingsInFavorites:(BOOL)favorites;
-(NSString *) pasteContentsOfClipping:(FlycutClipping *)clipping inFavorites:(BOOL)favorites;
-(void) deleteClipping:(FlycutClipping *)clipping inFavorites:(BOOL)favorites;
-(void)setDisableStoreTo:(bool) value;
-(bool)storeDisabled;
-(void)setClippingsStoreDelegate:(id<FlycutStoreDelegate>) delegate;
-(void)setFavoritesStoreDelegate:(id<FlycutStoreDelegate>) delegate;

/** optional delegate (not retained) */
@property (nonatomic, nullable, assign) id<FlycutOperatorDelegate> delegate;

@end

#endif /* FlycutOperator_h */
