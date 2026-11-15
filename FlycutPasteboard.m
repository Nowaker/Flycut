//
//  FlycutPasteboard.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutPasteboard.h"
#import <ApplicationServices/ApplicationServices.h>
#import <CoreServices/CoreServices.h>
#import <ImageIO/ImageIO.h>

static NSString *const kUTF8Text = @"public.utf8-plain-text";
static NSString *const kUTF16Text = @"public.utf16-plain-text";
static NSString *const kUTF16ExternalText = @"public.utf16-external-plain-text";
static NSString *const kMacRomanText = @"com.apple.traditional-mac-plain-text";

static BOOL IsPlainTextType(NSString *type)
{
	return [type isEqualToString:kUTF8Text] || [type isEqualToString:kUTF16Text]
		|| [type isEqualToString:kUTF16ExternalText] || [type isEqualToString:kMacRomanText];
}

// The nspasteboard.org markers (source app, concealed, transient) say something about a copy; they aren't its content.
static BOOL IsMarkerType(NSString *type)
{
	return [type hasPrefix:@"org.nspasteboard."];
}

static BOOL TypeConformsTo(NSString *type, NSString *parent)
{
	return [type isEqualToString:parent] || UTTypeConformsTo((CFStringRef)type, (CFStringRef)parent);
}

// "PNG", "JPEG", "MPEG-4 movie" rather than a reverse-DNS identifier.
static NSString *TypeName(NSString *type)
{
	if ( TypeConformsTo(type, @"public.image") ) {
		NSString *extension = [(NSString *)UTTypeCopyPreferredTagWithClass((CFStringRef)type, kUTTagClassFilenameExtension) autorelease];
		if ( [extension length] )
			return [extension uppercaseString];
	}
	if ( !UTTypeIsDynamic((CFStringRef)type) ) {
		NSString *description = [(NSString *)UTTypeCopyDescription((CFStringRef)type) autorelease];
		if ( [description length] )
			return description;
	}
	return type;
}

static NSString *FormattedByteCount(NSUInteger length)
{
	return [NSByteCountFormatter stringFromByteCount:(long long)length countStyle:NSByteCountFormatterCountStyleFile];
}

#pragma mark Reading text

