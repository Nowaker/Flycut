//
//  HistoryPanel.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "HistoryPanel.h"
#import <Carbon/Carbon.h>

static const CGFloat kMargin = 12;
static const CGFloat kRowHeight = 38;
static const NSUInteger kPreviewLimit = 100000;
static NSString * const kCellIdentifier = @"HistoryPanelClipping";

// Selected rows are drawn emphasized even though the search field, not the table, has keyboard focus.
@interface HistoryPanelRowView : NSTableRowView
@end

@implementation HistoryPanelRowView
- (BOOL)isEmphasized
{
	return YES;
}
@end

@implementation HistoryPanel {
	NSSearchField *searchField;
	NSSegmentedControl *listSwitch;
	NSTableView *table;
	NSTextView *preview;
	NSTextField *statusLabel;
	NSArray *allClippings;
	NSArray *shownClippings;
	BOOL showsFavorites;
	NSMutableDictionary *iconCache;
	NSDateFormatter *dateFormatter;
}

- (instancetype)initWithHistoryDelegate:(id<HistoryPanelDelegate>)delegate
{
	self = [super initWithContentRect:NSMakeRect(0, 0, 780, 460)
							styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskResizable | NSWindowStyleMaskNonactivatingPanel
							  backing:NSBackingStoreBuffered
								defer:YES];
	if ( !self )
		return nil;

	self.historyDelegate = delegate;
	self.delegate = self;
	self.titleVisibility = NSWindowTitleHidden;
	self.titlebarAppearsTransparent = YES;
	self.movableByWindowBackground = YES;
	self.level = NSStatusWindowLevel;
	self.hidesOnDeactivate = NO;
	self.releasedWhenClosed = NO;
	self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
	self.minSize = NSMakeSize(480, 260);
	for ( NSNumber *button in @[@(NSWindowCloseButton), @(NSWindowMiniaturizeButton), @(NSWindowZoomButton)] )
		[[self standardWindowButton:[button unsignedIntegerValue]] setHidden:YES];

	iconCache = [[NSMutableDictionary alloc] init];
	dateFormatter = [[NSDateFormatter alloc] init];
	[dateFormatter setDateStyle:NSDateFormatterMediumStyle];
	[dateFormatter setTimeStyle:NSDateFormatterShortStyle];

	[self buildContent];
	[self setFrameAutosaveName:@"HistoryPanel"];
	return self;
}

