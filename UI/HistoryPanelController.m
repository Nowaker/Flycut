#import "HistoryPanelController.h"

@interface HistoryPanelController ()
- (void)reloadSearch;
- (void)beginRefresh;
- (void)loadNextPage:(id)sender;
- (void)pasteSelection:(id)sender;
- (void)pasteClickedRow:(id)sender;
- (void)updateSelection;
@end

@implementation HistoryPanelController
@synthesize query, historyDelegate;

- (id)init
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 780, 520)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                               backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:panel];
    [panel release];
    if (!self) return nil;

    entries = [[NSMutableArray alloc] init];
    panel.title = @"Clipboard History";
    panel.minSize = NSMakeSize(640, 420);
    panel.level = NSFloatingWindowLevel;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    panel.delegate = self;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSView *content = panel.contentView;
    NSTextField *label = [NSTextField labelWithString:@"Search clipboard history"];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    searchField.placeholderString = @"Search all saved text";
    searchField.delegate = self;
    searchField.sendsSearchStringImmediately = YES;
    [searchField setAccessibilityLabel:@"Search clipboard history"];

    NSScrollView *listScroll = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
    listScroll.hasVerticalScroller = YES;
    listScroll.borderType = NSBezelBorder;
    tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:@"history"] autorelease];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [tableView addTableColumn:column];
    tableView.headerView = nil;
    tableView.rowHeight = 54;
    tableView.intercellSpacing = NSMakeSize(0, 4);
    tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    tableView.allowsEmptySelection = YES;
    tableView.dataSource = self;
    tableView.delegate = self;
    tableView.target = self;
    tableView.doubleAction = @selector(pasteClickedRow:);
    [tableView setAccessibilityLabel:@"History results"];
    listScroll.documentView = tableView;

    NSScrollView *previewScroll = [[[NSScrollView alloc] initWithFrame:NSZeroRect] autorelease];
    previewScroll.hasVerticalScroller = YES;
    previewScroll.borderType = NSBezelBorder;
    previewView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 340, 340)];
    previewView.editable = NO;
    previewView.selectable = YES;
    previewView.richText = NO;
    previewView.font = [NSFont systemFontOfSize:14];
    NSMutableParagraphStyle *paragraph = [[[NSParagraphStyle defaultParagraphStyle] mutableCopy] autorelease];
    if (@available(macOS 11.0, *)) paragraph.lineBreakStrategy = NSLineBreakStrategyStandard | NSLineBreakStrategyHangulWordPriority;
    previewView.defaultParagraphStyle = paragraph;
    previewView.textContainerInset = NSMakeSize(12, 12);
    previewView.autoresizingMask = NSViewWidthSizable;
    previewView.verticallyResizable = YES;
    previewView.horizontallyResizable = NO;
    previewView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    previewView.textContainer.widthTracksTextView = YES;
    [previewView setAccessibilityLabel:@"Selected clipping preview"];
    previewScroll.documentView = previewView;

    statusField = [[NSTextField wrappingLabelWithString:@"Copy text in another app to save it here."] retain];
    statusField.textColor = [NSColor secondaryLabelColor];
    statusField.maximumNumberOfLines = 3;
    statusField.selectable = YES;
    progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    progressIndicator.style = NSProgressIndicatorStyleSpinning;
    progressIndicator.controlSize = NSControlSizeSmall;
    progressIndicator.displayedWhenStopped = NO;
    progressIndicator.hidden = YES;

    pasteButton = [[NSButton buttonWithTitle:@"Paste" target:self action:@selector(pasteSelection:)] retain];
    pasteButton.bezelStyle = NSBezelStyleRounded;
    pasteButton.keyEquivalent = @"\r";
    pasteButton.enabled = NO;
    moreButton = [[NSButton buttonWithTitle:@"Load More" target:self action:@selector(loadNextPage:)] retain];
    moreButton.bezelStyle = NSBezelStyleRounded;
    moreButton.hidden = YES;
    for (NSButton *button in @[pasteButton, moreButton]) {
        [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [button setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    NSTextField *hint = [NSTextField labelWithString:@"Up/Down to select  ·  Enter to paste  ·  Escape to close"];
    hint.font = [NSFont systemFontOfSize:12];
    hint.textColor = [NSColor secondaryLabelColor];

    for (NSView *view in @[label, searchField, listScroll, previewScroll, statusField, progressIndicator, pasteButton, moreButton, hint]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [label.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [searchField.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [searchField.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [searchField.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8],
        [listScroll.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [listScroll.topAnchor constraintEqualToAnchor:searchField.bottomAnchor constant:12],
        [listScroll.widthAnchor constraintEqualToAnchor:content.widthAnchor multiplier:0.46 constant:-16],
        [listScroll.bottomAnchor constraintEqualToAnchor:statusField.topAnchor constant:-12],
        [previewScroll.leadingAnchor constraintEqualToAnchor:listScroll.trailingAnchor constant:12],
        [previewScroll.trailingAnchor constraintEqualToAnchor:searchField.trailingAnchor],
        [previewScroll.topAnchor constraintEqualToAnchor:listScroll.topAnchor],
        [previewScroll.bottomAnchor constraintEqualToAnchor:listScroll.bottomAnchor],
        [progressIndicator.trailingAnchor constraintEqualToAnchor:searchField.trailingAnchor],
        [progressIndicator.centerYAnchor constraintEqualToAnchor:statusField.centerYAnchor],
        [progressIndicator.widthAnchor constraintEqualToConstant:16],
        [progressIndicator.heightAnchor constraintEqualToConstant:16],
        [statusField.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [statusField.trailingAnchor constraintEqualToAnchor:progressIndicator.leadingAnchor constant:-8],
        [statusField.bottomAnchor constraintEqualToAnchor:hint.topAnchor constant:-12],
        [moreButton.trailingAnchor constraintEqualToAnchor:pasteButton.leadingAnchor constant:-8],
        [moreButton.centerYAnchor constraintEqualToAnchor:pasteButton.centerYAnchor],
        [pasteButton.trailingAnchor constraintEqualToAnchor:searchField.trailingAnchor],
        [pasteButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [hint.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [hint.centerYAnchor constraintEqualToAnchor:pasteButton.centerYAnchor],
        [hint.trailingAnchor constraintLessThanOrEqualToAnchor:moreButton.leadingAnchor constant:-8]
    ]];
    return self;
}

- (void)open
{
    if (!self.window.visible) {
        [statusMessage release];
        statusMessage = nil;
        [self.window center];
        searchField.stringValue = @"";
        [self reloadSearch];
    }
    if (!keyMonitor) {
        keyMonitor = [[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            if (event.window != self.window) return event;
            NSResponder *responder = self.window.firstResponder;
            if ([responder isKindOfClass:[NSTextView class]] && [(NSTextView *)responder hasMarkedText]) return event;
            NSEventModifierFlags modifiers = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
            if (modifiers == NSEventModifierFlagCommand && [[event.charactersIgnoringModifiers lowercaseString] isEqualToString:@"w"]) {
                [self dismiss];
                return nil;
            }
            if (modifiers) return event;
            if (event.keyCode == 53) {
                [self dismiss];
                return nil;
            }
            if (event.keyCode == 36 || event.keyCode == 76) {
                [self pasteSelection:nil];
                return nil;
            }
            if ((event.keyCode == 125 || event.keyCode == 126) && responder != previewView) {
                NSInteger row = tableView.selectedRow + (event.keyCode == 125 ? 1 : -1);
                if (entries.count) {
                    row = MAX(0, MIN(row, (NSInteger)entries.count - 1));
                    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
                    [tableView scrollRowToVisible:row];
                    if (row == (NSInteger)entries.count - 1 && nextCursor && !loading) [self loadNextPage:nil];
                }
                return nil;
            }
            if (responder == tableView || responder == previewView) {
                NSString *characters = event.characters;
                unichar character = characters.length ? [characters characterAtIndex:0] : 0;
                BOOL textKey = character >= 0x20 && character != 0x7f && !(character >= 0xf700 && character <= 0xf8ff);
                if (textKey || event.keyCode == 51 || event.keyCode == 117) {
                    [self.window makeFirstResponder:searchField];
                    [(NSTextView *)self.window.firstResponder setSelectedRange:NSMakeRange(searchField.stringValue.length, 0)];
                }
            }
            return event;
        }] retain];
    }
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:searchField];
}

- (void)dismiss
{
    [progressIndicator stopAnimation:nil];
    progressIndicator.hidden = YES;
    ++queryGeneration;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadSearch) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginRefresh) object:nil];
    if (keyMonitor) {
        [NSEvent removeMonitor:keyMonitor];
        [keyMonitor release];
        keyMonitor = nil;
    }
    [self.window orderOut:nil];
    [historyDelegate historyPanelDidDismiss:self];
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    [self dismiss];
    return NO;
}

- (void)controlTextDidChange:(NSNotification *)notification
{
    if (!query) return;
    [statusMessage release];
    statusMessage = nil;
    statusField.toolTip = nil;
    [selectionToRestore release];
    selectionToRestore = nil;
    ++queryGeneration;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadSearch) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginRefresh) object:nil];
    loading = YES;
    [entries removeAllObjects];
    [tableView reloadData];
    [self updateSelection];
    pasteButton.enabled = NO;
    moreButton.enabled = NO;
    moreButton.hidden = YES;
    statusField.stringValue = @"Searching history...";
    progressIndicator.hidden = NO;
    [progressIndicator startAnimation:nil];
    [self performSelector:@selector(reloadSearch) withObject:nil afterDelay:0.15];
}

