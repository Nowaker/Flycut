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
@end

@interface HistoryPanel : NSPanel <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate>

/** not retained */
@property (nonatomic, assign) id<HistoryPanelDelegate> historyDelegate;

- (instancetype)initWithHistoryDelegate:(id<HistoryPanelDelegate>)delegate;

- (void)showOnActiveScreen;
- (void)dismiss;
- (void)reloadClippings;
- (void)selectNext;
- (void)selectPrevious;

@end