- (void)buildContent
{
	NSRect bounds = [[self contentView] bounds];
	CGFloat width = bounds.size.width;
	CGFloat height = bounds.size.height;

	NSVisualEffectView *background = [[[NSVisualEffectView alloc] initWithFrame:bounds] autorelease];
	background.material = NSVisualEffectMaterialMenu;
	background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
	background.state = NSVisualEffectStateActive;
	[self setContentView:background];

	CGFloat switchWidth = 170;
	CGFloat topRowY = height - kMargin - 28;

	searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(kMargin, topRowY, width - 3 * kMargin - switchWidth, 28)];
	searchField.placeholderString = @"Search clippings";
	searchField.delegate = self;
	searchField.font = [NSFont systemFontOfSize:15];
	searchField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
	[[searchField cell] setSendsSearchStringImmediately:YES];
	[background addSubview:searchField];

	listSwitch = [[NSSegmentedControl segmentedControlWithLabels:@[@"History", @"Favorites"]
												 trackingMode:NSSegmentSwitchTrackingSelectOne
													   target:self
													   action:@selector(listSwitchChanged:)] retain];
	listSwitch.frame = NSMakeRect(width - kMargin - switchWidth, topRowY + 2, switchWidth, 24);
	listSwitch.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
	listSwitch.refusesFirstResponder = YES;
	[listSwitch setSelectedSegment:0];
	[background addSubview:listSwitch];

	CGFloat statusHeight = 16;
	CGFloat listBottom = kMargin + statusHeight + 8;
	CGFloat listHeight = topRowY - 10 - listBottom;
	CGFloat listWidth = floor((width - 3 * kMargin) * 0.45);

	table = [[NSTableView alloc] initWithFrame:NSZeroRect];
	NSTableColumn *column = [[[NSTableColumn alloc] initWithIdentifier:@"clipping"] autorelease];
	column.resizingMask = NSTableColumnAutoresizingMask;
	[table addTableColumn:column];
	table.headerView = nil;
	table.rowHeight = kRowHeight;
	table.intercellSpacing = NSMakeSize(0, 2);
	table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
	table.backgroundColor = [NSColor clearColor];
	table.refusesFirstResponder = YES;
	table.allowsEmptySelection = YES;
	table.dataSource = self;
	table.delegate = self;
	table.target = self;
	table.doubleAction = @selector(tableDoubleClicked:);

	NSScrollView *tableScroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(kMargin, listBottom, listWidth, listHeight)] autorelease];
	tableScroll.documentView = table;
	tableScroll.hasVerticalScroller = YES;
	tableScroll.drawsBackground = NO;
	tableScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMaxXMargin;
	[background addSubview:tableScroll];
	[column setWidth:tableScroll.contentSize.width];

	NSRect previewFrame = NSMakeRect(2 * kMargin + listWidth, listBottom, width - 3 * kMargin - listWidth, listHeight);
	NSScrollView *previewScroll = [[[NSScrollView alloc] initWithFrame:previewFrame] autorelease];
	previewScroll.hasVerticalScroller = YES;
	previewScroll.borderType = NSNoBorder;
	previewScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable | NSViewMinXMargin;
	preview = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, previewScroll.contentSize.width, previewScroll.contentSize.height)];
	preview.editable = NO;
	preview.selectable = YES;
	preview.richText = NO;
	preview.textContainerInset = NSMakeSize(6, 6);
	preview.autoresizingMask = NSViewWidthSizable;
	preview.backgroundColor = [NSColor textBackgroundColor];
	previewScroll.backgroundColor = [NSColor textBackgroundColor];
	if ( @available(macOS 10.15, *) )
		preview.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
	else
		preview.font = [NSFont userFixedPitchFontOfSize:12];
	previewScroll.documentView = preview;
	[background addSubview:previewScroll];

	statusLabel = [[NSTextField labelWithString:@""] retain];
	statusLabel.frame = NSMakeRect(kMargin, kMargin - 2, width - 2 * kMargin, statusHeight);
	statusLabel.font = [NSFont systemFontOfSize:11];
	statusLabel.textColor = [NSColor secondaryLabelColor];
	statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
	statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	[background addSubview:statusLabel];

	self.initialFirstResponder = searchField;
}

- (BOOL)canBecomeKeyWindow
{
	return YES;
}

#pragma mark Showing and hiding

- (void)showOnActiveScreen
{
	showsFavorites = NO;
	[listSwitch setSelectedSegment:0];
	searchField.stringValue = @"";
	[self reloadClippingsSelectingFirst:YES];

	NSScreen *screen = [NSScreen mainScreen];
	NSPoint mouse = [NSEvent mouseLocation];
	for ( NSScreen *candidate in [NSScreen screens] )
		if ( NSMouseInRect(mouse, [candidate frame], NO) )
			screen = candidate;

	NSRect visible = [screen visibleFrame];
	NSRect frame = [self frame];
	frame.size.width = MIN(frame.size.width, visible.size.width);
	frame.size.height = MIN(frame.size.height, visible.size.height);
	frame.origin.x = NSMidX(visible) - frame.size.width / 2;
	frame.origin.y = visible.origin.y + floor((visible.size.height - frame.size.height) * 0.6);
	[self setFrame:frame display:NO];

	[self makeKeyAndOrderFront:nil];
	[self makeFirstResponder:searchField];
}

- (void)dismiss
{
	[self orderOut:nil];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
	[self dismiss];
}

- (void)listSwitchChanged:(id)sender
{
	[self setShowsFavorites:[listSwitch selectedSegment] == 1];
}

- (void)setShowsFavorites:(BOOL)favorites
{
	showsFavorites = favorites;
	[listSwitch setSelectedSegment:favorites ? 1 : 0];
	[self reloadClippingsSelectingFirst:YES];
	[self makeFirstResponder:searchField];
}

