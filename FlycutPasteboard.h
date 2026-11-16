//
//  FlycutPasteboard.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// Reads everything a copy put on a pasteboard and puts it back on paste.
//
// A pasteboard holds items (one per copied object), each in several representations ("flavors"):
// text, HTML, RTF, an image, an app's private format. macOS also advertises flavors it would only
// produce on request by translating another one (a PNG offers TIFF, JPEG, HEIC and a dozen more);
// those are left out, as are flavors the copying app marked as not to be saved. Flavors the app
// promised are read, which makes it provide them. Pasting writes back exactly what was kept, and
// macOS offers its translations again from there.

#import <Cocoa/Cocoa.h>
#import "FlycutClipping.h"
#import "FlycutBlobStore.h"

@interface FlycutPasteboardCapture : NSObject

// Nil if the pasteboard is empty. Representations are dropped, largest first and never plain text,
// until the rest fit in sizeLimit bytes.
+(instancetype) captureFromPasteboardNamed:(NSString *)name sizeLimit:(unsigned long long)sizeLimit;

// Arrays of {"t": type, "d": NSData}, one per pasteboard item.
@property (nonatomic, readonly) NSArray *items;
// Every type the pasteboard offered, including translations, for the types the user chose to skip.
@property (nonatomic, readonly) NSArray *types;
// The plain text, or text read from RTF or HTML when there is no plain text; nil when there is neither.
@property (nonatomic, readonly) NSString *text;
// Says what the items are, for a copy without text: "[image: PNG, 1920×1080, 1.2 MB]".
@property (nonatomic, readonly) NSString *itemsDescription;
// The type that best names the copy: plain text if it has any, otherwise the first item's main type.
@property (nonatomic, readonly) NSString *primaryType;
// Nothing but plain text in one item; such a clipping needs no stored items.
@property (nonatomic, readonly) BOOL onlyPlainText;

// Stores the data and returns the items in FlycutClipping's form, or nil if any of it can't be stored.
-(NSArray *) clippingItemsStoredIn:(FlycutBlobStore *)store;

// Adds the flavors that keep a Markdown or Slack copy's formatting when pasted (see FlycutRichClipboard.h):
// HTML and Slack's delta, and for a copy out of Slack laid-out plain text, which then becomes `text`. NO,
// changing nothing, for a copy that needs none, has more than one item, holds an image, file or other media,
// is marked concealed, transient or auto-generated, or lost a representation to the size limit (writing it
// back would lose that from the pasteboard too).
-(BOOL) addRichFormats;

// Puts the items back on the pasteboard, e.g. after addRichFormats.
-(BOOL) writeToPasteboard:(NSPasteboard *)pasteboard;

@end

// Describes items holding {"t", "d"} representations, e.g. "[image: GIF, 480×270, 1.1 MB, 20 frames]".
NSString *FlycutDescribePasteboardItems(NSArray *items);

// Puts the clipping's items on the pasteboard. NO, leaving the pasteboard alone, if it has no items
// or none of their data is in the store.
BOOL FlycutWriteClippingItems(FlycutClipping *clipping, FlycutBlobStore *store, NSPasteboard *pasteboard);

// The clipping's first image (or PDF), for previews; nil if it has none.
NSImage *FlycutClippingImage(FlycutClipping *clipping, FlycutBlobStore *store);
