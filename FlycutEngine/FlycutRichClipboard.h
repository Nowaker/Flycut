//
//  FlycutRichClipboard.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// Formatting that survives the clipboard both ways:
//
// - A copy out of Slack (its `slack/texty` delta inside Chromium's web custom data, or Slack's copy HTML)
//   gets HTML for mail and documents, and laid-out plain text (numbered lists, "- " bullets, indented
//   nesting) in place of Slack's flat one. Slack's own flavors stay, so pasting back into Slack is unchanged.
// - A copy whose plain text is Markdown gets HTML and Slack's delta, and its plain text stays the Markdown
//   source byte for byte. Each app pastes the richest flavor it reads: Slack the delta, mail the HTML,
//   terminals and editors the source.
//
// This is a line-for-line port of opencode-tools' _lib/rich-clipboard (markdown.ts, to-markdown.ts,
// detect.ts, enrich.ts, chromium-custom-data.ts); Tests/RichClipboard holds copies of its fixtures, and
// both must produce the same output for every case. Change the two together.

#import <Cocoa/Cocoa.h>

extern NSString *const FlycutWebCustomDataType;		// org.chromium.web-custom-data
extern NSString *const FlycutMarkdownType;			// net.daringfireball.markdown
extern NSString *const FlycutRichSourceMarkerType;	// application/x-rich-clipboard-source

// The conversions, for the enrichment below and for the fixture tests.
NSString *FlycutMarkdownToPlain(NSString *markdown, BOOL readable);
NSString *FlycutMarkdownToHTML(NSString *markdown);
NSDictionary *FlycutMarkdownToSlackDelta(NSString *markdown);
NSString *FlycutSlackDeltaToMarkdown(NSDictionary *delta);
NSString *FlycutHTMLToMarkdown(NSString *html);
BOOL FlycutIsSlackHTML(NSString *html);
BOOL FlycutLooksLikeMarkdown(NSString *text);

// Chromium's web custom data: a base::Pickle of key/value string pairs, each an @[key, value] array.
NSData *FlycutChromiumWebCustomData(NSArray *pairs);
// Empty for bytes that are not a well-formed container.
NSArray *FlycutParseChromiumWebCustomData(NSData *data);

// What to add to a copy so its formatting survives the paste.
@interface FlycutRichEnrichment : NSObject
@property (nonatomic, readonly) NSString *kind;			// "slack" or "markdown"
@property (nonatomic, readonly) NSString *markdown;
@property (nonatomic, readonly) NSString *text;			// the plain text to put on the pasteboard
@property (nonatomic, readonly) NSString *html;
@property (nonatomic, readonly) NSData *webCustomData;
@end

// Nil when the copy needs nothing: not from Slack, not Markdown, or already enriched (it carries the marker).
// Any argument may be nil.
FlycutRichEnrichment *FlycutEnrichFlavors(NSString *text, NSString *html, NSString *markdown, NSData *webCustomData);

// Puts Markdown text on the pasteboard as its source plus HTML and Slack's delta. NO, writing nothing,
// when the text doesn't look like Markdown.
BOOL FlycutWriteRichMarkdown(NSString *text, NSPasteboard *pasteboard);