#pragma mark Contents

- (void)reloadClippings
{
	[self reloadClippingsSelectingFirst:NO];
}

- (void)reloadClippingsSelectingFirst:(BOOL)selectFirst
{
	NSArray *clippings = [self.historyDelegate historyPanel:self clippingsInFavorites:showsFavorites];
	[allClippings release];
	allClippings = [clippings retain];
	[self applyFilterSelectingFirst:selectFirst];
}

- (FlycutClipping *)selectedClipping
{
	NSInteger row = [table selectedRow];
	return row >= 0 && row < (NSInteger)[shownClippings count] ? [shownClippings objectAtIndex:row] : nil;
}

// Letters with a stroke or bar have no Unicode decomposition, so diacritic-insensitive search leaves them
// alone; folding them lets "zolc" find "żółć". Strings without any are returned as they are.
static NSString *FoldUndecomposableLetters(NSString *string)
{
	static NSDictionary *replacements;
	static NSCharacterSet *letters;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		replacements = [@{@"ł": @"l", @"Ł": @"L", @"đ": @"d", @"Đ": @"D", @"ø": @"o", @"Ø": @"O",
						  @"ħ": @"h", @"Ħ": @"H", @"ŧ": @"t", @"Ŧ": @"T", @"ı": @"i"} retain];
		letters = [[NSCharacterSet characterSetWithCharactersInString:[[replacements allKeys] componentsJoinedByString:@""]] retain];
	});
	if ( [string rangeOfCharacterFromSet:letters].location == NSNotFound )
		return string;
	NSMutableString *folded = [[string mutableCopy] autorelease];
	for ( NSString *letter in replacements )
		[folded replaceOccurrencesOfString:letter withString:[replacements objectForKey:letter] options:0 range:NSMakeRange(0, [folded length])];
	return folded;
}

// Every whitespace-separated word must appear somewhere in the clipping, in any order.
- (NSArray *)clippingsMatching:(NSString *)search
{
	NSMutableArray *words = [NSMutableArray array];
	for ( NSString *word in [FoldUndecomposableLetters(search) componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] )
		if ( [word length] > 0 )
			[words addObject:word];
	if ( [words count] == 0 )
		return allClippings;

	NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
	NSIndexSet *matching = [allClippings indexesOfObjectsWithOptions:NSEnumerationConcurrent passingTest:^BOOL(FlycutClipping *clipping, NSUInteger idx, BOOL *stop) {
		NSString *contents = FoldUndecomposableLetters([clipping contents]);
		for ( NSString *word in words )
			if ( [contents rangeOfString:word options:options].location == NSNotFound )
				return NO;
		return YES;
	}];
	return [allClippings objectsAtIndexes:matching];
}

- (void)applyFilterSelectingFirst:(BOOL)selectFirst
{
	FlycutClipping *previouslySelected = [[[self selectedClipping] retain] autorelease];
	NSInteger previousRow = [table selectedRow];

	[shownClippings release];
	shownClippings = [[self clippingsMatching:[searchField stringValue]] retain];
	[table reloadData];

	NSInteger row = 0;
	if ( !selectFirst && previouslySelected ) {
		NSUInteger kept = [shownClippings indexOfObjectIdenticalTo:previouslySelected];
		row = NSNotFound != kept ? (NSInteger)kept : MAX(previousRow, 0);
	}
	[self selectRow:row];
	[self updateStatus];
}

