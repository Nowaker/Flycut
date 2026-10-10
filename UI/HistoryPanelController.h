#import <Cocoa/Cocoa.h>

typedef void (^HistoryPanelQueryCompletion)(NSArray<NSDictionary *> *entries, NSDictionary *nextCursor, NSError *error);
typedef void (^HistoryPanelQuery)(NSString *search, NSDictionary *cursor, NSUInteger limit, HistoryPanelQueryCompletion completion);

@class HistoryPanelController;

@protocol HistoryPanelDelegate <NSObject>
- (void)historyPanel:(HistoryPanelController *)controller pasteEntry:(NSDictionary *)entry;
- (void)historyPanelDidDismiss:(HistoryPanelController *)controller;
@end

// Entries contain item_id, text, source, and date (NSDate). Queries may complete on any queue.
@interface HistoryPanelController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate>
{
    NSSearchField *searchField;
    NSTableView *tableView;
    NSTextView *previewView;
    NSTextField *statusField;
    NSProgressIndicator *progressIndicator;
    NSButton *pasteButton;
    NSButton *moreButton;
    NSMutableArray<NSDictionary *> *entries;
    HistoryPanelQuery query;
    id<HistoryPanelDelegate> historyDelegate;
    id keyMonitor;
    NSUInteger queryGeneration;
    BOOL loading;
    NSDictionary *nextCursor;
    NSString *selectionToRestore;
    NSString *statusMessage;
    NSMutableArray<NSDictionary *> *refreshedEntries;
    NSDictionary *refreshCursor;
    NSUInteger refreshLimit;
    BOOL refreshing;
}
@property(nonatomic, copy) HistoryPanelQuery query;
@property(nonatomic, assign) id<HistoryPanelDelegate> historyDelegate;
- (void)open;
- (void)refresh;
- (void)dismiss;
- (void)showLoading:(NSString *)message;
- (void)showError:(NSString *)message;
@end