static NSString *TextOfRepresentation(NSString *type, NSData *data)
{
	if ( [type isEqualToString:kUTF8Text] )
		return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	if ( [type isEqualToString:kUTF16Text] )
		return [[[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding] autorelease];
	if ( [type isEqualToString:kUTF16ExternalText] )
		return [[[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding] autorelease];
	if ( [type isEqualToString:kMacRomanText] )
		return [[[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding] autorelease];
	return nil;
}

// AppKit reads HTML through WebKit, which only runs on the main thread.
static NSString *TextOfRichRepresentation(NSString *type, NSData *data)
{
	__block NSAttributedString *rich = nil;
	if ( [type isEqualToString:@"public.rtf"] )
		rich = [[NSAttributedString alloc] initWithRTF:data documentAttributes:NULL];
	else if ( [type isEqualToString:@"com.apple.flat-rtfd"] )
		rich = [[NSAttributedString alloc] initWithRTFD:data documentAttributes:NULL];
	else if ( [type isEqualToString:@"public.html"] ) {
		void (^readHTML)(void) = ^{ rich = [[NSAttributedString alloc] initWithHTML:data documentAttributes:NULL]; };
		if ( [NSThread isMainThread] )
			readHTML();
		else
			dispatch_sync(dispatch_get_main_queue(), readHTML);
	}
	NSString *text = [[rich string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[rich release];
	return [text length] ? text : nil;
}

static NSString *TextOfItems(NSArray *items)
{
	NSMutableArray *texts = [NSMutableArray array];
	for ( NSArray *item in items ) {
		NSString *text = nil;
		for ( NSString *type in @[kUTF8Text, kUTF16Text, kUTF16ExternalText, kMacRomanText] )
			for ( NSDictionary *representation in item )
				if ( !text && [[representation objectForKey:@"t"] isEqualToString:type] )
					text = TextOfRepresentation(type, [representation objectForKey:@"d"]);
		for ( NSString *type in @[@"public.rtf", @"com.apple.flat-rtfd", @"public.html"] )
			for ( NSDictionary *representation in item )
				if ( !text && [[representation objectForKey:@"t"] isEqualToString:type] )
					text = TextOfRichRepresentation(type, [representation objectForKey:@"d"]);
		if ( [text length] )
			[texts addObject:text];
	}
	return [texts count] ? [texts componentsJoinedByString:@"\n"] : nil;
}

#pragma mark Describing data

// libjpeg scales its standard luminance table by S = 5000/Q below quality 50 and by 200 - 2Q above it,
// and most encoders do the same, so comparing the file's first table with the standard one gives Q back.
static int JPEGQuality(NSData *data)
{
	static const int standardLuminance[64] = {
		16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
		14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
		49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99 };
	const unsigned char *bytes = [data bytes];
	NSUInteger length = [data length], at = 2;
	if ( length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 )
		return -1;
	while ( at + 4 <= length && bytes[at] == 0xFF ) {
		unsigned char marker = bytes[at + 1];
		NSUInteger segment = ((NSUInteger)bytes[at + 2] << 8) | bytes[at + 3];
		if ( marker == 0xDB && at + 4 + 1 + 64 <= length && (bytes[at + 4] >> 4) == 0 ) {
			// Table values are in zigzag order; only their sum is compared, so the order doesn't matter.
			double sum = 0, standardSum = 0;
			for ( int i = 0; i < 64; i++ ) {
				sum += bytes[at + 5 + i];
				standardSum += standardLuminance[i];
			}
			double scale = sum * 100 / standardSum;
			double quality = scale <= 100 ? (200 - scale) / 2 : 5000 / scale;
			return (int)lround(MAX(1, MIN(100, quality)));
		}
		if ( marker == 0xDA )
			break;
		at += 2 + segment;
	}
	return -1;
}

static NSString *DescribeImage(NSString *type, NSData *data)
{
	NSMutableArray *parts = [NSMutableArray arrayWithObject:TypeName(type)];
	CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
	size_t frames = source ? CGImageSourceGetCount(source) : 0;
	if ( frames > 0 ) {
		NSDictionary *properties = [(NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL) autorelease];
		NSInteger width = [[properties objectForKey:(id)kCGImagePropertyPixelWidth] integerValue];
		NSInteger height = [[properties objectForKey:(id)kCGImagePropertyPixelHeight] integerValue];
		if ( width > 0 && height > 0 )
			[parts addObject:[NSString stringWithFormat:@"%ld×%ld", (long)width, (long)height]];
	}
	if ( source )
		CFRelease(source);
	[parts addObject:FormattedByteCount([data length])];
	int quality = TypeConformsTo(type, @"public.jpeg") ? JPEGQuality(data) : -1;
	if ( quality > 0 )
		[parts addObject:[NSString stringWithFormat:@"~%d%% quality", quality]];
	if ( frames > 1 )
		[parts addObject:[NSString stringWithFormat:@"%lu frames", (unsigned long)frames]];
	return [NSString stringWithFormat:@"[image: %@]", [parts componentsJoinedByString:@", "]];
}

static NSString *DescribePDF(NSData *data)
{
	CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
	CGPDFDocumentRef document = provider ? CGPDFDocumentCreateWithProvider(provider) : NULL;
	size_t pages = document ? CGPDFDocumentGetNumberOfPages(document) : 0;
	CGPDFDocumentRelease(document);
	CGDataProviderRelease(provider);
	if ( pages == 0 )
		return [NSString stringWithFormat:@"[PDF: %@]", FormattedByteCount([data length])];
	return [NSString stringWithFormat:@"[PDF: %lu page%@, %@]", (unsigned long)pages, pages == 1 ? @"" : @"s", FormattedByteCount([data length])];
}

static NSString *DescribeItem(NSArray *item)
{
	NSDictionary *main = nil;
	NSString *kind = nil;
	for ( NSString *parent in @[@"public.image", @"com.adobe.pdf", @"public.movie", @"public.audio", @"public.file-url", @"public.url"] ) {
		for ( NSDictionary *representation in item )
			if ( TypeConformsTo([representation objectForKey:@"t"], parent) ) {
				main = representation;
				kind = parent;
				break;
			}
		if ( main )
			break;
	}
	if ( !main ) {
		for ( NSDictionary *representation in item )
			if ( !IsMarkerType([representation objectForKey:@"t"]) ) {
				main = representation;
				break;
			}
	}
	if ( !main )
		return nil;

	NSString *type = [main objectForKey:@"t"];
	NSData *data = [main objectForKey:@"d"];
	if ( [kind isEqualToString:@"public.image"] )
		return DescribeImage(type, data);
	if ( [kind isEqualToString:@"com.adobe.pdf"] )
		return DescribePDF(data);
	if ( [kind isEqualToString:@"public.movie"] || [kind isEqualToString:@"public.audio"] )
		return [NSString stringWithFormat:@"[%@: %@, %@]", [kind isEqualToString:@"public.movie"] ? @"video" : @"audio", TypeName(type), FormattedByteCount([data length])];
	if ( [kind isEqualToString:@"public.file-url"] || [kind isEqualToString:@"public.url"] ) {
		NSString *string = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
		NSURL *url = string ? [NSURL URLWithString:string] : nil;
		if ( [url isFileURL] )
			return [NSString stringWithFormat:@"[file: %@]", [[url path] lastPathComponent]];
		if ( url )
			return [NSString stringWithFormat:@"[link: %@]", string];
	}
	return [NSString stringWithFormat:@"[object: %@, %@]", TypeName(type), FormattedByteCount([data length])];
}

NSString *FlycutDescribePasteboardItems(NSArray *items)
{
	NSMutableArray *descriptions = [NSMutableArray array];
	for ( NSArray *item in items ) {
		NSString *description = DescribeItem(item);
		if ( description )
			[descriptions addObject:description];
	}
	return [descriptions count] ? [descriptions componentsJoinedByString:@" "] : nil;
}

#pragma mark Capture

@implementation FlycutPasteboardCapture

@synthesize items, types, text, itemsDescription, primaryType, onlyPlainText;

// Keeps plain text whatever its size; otherwise drops the largest representations until the rest fit.
static void DropRepresentationsBeyond(NSMutableArray *items, unsigned long long sizeLimit)
{
	unsigned long long total = 0;
	for ( NSArray *item in items )
		for ( NSDictionary *representation in item )
			total += [[representation objectForKey:@"d"] length];
	while ( total > sizeLimit ) {
		NSMutableArray *largestItem = nil;
		NSDictionary *largest = nil;
		for ( NSMutableArray *item in items )
			for ( NSDictionary *representation in item )
				if ( !IsPlainTextType([representation objectForKey:@"t"])
					&& [[representation objectForKey:@"d"] length] > [[largest objectForKey:@"d"] length] ) {
					largest = representation;
					largestItem = item;
				}
		if ( !largest )
			break;
		total -= [[largest objectForKey:@"d"] length];
		[largestItem removeObjectIdenticalTo:largest];
	}
	[items filterUsingPredicate:[NSPredicate predicateWithFormat:@"SELF.@count > 0"]];
}

+(instancetype) captureFromPasteboardNamed:(NSString *)name sizeLimit:(unsigned long long)sizeLimit
{
	PasteboardRef pasteboard = NULL;
	if ( PasteboardCreate((CFStringRef)name, &pasteboard) != noErr || !pasteboard )
		return nil;
	PasteboardSynchronize(pasteboard);
	ItemCount count = 0;
	PasteboardGetItemCount(pasteboard, &count);

	NSMutableArray *items = [NSMutableArray array];
	NSMutableArray *offered = [NSMutableArray array];
	for ( ItemCount index = 1; index <= count; index++ ) {
		PasteboardItemID itemId = 0;
		CFArrayRef flavors = NULL;
		if ( PasteboardGetItemIdentifier(pasteboard, index, &itemId) != noErr
			|| PasteboardCopyItemFlavors(pasteboard, itemId, &flavors) != noErr || !flavors )
			continue;
		NSMutableArray *item = [NSMutableArray array];
		for ( NSString *flavor in (NSArray *)flavors ) {
			[offered addObject:flavor];
			PasteboardFlavorFlags flags = 0;
			PasteboardGetItemFlavorFlags(pasteboard, itemId, (CFStringRef)flavor, &flags);
			// A flavor the copying app promised is read, which makes the app provide it, as pasting would;
			// one macOS would only make by translating another is left out.
			if ( flags & (kPasteboardFlavorSystemTranslated | kPasteboardFlavorRequestOnly | kPasteboardFlavorNotSaved) )
				continue;
			CFDataRef data = NULL;
			if ( PasteboardCopyItemFlavorData(pasteboard, itemId, (CFStringRef)flavor, &data) == noErr && data ) {
				[item addObject:@{@"t": flavor, @"d": (NSData *)data}];
				CFRelease(data);
			}
		}
		CFRelease(flavors);
		if ( [item count] )
			[items addObject:item];
	}
	CFRelease(pasteboard);
	if ( [items count] == 0 )
		return nil;

	FlycutPasteboardCapture *capture = [[[FlycutPasteboardCapture alloc] init] autorelease];
	capture->types = [[[NSOrderedSet orderedSetWithArray:offered] array] retain];
	capture->text = [TextOfItems(items) retain];
	capture->itemsDescription = [FlycutDescribePasteboardItems(items) retain];
	DropRepresentationsBeyond(items, sizeLimit);
	capture->items = [items retain];

	BOOL plain = [items count] == 1;
	for ( NSDictionary *representation in [items firstObject] )
		plain &= IsPlainTextType([representation objectForKey:@"t"]) || IsMarkerType([representation objectForKey:@"t"]);
	capture->onlyPlainText = plain && capture->text != nil;

	NSString *main = nil;
	for ( NSDictionary *representation in [items firstObject] )
		if ( !main && !IsMarkerType([representation objectForKey:@"t"]) )
			main = [representation objectForKey:@"t"];
	capture->primaryType = [(capture->text ? @"NSStringPboardType" : main) copy];
	return capture;
}

-(NSArray *) clippingItemsStoredIn:(FlycutBlobStore *)store
{
	NSMutableArray *stored = [NSMutableArray arrayWithCapacity:[items count]];
	for ( NSArray *item in items ) {
		NSMutableArray *storedItem = [NSMutableArray arrayWithCapacity:[item count]];
		for ( NSDictionary *representation in item ) {
			NSData *data = [representation objectForKey:@"d"];
			NSString *address = [store storeData:data];
			if ( !address )
				return nil;
			[storedItem addObject:@{@"t": [representation objectForKey:@"t"], @"b": address, @"n": @([data length])}];
		}
		[stored addObject:storedItem];
	}
	return stored;
}

-(void) dealloc
{
	[items release];
	[types release];
	[text release];
	[itemsDescription release];
	[primaryType release];
	[super dealloc];
}

@end

#pragma mark Pasting

BOOL FlycutWriteClippingItems(FlycutClipping *clipping, FlycutBlobStore *store, NSPasteboard *pasteboard)
{
	NSMutableArray *objects = [NSMutableArray array];
	for ( NSArray *item in [clipping items] ) {
		NSPasteboardItem *pasteboardItem = [[[NSPasteboardItem alloc] init] autorelease];
		for ( NSDictionary *representation in item ) {
			NSData *data = [store dataAtAddress:[representation objectForKey:@"b"]];
			if ( data )
				[pasteboardItem setData:data forType:[representation objectForKey:@"t"]];
		}
		if ( [[pasteboardItem types] count] )
			[objects addObject:pasteboardItem];
	}
	if ( [objects count] == 0 )
		return NO;
	[pasteboard clearContents];
	return [pasteboard writeObjects:objects];
}

NSImage *FlycutClippingImage(FlycutClipping *clipping, FlycutBlobStore *store)
{
	for ( NSArray *item in [clipping items] )
		for ( NSDictionary *representation in item ) {
			NSString *type = [representation objectForKey:@"t"];
			if ( !TypeConformsTo(type, @"public.image") && !TypeConformsTo(type, @"com.adobe.pdf") )
				continue;
			NSData *data = [store dataAtAddress:[representation objectForKey:@"b"]];
			NSImage *image = data ? [[[NSImage alloc] initWithData:data] autorelease] : nil;
			if ( image )
				return image;
		}
	return nil;
}
