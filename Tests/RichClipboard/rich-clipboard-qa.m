// Offscreen tests for FlycutRichClipboard: the fixtures shared with opencode-tools' _lib/rich-clipboard,
// and enrichment through FlycutPasteboardCapture on private pasteboards (the general one is never touched).
// Usage: rich-clipboard-qa <fixtures directory> [a real Slack composer copy's web custom data, structure only]
#import <Cocoa/Cocoa.h>
#import "FlycutRichClipboard.h"
#import "FlycutPasteboard.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (cond) printf("ok   "); else { printf("FAIL "); failures++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static NSString *fixturesDirectory;

static NSArray *Fixture(NSString *name)
{
	NSData *data = [NSData dataWithContentsOfFile:[fixturesDirectory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]]];
	return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}

static NSString *JSON(id object)
{
	NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:NULL];
	return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

// Where a mismatch starts, so a failure says what differs without dumping both strings.
static NSString *Diff(NSString *got, NSString *want)
{
	if ( [got isEqualToString:want] )
		return @"";
	NSUInteger i = 0;
	while ( i < [got length] && i < [want length] && [got characterAtIndex:i] == [want characterAtIndex:i] )
		i++;
	NSString *(^around)(NSString *) = ^NSString *(NSString *s) {
		NSUInteger start = i > 20 ? i - 20 : 0;
		return [[s substringWithRange:NSMakeRange(start, MIN([s length], i + 30) - start)] stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
	};
	return [NSString stringWithFormat:@" (differs at %lu: got \"%@\" want \"%@\")", (unsigned long)i, around(got), around(want)];
}

static void CheckString(NSString *got, NSString *want, NSString *what)
{
	CHECK([got isEqualToString:want], "%s%s", [what UTF8String], [Diff(got ?: @"(nil)", want ?: @"(nil)") UTF8String]);
}

static void MarkdownFixtures(void)
{
	for ( NSDictionary *c in Fixture(@"markdown") ) {
		NSString *name = [c objectForKey:@"name"], *markdown = [c objectForKey:@"markdown"];
		CheckString(FlycutMarkdownToPlain(markdown, NO), [c objectForKey:@"plain"], [NSString stringWithFormat:@"markdown %@: plain", name]);
		CheckString(FlycutMarkdownToPlain(markdown, YES), [c objectForKey:@"readable"], [NSString stringWithFormat:@"markdown %@: readable", name]);
		CheckString(FlycutMarkdownToHTML(markdown), [c objectForKey:@"html"], [NSString stringWithFormat:@"markdown %@: html", name]);
		CheckString(JSON(FlycutMarkdownToSlackDelta(markdown)), JSON([c objectForKey:@"delta"]), [NSString stringWithFormat:@"markdown %@: delta", name]);
	}
}

static void ConversionFixtures(void)
{
	for ( NSDictionary *c in Fixture(@"delta") ) {
		NSString *name = [c objectForKey:@"name"], *markdown = [c objectForKey:@"markdown"];
		CheckString(FlycutSlackDeltaToMarkdown([c objectForKey:@"delta"]), markdown, [NSString stringWithFormat:@"delta %@", name]);
		CheckString(FlycutSlackDeltaToMarkdown(FlycutMarkdownToSlackDelta(markdown)), markdown, [NSString stringWithFormat:@"delta %@: settles", name]);
	}
	for ( NSDictionary *c in Fixture(@"html") )
		CheckString(FlycutHTMLToMarkdown([c objectForKey:@"html"]), [c objectForKey:@"markdown"], [NSString stringWithFormat:@"html %@", [c objectForKey:@"name"]]);
	for ( NSDictionary *c in Fixture(@"detect") )
		CHECK(FlycutLooksLikeMarkdown([c objectForKey:@"text"]) == [[c objectForKey:@"markdown"] boolValue], "detect %s", [[c objectForKey:@"name"] UTF8String]);
}

static void EnrichFixtures(void)
{
	for ( NSDictionary *c in Fixture(@"enrich") ) {
		NSString *name = [c objectForKey:@"name"];
		NSDictionary *input = [c objectForKey:@"input"];
		id expected = [c objectForKey:@"expected"];
		NSString *custom = [input objectForKey:@"webCustomData"];
		FlycutRichEnrichment *result = FlycutEnrichFlavors([input objectForKey:@"text"], [input objectForKey:@"html"], [input objectForKey:@"markdown"],
														   custom ? [[[NSData alloc] initWithBase64EncodedString:custom options:0] autorelease] : nil);
		if ( expected == [NSNull null] ) {
			CHECK(result == nil, "enrich %s: nothing to add", [name UTF8String]);
			continue;
		}
		CheckString([result kind], [expected objectForKey:@"kind"], [NSString stringWithFormat:@"enrich %@: kind", name]);
		CheckString([result markdown], [expected objectForKey:@"markdown"], [NSString stringWithFormat:@"enrich %@: markdown", name]);
		CheckString([result text], [expected objectForKey:@"text"], [NSString stringWithFormat:@"enrich %@: text", name]);
		CheckString([result html], [expected objectForKey:@"html"], [NSString stringWithFormat:@"enrich %@: html", name]);
		// Byte for byte, the delta JSON included, so Slack reads the same thing from either port.
		CHECK([FlycutParseChromiumWebCustomData([result webCustomData]) isEqualToArray:[expected objectForKey:@"pairs"]], "enrich %s: web custom data pairs", [name UTF8String]);
		CHECK(FlycutEnrichFlavors([result text], [result html], nil, [result webCustomData]) == nil, "enrich %s: never enriched twice", [name UTF8String]);
	}
}

static void PickleRoundTrip(void)
{
	NSArray *pairs = @[@[@"a", @"xyz"], @[@"slack/texty", @"ünï 👋"]];
	CHECK([FlycutParseChromiumWebCustomData(FlycutChromiumWebCustomData(pairs)) isEqualToArray:pairs], "pickle round trip with odd lengths and surrogates");
	NSData *data = FlycutChromiumWebCustomData(@[@[@"k", @"value"]]);
	CHECK([FlycutParseChromiumWebCustomData([data subdataWithRange:NSMakeRange(0, [data length] - 4)]) count] == 0, "pickle: truncated container is empty");
}

static NSPasteboardItem *Item(NSDictionary *typesToData)
{
	NSPasteboardItem *item = [[[NSPasteboardItem alloc] init] autorelease];
	for ( NSString *type in typesToData ) {
		id value = [typesToData objectForKey:type];
		if ( [value isKindOfClass:[NSString class]] )
			[item setString:value forType:type];
		else
			[item setData:value forType:type];
	}
	return item;
}

static FlycutPasteboardCapture *CaptureOf(NSArray *objects, unsigned long long limit)
{
	NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
	[pasteboard clearContents];
	[pasteboard writeObjects:objects];
	FlycutPasteboardCapture *capture = [FlycutPasteboardCapture captureFromPasteboardNamed:[pasteboard name] sizeLimit:limit];
	[pasteboard releaseGlobally];
	return capture;
}

static NSData *Representation(FlycutPasteboardCapture *capture, NSString *type)
{
	for ( NSDictionary *representation in [[capture items] firstObject] )
		if ( [[representation objectForKey:@"t"] isEqualToString:type] )
			return [representation objectForKey:@"d"];
	return nil;
}

static NSArray *Keys(NSArray *pairs)
{
	NSMutableArray *keys = [NSMutableArray array];
	for ( NSArray *pair in pairs )
		[keys addObject:[pair firstObject]];
	return keys;
}

static NSString *Utf8(NSData *data)
{
	return data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
}

static void CaptureEnrichment(void)
{
	NSString *source = @"Plan:\n\n1. **one**\n2. two\n   - [link](https://l.test)\n";
	FlycutPasteboardCapture *capture = CaptureOf(@[Item(@{NSPasteboardTypeString: source})], 1 << 20);
	CHECK([capture onlyPlainText], "markdown copy starts as plain text only");
	CHECK([capture addRichFormats], "markdown copy gets rich formats");
	CHECK(![capture onlyPlainText], "and is no longer plain text only");
	CHECK([Utf8(Representation(capture, NSPasteboardTypeString)) isEqualToString:source] && [[capture text] isEqualToString:source], "its plain text stays the Markdown source");
	CHECK([Utf8(Representation(capture, NSPasteboardTypeHTML)) hasPrefix:@"<meta charset=\"utf-8\"><p>Plan:</p>\n<ol>"], "it carries HTML");
	NSArray *pairs = FlycutParseChromiumWebCustomData(Representation(capture, FlycutWebCustomDataType));
	CHECK(([Keys(pairs) isEqualToArray:@[@"public.utf8-plain-text", @"slack/texty", FlycutRichSourceMarkerType]]), "and Slack's delta with the marker");

	NSPasteboard *target = [NSPasteboard pasteboardWithUniqueName];
	CHECK([capture writeToPasteboard:target], "rich copy written back");
	NSSet *types = [NSSet setWithArray:[[[target pasteboardItems] firstObject] types]];
	CHECK([types containsObject:NSPasteboardTypeString] && [types containsObject:NSPasteboardTypeHTML] && [types containsObject:FlycutWebCustomDataType], "the pasteboard offers text, HTML and web custom data");
	FlycutPasteboardCapture *again = [FlycutPasteboardCapture captureFromPasteboardNamed:[target name] sizeLimit:1 << 20];
	CHECK(![again addRichFormats], "a copy already enriched is left alone");
	[target releaseGlobally];

	NSString *texty = JSON(@{@"ops": @[@{@"insert": @"Intro:\n"}, @{@"attributes": @{@"bold": @YES}, @"insert": @"a"}, @{@"attributes": @{@"list": @"ordered"}, @"insert": @"\n"},
									   @{@"insert": @"b"}, @{@"attributes": @{@"indent": @1, @"list": @"bullet"}, @"insert": @"\n"}]});
	NSData *slack = FlycutChromiumWebCustomData(@[@[@"public.utf8-plain-text", @"Intro:\na\nb"], @[@"slack/texty", texty]]);
	capture = CaptureOf(@[Item(@{NSPasteboardTypeString: @"Intro:\na\nb", FlycutWebCustomDataType: slack})], 1 << 20);
	CHECK([capture addRichFormats], "Slack copy gets rich formats");
	CHECK([[capture text] isEqualToString:@"Intro:\n1. a\n   - b"] && [Utf8(Representation(capture, NSPasteboardTypeString)) isEqualToString:[capture text]], "its plain text is laid out");
	CHECK([Utf8(Representation(capture, NSPasteboardTypeHTML)) rangeOfString:@"<li><strong>a</strong>"].location != NSNotFound, "it carries HTML");
	pairs = FlycutParseChromiumWebCustomData(Representation(capture, FlycutWebCustomDataType));
	CHECK([[[pairs objectAtIndex:1] lastObject] isEqualToString:texty] && [[[pairs lastObject] firstObject] isEqualToString:FlycutRichSourceMarkerType], "Slack's own delta is kept as it was");

	NSArray *declined = @[
		@[@"plain prose", @[Item(@{NSPasteboardTypeString: @"Hello there,\nhow are you?"})]],
		@[@"concealed", @[Item(@{NSPasteboardTypeString: source, @"org.nspasteboard.ConcealedType": @""})]],
		@[@"transient", @[Item(@{NSPasteboardTypeString: source, @"org.nspasteboard.TransientType": @""})]],
		@[@"with an image", @[Item(@{NSPasteboardTypeString: source, NSPasteboardTypePNG: [NSData dataWithBytes:"\x89PNG" length:4]})]],
		@[@"two items", @[Item(@{NSPasteboardTypeString: source}), Item(@{NSPasteboardTypeString: source})]],
	];
	for ( NSArray *c in declined ) {
		FlycutPasteboardCapture *declinedCapture = CaptureOf([c lastObject], 1 << 20);
		CHECK(![declinedCapture addRichFormats], "left alone: %s", [[c firstObject] UTF8String]);
	}
	NSString *bigHTML = [@"<p>" stringByPaddingToLength:4096 withString:@"x" startingAtIndex:0];
	FlycutPasteboardCapture *trimmed = CaptureOf(@[Item(@{NSPasteboardTypeString: source, NSPasteboardTypeHTML: bigHTML})], 1024);
	CHECK(![trimmed addRichFormats], "left alone: lost a representation to the size limit");

	NSPasteboard *paste = [NSPasteboard pasteboardWithUniqueName];
	CHECK(FlycutWriteRichMarkdown(source, paste), "pasting Markdown text writes rich formats");
	CHECK([[paste stringForType:NSPasteboardTypeString] isEqualToString:source] && [paste dataForType:FlycutWebCustomDataType] && [paste stringForType:NSPasteboardTypeHTML], "with the source as its plain text");
	CHECK(!FlycutWriteRichMarkdown(@"just words\nand more", paste), "plain text is not written as rich");
	[paste releaseGlobally];
}

// A real Slack composer copy kept outside the repository: only its structure is checked and printed.
static void RealSlackCopy(NSString *path)
{
	NSArray *pairs = FlycutParseChromiumWebCustomData([NSData dataWithContentsOfFile:path]);
	CHECK(([Keys(pairs) isEqualToArray:@[@"public.utf8-plain-text", @"slack/texty"]]), "real Slack copy: two pairs");
	NSDictionary *delta = [NSJSONSerialization JSONObjectWithData:[[[pairs lastObject] lastObject] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
	NSString *markdown = FlycutSlackDeltaToMarkdown(delta);
	CHECK([FlycutSlackDeltaToMarkdown(FlycutMarkdownToSlackDelta(markdown)) isEqualToString:markdown], "real Slack copy: settles through Markdown");
	NSUInteger (^listLines)(NSDictionary *) = ^NSUInteger(NSDictionary *d) {
		NSUInteger count = 0;
		for ( NSDictionary *op in [d objectForKey:@"ops"] )
			count += [[op objectForKey:@"attributes"] objectForKey:@"list"] != nil ? [[op objectForKey:@"insert"] length] : 0;
		return count;
	};
	CHECK(listLines(FlycutMarkdownToSlackDelta(markdown)) == listLines(delta), "real Slack copy: %lu list lines kept", (unsigned long)listLines(delta));
	FlycutRichEnrichment *enrichment = FlycutEnrichFlavors(@"flat", nil, nil, [NSData dataWithContentsOfFile:path]);
	CHECK([[enrichment kind] isEqualToString:@"slack"] && [[enrichment text] length] > 0, "real Slack copy: enriched as a Slack copy");
}

int main(int argc, const char *argv[])
{
	@autoreleasepool {
		if ( argc < 2 ) {
			fprintf(stderr, "usage: rich-clipboard-qa <fixtures directory> [slack-custom.bin]\n");
			return 2;
		}
		fixturesDirectory = [NSString stringWithUTF8String:argv[1]];
		CHECK([Fixture(@"markdown") count] && [Fixture(@"enrich") count], "fixtures load");
		MarkdownFixtures();
		ConversionFixtures();
		EnrichFixtures();
		PickleRoundTrip();
		CaptureEnrichment();
		if ( argc > 2 )
			RealSlackCopy([NSString stringWithUTF8String:argv[2]]);
		printf("%d failure%s\n", failures, failures == 1 ? "" : "s");
	}
	return failures ? 1 : 0;
}