- (void)reloadSearch
{
    ++queryGeneration;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadSearch) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginRefresh) object:nil];
    [entries removeAllObjects];
    [tableView reloadData];
    [self updateSelection];
    refreshing = NO;
    [refreshedEntries release];
    refreshedEntries = nil;
    [refreshCursor release];
    refreshCursor = nil;
    [nextCursor release];
    nextCursor = nil;
    loading = NO;
    if (!query) return;
    [self loadNextPage:nil];
}

- (void)refresh
{
    if (!self.window.visible) return;
    ++queryGeneration;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadSearch) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(beginRefresh) object:nil];
    if (!query) return;
    refreshing = YES;
    loading = YES;
    moreButton.enabled = NO;
    statusField.stringValue = @"Refreshing history...";
    progressIndicator.hidden = NO;
    [progressIndicator startAnimation:nil];
    [self performSelector:@selector(beginRefresh) withObject:nil afterDelay:0.15];
}

- (void)beginRefresh
{
    NSInteger row = tableView.selectedRow;
    [selectionToRestore release];
    selectionToRestore = row >= 0 && row < (NSInteger)entries.count ? [entries[row][@"item_id"] copy] : nil;
    [refreshedEntries release];
    refreshedEntries = [[NSMutableArray alloc] init];
    [refreshCursor release];
    refreshCursor = nil;
    refreshLimit = MAX(100, entries.count);
    refreshing = YES;
    loading = NO;
    [self loadNextPage:nil];
}