- (void)selectRow:(NSInteger)row
{
	NSInteger count = [shownClippings count];
	if ( count == 0 ) {
		[table deselectAll:nil];
		[self updatePreview];
		return;
	}
	row = MAX(0, MIN(row, count - 1));
	[table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	[table scrollRowToVisible:row];
}

- (void)moveSelectionBy:(NSInteger)delta
{
	NSInteger row = [table selectedRow];
	[self selectRow:row < 0 ? 0 : row + delta];
}

- (void)selectNext
{
	[self moveSelectionBy:1];
}

- (void)selectPrevious
{
	[self moveSelectionBy:-1];
}

- (void)updatePreview
{
	NSString *contents = [[self selectedClipping] contents] ?: @"";
	if ( [contents length] > kPreviewLimit )
		contents = [[contents substringToIndex:kPreviewLimit] stringByAppendingString:@"\n…"];
	[preview setString:contents];
	[preview scrollRangeToVisible:NSMakeRange(0, 0)];
}

- (void)updateStatus
{
	NSString *count = [shownClippings count] == [allClippings count]
		? [NSString stringWithFormat:@"%lu clippings", (unsigned long)[allClippings count]]
		: [NSString stringWithFormat:@"%lu of %lu clippings", (unsigned long)[shownClippings count], (unsigned long)[allClippings count]];
	NSString *other = showsFavorites ? @"history" : @"favorites";
	statusLabel.stringValue = [NSString stringWithFormat:@"%@     ⏎ paste    ⌘⏎ copy    ⌘⌫ delete    ⇥ %@    esc close", count, other];
}

#pragma mark Choosing

- (void)chooseSelectedAndPaste:(BOOL)paste
{
	FlycutClipping *clipping = [[[self selectedClipping] retain] autorelease];
	if ( nil == clipping )
		return;
	[self dismiss];
	if ( paste )
		[self.historyDelegate historyPanel:self pasteClipping:clipping inFavorites:showsFavorites];
	else
		[self.historyDelegate historyPanel:self copyClipping:clipping inFavorites:showsFavorites];
}

- (void)deleteSelected
{
	FlycutClipping *clipping = [self selectedClipping];
	if ( nil != clipping )
		[self.historyDelegate historyPanel:self deleteClipping:clipping inFavorites:showsFavorites];
}

- (void)tableDoubleClicked:(id)sender
{
	if ( [table clickedRow] >= 0 )
		[self chooseSelectedAndPaste:YES];
}

#pragma mark Keyboard

// Command-key shortcuts reach the window before the search field's editor sees them.
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
	NSEventModifierFlags modifiers = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;
	if ( [event type] == NSEventTypeKeyDown && modifiers == NSEventModifierFlagCommand ) {
		switch ( [event keyCode] ) {
			case kVK_Return:
			case kVK_ANSI_KeypadEnter:
				[self chooseSelectedAndPaste:NO];
				return YES;
			case kVK_Delete:
				[self deleteSelected];
				return YES;
			case kVK_ANSI_W:
				[self dismiss];
				return YES;
			case kVK_ANSI_F:
				[self makeFirstResponder:searchField];
				[[searchField currentEditor] selectAll:nil];
				return YES;
		}
	}
	return [super performKeyEquivalent:event];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
	if ( command == @selector(moveDown:) )
		[self moveSelectionBy:1];
	else if ( command == @selector(moveUp:) )
		[self moveSelectionBy:-1];
	else if ( command == @selector(scrollPageDown:) || command == @selector(pageDown:) )
		[self moveSelectionBy:10];
	else if ( command == @selector(scrollPageUp:) || command == @selector(pageUp:) )
		[self moveSelectionBy:-10];
	else if ( command == @selector(moveToBeginningOfDocument:) || command == @selector(scrollToBeginningOfDocument:) )
		[self selectRow:0];
	else if ( command == @selector(moveToEndOfDocument:) || command == @selector(scrollToEndOfDocument:) )
		[self selectRow:[shownClippings count] - 1];
	else if ( command == @selector(insertNewline:) )
		[self chooseSelectedAndPaste:YES];
	else if ( command == @selector(insertTab:) || command == @selector(insertBacktab:) )
		[self setShowsFavorites:!showsFavorites];
	else if ( command == @selector(cancelOperation:) ) {
		if ( [[searchField stringValue] length] > 0 ) {
			searchField.stringValue = @"";
			[self applyFilterSelectingFirst:YES];
		} else
			[self dismiss];
	}
	else
		return NO;
	return YES;
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	[self applyFilterSelectingFirst:YES];
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return [shownClippings count];
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row
{
	return [[[HistoryPanelRowView alloc] initWithFrame:NSZeroRect] autorelease];
}

- (NSTableCellView *)newCellView
{
	NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 300, kRowHeight)];
	cell.identifier = kCellIdentifier;

	NSImageView *icon = [[[NSImageView alloc] initWithFrame:NSMakeRect(6, (kRowHeight - 22) / 2, 22, 22)] autorelease];
	icon.imageScaling = NSImageScaleProportionallyUpOrDown;
	cell.imageView = icon;
	[cell addSubview:icon];

	NSTextField *title = [NSTextField labelWithString:@""];
	title.frame = NSMakeRect(36, 18, 300 - 42, 17);
	title.font = [NSFont systemFontOfSize:13];
	title.lineBreakMode = NSLineBreakByTruncatingTail;
	title.autoresizingMask = NSViewWidthSizable;
	cell.textField = title;
	[cell addSubview:title];

	NSTextField *subtitle = [NSTextField labelWithString:@""];
	subtitle.frame = NSMakeRect(36, 3, 300 - 42, 14);
	subtitle.font = [NSFont systemFontOfSize:11];
	subtitle.textColor = [NSColor secondaryLabelColor];
	subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
	subtitle.autoresizingMask = NSViewWidthSizable;
	subtitle.tag = 2;
	[cell addSubview:subtitle];
	return cell;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
	NSTableCellView *cell = [tableView makeViewWithIdentifier:kCellIdentifier owner:self];
	if ( nil == cell )
		cell = [[self newCellView] autorelease];

	FlycutClipping *clipping = [shownClippings objectAtIndex:row];
	cell.textField.stringValue = [self titleForClipping:clipping];
	[(NSTextField *)[cell viewWithTag:2] setStringValue:[self subtitleForClipping:clipping]];
	cell.imageView.image = [self iconForClipping:clipping];
	return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
	[self updatePreview];
}

