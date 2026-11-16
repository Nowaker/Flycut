//
//  HistoryPanel.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// HistoryPanel lists the whole clipboard history with a search field, in the
// manner of KDE's Klipper popup. It stays open until a clipping is chosen or it
// is dismissed, and it never activates Flycut, so the app the user came from
// keeps focus and receives the paste.

#import <Cocoa/Cocoa.h>
#import "FlycutClipping.h"

@class HistoryPanel;

@protocol HistoryPanelDelegate <NSObject>
- (NSArray *)historyPanel:(HistoryPanel *)panel clippingsInFavorites:(BOOL)favorites;
- (void)historyPanel:(HistoryPanel *)panel pasteClipping:(FlycutClipping *)clipping inFavorites:(BOOL)favorites;
- (void)historyPanel:(HistoryPanel *)panel copyClipping:(FlycutClipping *)clipping inFavorites:(BOOL)favorites;
- (void)historyPanel:(HistoryPanel *)panel deleteClipping:(FlycutClipping *)clipping inFavorites:(BOOL)favorites;
@optional
- (NSImage *)historyPanel:(HistoryPanel *)panel imageForClipping:(FlycutClipping *)clipping;
// The clipping's data is being fetched back from the server; the preview says so until refreshPreview.
- (BOOL)historyPanel:(HistoryPanel *)panel isFetchingDataForClipping:(FlycutClipping *)clipping;

// Searching the server's archive, offered while history syncs through a server. Results are clippings to show,
// each with the archive event it came from at the same index.
- (BOOL)historyPanelCanSearchArchive:(HistoryPanel *)panel;
- (void)historyPanel:(HistoryPanel *)panel searchArchiveFor:(NSString *)words inFavorites:(BOOL)favorites
		  completion:(void (^)(NSArray *clippings, NSArray *events, NSUInteger matched, NSString *error))completion;
- (void)historyPanel:(HistoryPanel *)panel chooseArchivedClipping:(FlycutClipping *)clipping event:(NSDictionary *)event paste:(BOOL)paste;
@end

@interface HistoryPanel : NSPanel <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate>

/** not retained */
@property (nonatomic, assign) id<HistoryPanelDelegate> historyDelegate;

/** Copies aren't being recorded; the status line says so. */
@property (nonatomic, assign) BOOL recordingPaused;

- (instancetype)initWithHistoryDelegate:(id<HistoryPanelDelegate>)delegate;

- (void)showOnActiveScreen;
- (void)dismiss;
- (void)reloadClippings;
- (void)refreshPreview;
- (void)selectNext;
- (void)selectPrevious;

@end