- (void)loadNextPage:(id)sender
{
    if (loading || !query) return;
    loading = YES;
    moreButton.enabled = NO;
    statusField.stringValue = refreshing ? @"Refreshing history..." : (entries.count ? @"Loading more history..." : @"Searching history...");
    progressIndicator.hidden = NO;
    [progressIndicator startAnimation:nil];
    NSUInteger generation = queryGeneration;
    NSUInteger limit = refreshing ? MIN(100, refreshLimit - refreshedEntries.count) : 100;
    query(searchField.stringValue, refreshing ? refreshCursor : nextCursor, limit, ^(NSArray<NSDictionary *> *page, NSDictionary *cursor, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != queryGeneration) return;
            loading = NO;
            [progressIndicator stopAnimation:nil];
            progressIndicator.hidden = YES;
            if (error) {
                statusField.stringValue = [NSString stringWithFormat:@"History unavailable: %@", error.localizedDescription];
                moreButton.title = @"Retry";
                moreButton.hidden = NO;
                moreButton.enabled = YES;
                return;
            }
            NSInteger selectedRow = tableView.selectedRow;
            NSPoint scrollPosition = tableView.enclosingScrollView.contentView.bounds.origin;
            BOOL replaced = refreshing;
            if (refreshing) {
                [refreshedEntries addObjectsFromArray:page];
                [refreshCursor release];
                refreshCursor = [cursor copy];
                if (cursor && refreshedEntries.count < refreshLimit) {
                    [self loadNextPage:nil];
                    return;
                }
                [entries setArray:refreshedEntries];
                [refreshedEntries release];
                refreshedEntries = nil;
                [refreshCursor release];
                refreshCursor = nil;
                refreshing = NO;
            } else {
                [entries addObjectsFromArray:page];
            }
            [nextCursor release];
            nextCursor = [cursor copy];
            [tableView reloadData];
            if (entries.count) {
                if (selectionToRestore) {
                    NSUInteger index = [entries indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger idx, BOOL *stop) {
                        return [entry[@"item_id"] isEqualToString:selectionToRestore];
                    }];
                    selectedRow = index != NSNotFound ? (NSInteger)index : -1;
                }
                NSIndexSet *selection = selectedRow < 0 && selectionToRestore ? [NSIndexSet indexSet] : [NSIndexSet indexSetWithIndex:MAX(0, MIN(selectedRow, (NSInteger)entries.count - 1))];
                [tableView selectRowIndexes:selection byExtendingSelection:NO];
            }
            [selectionToRestore release];
            selectionToRestore = nil;
            if (replaced) {
                [tableView.enclosingScrollView.contentView scrollToPoint:scrollPosition];
                [tableView.enclosingScrollView reflectScrolledClipView:tableView.enclosingScrollView.contentView];
            }
            [self updateSelection];
            moreButton.title = @"Load More";
            moreButton.hidden = !nextCursor;
            moreButton.enabled = nextCursor != nil;
            statusField.stringValue = entries.count ? [NSString stringWithFormat:@"%lu %@%@", (unsigned long)entries.count, entries.count == 1 ? @"result" : @"results", nextCursor ? @" - more available" : @""] :
                (searchField.stringValue.length ? @"No matches. Try different search text." : @"No saved text. Copy text in another app to begin.");
            if (statusMessage) statusField.stringValue = statusMessage;
        });
    });
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
    return entries.count;
}

- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSTableCellView *cell = [table makeViewWithIdentifier:@"history" owner:self];
    if (!cell) {
        cell = [[[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 320, 54)] autorelease];
        cell.identifier = @"history";
        NSTextField *text = [NSTextField labelWithString:@""];
        text.frame = NSMakeRect(10, 26, 300, 20);
        text.autoresizingMask = NSViewWidthSizable;
        text.font = [NSFont systemFontOfSize:14];
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.textField = text;
        [cell addSubview:text];
        NSTextField *detail = [NSTextField labelWithString:@""];
        detail.frame = NSMakeRect(10, 6, 300, 18);
        detail.autoresizingMask = NSViewWidthSizable;
        detail.font = [NSFont systemFontOfSize:12];
        detail.textColor = [NSColor secondaryLabelColor];
        detail.lineBreakMode = NSLineBreakByTruncatingTail;
        detail.tag = 1;
        [cell addSubview:detail];
    }
    NSDictionary *entry = [entries objectAtIndex:row];
    NSString *text = entry[@"text"];
    NSString *summary = text.length > 300 ? [text substringWithRange:[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 300)]] : text;
    cell.textField.stringValue = [[summary componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    NSDate *date = entry[@"date"];
    NSString *dateString = date ? [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"";
    NSTextField *detail = (NSTextField *)[cell viewWithTag:1];
    detail.stringValue = [NSString stringWithFormat:@"%@%@%@", entry[@"source"] ?: @"", dateString.length ? @" · " : @"", dateString];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if (refreshing) {
        NSInteger row = tableView.selectedRow;
        [selectionToRestore release];
        selectionToRestore = row >= 0 && row < (NSInteger)entries.count ? [entries[row][@"item_id"] copy] : nil;
    }
    [self updateSelection];
}

- (void)updateSelection
{
    NSInteger row = tableView.selectedRow;
    BOOL selected = row >= 0 && row < (NSInteger)entries.count;
    previewView.string = selected ? entries[row][@"text"] : @"";
    [previewView.textStorage addAttribute:NSParagraphStyleAttributeName value:previewView.defaultParagraphStyle range:NSMakeRange(0, previewView.string.length)];
    [previewView scrollRangeToVisible:NSMakeRange(0, 0)];
    pasteButton.enabled = selected;
}

- (void)pasteSelection:(id)sender
{
    if (!pasteButton.enabled) return;
    NSInteger row = tableView.selectedRow;
    if (row >= 0 && row < (NSInteger)entries.count) {
        [historyDelegate historyPanel:self pasteEntry:entries[row]];
    }
}

- (void)pasteClickedRow:(id)sender
{
    if (tableView.clickedRow < 0) return;
    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:tableView.clickedRow] byExtendingSelection:NO];
    [self pasteSelection:sender];
}

- (void)showError:(NSString *)message
{
    [statusMessage release];
    statusMessage = [message copy];
    [progressIndicator stopAnimation:nil];
    progressIndicator.hidden = YES;
    statusField.stringValue = message;
    statusField.toolTip = message;
    if (!query) {
        moreButton.hidden = YES;
        moreButton.enabled = NO;
    }
}

- (void)showLoading:(NSString *)message
{
    [statusMessage release];
    statusMessage = nil;
    statusField.stringValue = message;
    pasteButton.enabled = NO;
    moreButton.hidden = YES;
    progressIndicator.hidden = NO;
    [progressIndicator startAnimation:nil];
}

- (void)dealloc
{
    self.window.delegate = nil;
    tableView.delegate = nil;
    tableView.dataSource = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (keyMonitor) [NSEvent removeMonitor:keyMonitor];
    [keyMonitor release];
    [query release];
    [nextCursor release];
    [selectionToRestore release];
    [statusMessage release];
    [refreshedEntries release];
    [refreshCursor release];
    [entries release];
    [searchField release];
    [tableView release];
    [previewView release];
    [statusField release];
    [progressIndicator release];
    [pasteButton release];
    [moreButton release];
    [super dealloc];
}
@end