// The first non-blank line, taken from the start of the clipping so long clippings cost nothing extra.
- (NSString *)titleForClipping:(FlycutClipping *)clipping
{
	NSString *contents = [clipping contents];
	NSString *head = [contents length] > 400 ? [contents substringToIndex:400] : contents;
	head = [head stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSRange lineEnd = [head rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
	if ( NSNotFound != lineEnd.location )
		head = [[head substringToIndex:lineEnd.location] stringByAppendingString:@" …"];
	return head;
}

- (NSString *)subtitleForClipping:(FlycutClipping *)clipping
{
	NSMutableArray *parts = [NSMutableArray array];
	NSString *app = [clipping appLocalizedName];
	if ( [app length] > 0 )
		[parts addObject:app];
	if ( [clipping timestamp] > 0 )
		[parts addObject:[self relativeTime:[clipping timestamp]]];
	NSUInteger length = [[clipping contents] length];
	if ( length > 200 )
		[parts addObject:[NSString stringWithFormat:@"%lu characters", (unsigned long)length]];
	return [parts componentsJoinedByString:@" · "];
}

- (NSString *)relativeTime:(NSInteger)timestamp
{
	NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - timestamp;
	if ( age < 60 )
		return @"just now";
	if ( age < 3600 )
		return [NSString stringWithFormat:@"%d min ago", (int)(age / 60)];
	if ( age < 86400 )
		return [NSString stringWithFormat:@"%d h ago", (int)(age / 3600)];
	if ( age < 7 * 86400 )
		return [NSString stringWithFormat:@"%d d ago", (int)(age / 86400)];
	return [dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:timestamp]];
}

- (NSImage *)iconForClipping:(FlycutClipping *)clipping
{
	NSString *path = [clipping appBundleURL];
	if ( [path length] == 0 )
		return [NSImage imageNamed:NSImageNameMultipleDocuments];
	NSImage *icon = [iconCache objectForKey:path];
	if ( nil == icon ) {
		icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
		[iconCache setObject:icon forKey:path];
	}
	return icon;
}

- (void)dealloc
{
	[searchField release];
	[listSwitch release];
	[table release];
	[preview release];
	[statusLabel release];
	[allClippings release];
	[shownClippings release];
	[iconCache release];
	[dateFormatter release];
	[super dealloc];
}

@end
