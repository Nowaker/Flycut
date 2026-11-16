//
//  FlycutRichClipboard.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// Ported from opencode-tools' _lib/rich-clipboard; the sections below follow its files and functions in
// order, with the same names, so a change on one side can be found and repeated on the other. Strings are
// walked in UTF-16 units, as JavaScript does, and regular expressions are the TypeScript ones in ICU syntax.

#import "FlycutRichClipboard.h"

NSString *const FlycutWebCustomDataType = @"org.chromium.web-custom-data";
NSString *const FlycutMarkdownType = @"net.daringfireball.markdown";
NSString *const FlycutRichSourceMarkerType = @"application/x-rich-clipboard-source";
static NSString *const kSlackTextyType = @"slack/texty";
static NSString *const kPlainPairType = @"public.utf8-plain-text";

#pragma mark Helpers

static NSRegularExpression *Regex(NSString *pattern)
{
	static NSMutableDictionary *cache = nil;
	@synchronized ( [NSRegularExpression class] ) {
		if ( !cache )
			cache = [[NSMutableDictionary alloc] init];
		NSRegularExpression *regex = [cache objectForKey:pattern];
		if ( !regex ) {
			NSRegularExpressionOptions options = 0;
			NSString *source = pattern;
			if ( [pattern hasPrefix:@"(?m)"] ) {
				options = NSRegularExpressionAnchorsMatchLines;
				source = [pattern substringFromIndex:4];
			}
			regex = [NSRegularExpression regularExpressionWithPattern:source options:options error:NULL];
			NSCAssert(regex, @"bad pattern %@", pattern);
			[cache setObject:regex forKey:pattern];
		}
		return regex;
	}
}

static NSTextCheckingResult *Match(NSString *pattern, NSString *string)
{
	return [Regex(pattern) firstMatchInString:string options:0 range:NSMakeRange(0, [string length])];
}

static BOOL Test(NSString *pattern, NSString *string)
{
	return Match(pattern, string) != nil;
}

// A match that must start at `at`, as `regex.exec(text.slice(at))` with a `^` pattern does.
static NSTextCheckingResult *MatchAt(NSString *pattern, NSString *string, NSUInteger at)
{
	return [Regex(pattern) firstMatchInString:string options:NSMatchingAnchored range:NSMakeRange(at, [string length] - at)];
}

static NSString *Group(NSTextCheckingResult *match, NSString *string, NSUInteger group)
{
	NSRange range = [match rangeAtIndex:group];
	return range.location == NSNotFound ? nil : [string substringWithRange:range];
}

static NSString *Replace(NSString *pattern, NSString *string, NSString *template)
{
	return [Regex(pattern) stringByReplacingMatchesInString:string options:0 range:NSMakeRange(0, [string length]) withTemplate:template];
}

// 0 stands for JavaScript's undefined past either end.
static unichar At(NSString *s, NSInteger i)
{
	return i >= 0 && i < (NSInteger)[s length] ? [s characterAtIndex:i] : 0;
}

static NSString *Char(unichar c)
{
	return [NSString stringWithCharacters:&c length:1];
}

static BOOL IsWordAt(NSString *s, NSInteger i)
{
	unichar c = At(s, i);
	return c != 0 && (c == '_' || Test(@"^[\\p{L}\\p{N}]$", Char(c)));
}

static BOOL IsSpaceChar(unichar c)
{
	static NSCharacterSet *spaces = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableCharacterSet *set = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
		[set addCharactersInRange:NSMakeRange(0xFEFF, 1)];
		[set removeCharactersInRange:NSMakeRange(0x85, 1)];
		spaces = set;
	});
	return [spaces characterIsMember:c];
}

static BOOL IsSpaceAt(NSString *s, NSInteger i)
{
	unichar c = At(s, i);
	return c == 0 || IsSpaceChar(c);
}

static BOOL IsAsciiPunctuation(unichar c)
{
	return (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40) || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E);
}

static NSString *Trim(NSString *s)
{
	return Replace(@"^\\s+|\\s+$", s, @"");
}

static NSString *TrimEnd(NSString *s)
{
	return Replace(@"\\s+$", s, @"");
}

static NSString *TrimStart(NSString *s)
{
	return Replace(@"^\\s+", s, @"");
}

static BOOL IsBlank(NSString *s)
{
	return [Trim(s) length] == 0;
}

static NSString *Repeat(NSString *s, NSInteger count)
{
	NSMutableString *out = [NSMutableString string];
	for ( NSInteger i = 0; i < count; i++ )
		[out appendString:s];
	return out;
}

static NSArray *SplitLines(NSString *s)
{
	NSMutableArray *lines = [NSMutableArray array];
	for ( NSString *line in [s componentsSeparatedByString:@"\n"] )
		[lines addObject:[line hasSuffix:@"\r"] ? [line substringToIndex:[line length] - 1] : line];
	return lines;
}

static NSUInteger CountOf(NSString *s, unichar c)
{
	NSUInteger count = 0;
	for ( NSUInteger i = 0; i < [s length]; i++ )
		count += [s characterAtIndex:i] == c;
	return count;
}

#pragma mark markdown.ts: blocks

@interface FRBlock : NSObject {
@public
	NSString *kind;				// paragraph, heading, item, code, quote, rule, table
	NSMutableString *text;
	NSInteger level, number, depth;
	NSString *list;				// ordered, bullet
	NSString *lang;
	NSMutableArray *lines;		// quote lines
	NSArray *rows;				// table rows of cells
}
@end

@implementation FRBlock
+(FRBlock *) kind:(NSString *)kind
{
	FRBlock *block = [[[FRBlock alloc] init] autorelease];
	block->kind = [kind copy];
	block->text = [[NSMutableString alloc] init];
	return block;
}
-(BOOL) is:(NSString *)aKind { return [kind isEqualToString:aKind]; }
-(void) dealloc
{
	[kind release];
	[text release];
	[list release];
	[lang release];
	[lines release];
	[rows release];
	[super dealloc];
}
@end

static NSString *const kFenceOpen = @"^( {0,3})(`{3,}|~{3,})[ \\t]*([^`\\s]*)[^`]*$";
static NSString *const kFenceClose = @"^ {0,3}(`{3,}|~{3,})[ \\t]*$";
static NSString *const kHeading = @"^ {0,3}(#{1,6})[ \\t]+(.+?)(?:[ \\t]+#+)?[ \\t]*$";
static NSString *const kRule = @"^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$";
static NSString *const kQuote = @"^ {0,3}>[ \\t]?(.*)$";
static NSString *const kItem = @"^([ \\t]*)(\\d{1,9}[.)]|[-*+])[ \\t]+(.*)$";
static NSString *const kTableDelimiter = @"^[ \\t]*\\|?[ \\t]*:?-+:?[ \\t]*(?:\\|[ \\t]*:?-+:?[ \\t]*)+\\|?[ \\t]*$";

static NSInteger IndentWidth(NSString *whitespace)
{
	return [[whitespace stringByReplacingOccurrencesOfString:@"\t" withString:@"    "] length];
}

static NSString *LineContent(NSString *raw, BOOL *hardBreak)
{
	NSString *text = Trim(raw);
	*hardBreak = Test(@" {2,}$", raw) && [text length] > 0;
	NSUInteger backslashes = 0;
	while ( backslashes < [text length] && [text characterAtIndex:[text length] - 1 - backslashes] == '\\' )
		backslashes++;
	if ( backslashes % 2 == 1 ) {
		text = TrimEnd([text substringToIndex:[text length] - 1]);
		*hardBreak = YES;
	}
	return text;
}

static NSArray *SplitRow(NSString *line)
{
	NSString *row = Trim(line);
	if ( [row hasPrefix:@"|"] )
		row = [row substringFromIndex:1];
	if ( [row hasSuffix:@"|"] && ![row hasSuffix:@"\\|"] )
		row = [row substringToIndex:[row length] - 1];
	NSMutableArray *cells = [NSMutableArray array];
	NSMutableString *cell = [NSMutableString string];
	for ( NSUInteger i = 0; i < [row length]; i++ ) {
		unichar c = [row characterAtIndex:i];
		if ( c == '\\' && At(row, i + 1) == '|' ) {
			[cell appendString:@"|"];
			i++;
		} else if ( c == '|' ) {
			[cells addObject:Trim(cell)];
			[cell setString:@""];
		} else
			[cell appendString:Char(c)];
	}
	[cells addObject:Trim(cell)];
	return cells;
}

static NSArray *ParseBlocks(NSString *markdown)
{
	NSArray *lines = SplitLines(markdown);
	NSMutableArray *out = [NSMutableArray array];
	BOOL blank = YES, hardBreak = NO;
	FRBlock *joinable = nil;
	NSMutableArray *listIndents = [NSMutableArray array];
	NSUInteger index = 0;
	while ( index < [lines count] ) {
		NSString *raw = [lines objectAtIndex:index];
		NSTextCheckingResult *fence = Match(kFenceOpen, raw);
		if ( fence ) {
			NSString *marker = Group(fence, raw, 2);
			NSUInteger strip = [Group(fence, raw, 1) length];
			NSMutableArray *body = [NSMutableArray array];
			NSUInteger end = index + 1;
			for ( ; end < [lines count]; end++ ) {
				NSString *line = [lines objectAtIndex:end];
				NSTextCheckingResult *close = Match(kFenceClose, line);
				NSString *closing = close ? Group(close, line, 1) : nil;
				if ( closing && [closing characterAtIndex:0] == [marker characterAtIndex:0] && [closing length] >= [marker length] )
					break;
				NSUInteger leading = 0;
				while ( At(line, leading) == ' ' )
					leading++;
				[body addObject:[line substringFromIndex:MIN(leading, strip)]];
			}
			FRBlock *code = [FRBlock kind:@"code"];
			code->lang = [Group(fence, raw, 3) ?: @"" copy];
			[code->text setString:[body componentsJoinedByString:@"\n"]];
			[out addObject:code];
			index = end + 1;
			blank = NO;
			joinable = nil;
			[listIndents removeAllObjects];
			continue;
		}
		index++;
		if ( IsBlank(raw) ) {
			blank = YES;
			joinable = nil;
			continue;
		}
		NSTextCheckingResult *heading = Match(kHeading, raw);
		NSTextCheckingResult *quote = Match(kQuote, raw);
		NSTextCheckingResult *item = Match(kItem, raw);
		FRBlock *previous = [out lastObject];
		if ( Test(kRule, raw) ) {
			[out addObject:[FRBlock kind:@"rule"]];
			joinable = nil;
			[listIndents removeAllObjects];
		} else if ( heading ) {
			FRBlock *block = [FRBlock kind:@"heading"];
			block->level = [Group(heading, raw, 1) length];
			[block->text setString:Group(heading, raw, 2)];
			[out addObject:block];
			joinable = nil;
			[listIndents removeAllObjects];
		} else if ( quote ) {
			NSString *text = TrimEnd(Group(quote, raw, 1) ?: @"");
			if ( !blank && [previous is:@"quote"] )
				[previous->lines addObject:text];
			else {
				FRBlock *block = [FRBlock kind:@"quote"];
				block->lines = [[NSMutableArray alloc] initWithObjects:text, nil];
				[out addObject:block];
			}
			joinable = nil;
			[listIndents removeAllObjects];
		} else if ( item ) {
			NSInteger indent = IndentWidth(Group(item, raw, 1));
			while ( [listIndents count] && [[listIndents lastObject] integerValue] >= indent )
				[listIndents removeLastObject];
			NSInteger depth = [listIndents count];
			[listIndents addObject:@(indent)];
			NSString *marker = Group(item, raw, 2);
			BOOL ordered = [marker characterAtIndex:0] >= '0' && [marker characterAtIndex:0] <= '9';
			FRBlock *block = [FRBlock kind:@"item"];
			block->list = [(ordered ? @"ordered" : @"bullet") copy];
			block->number = ordered ? [marker integerValue] : 0;
			block->depth = depth;
			[block->text setString:LineContent(Group(item, raw, 3) ?: @"", &hardBreak)];
			[out addObject:block];
			joinable = block;
		} else if ( [raw rangeOfString:@"|"].location != NSNotFound && ![joinable is:@"paragraph"]
				   && Test(kTableDelimiter, index < [lines count] ? [lines objectAtIndex:index] : @"") ) {
			NSMutableArray *rows = [NSMutableArray arrayWithObject:SplitRow(raw)];
			index++;
			while ( index < [lines count] && [[lines objectAtIndex:index] rangeOfString:@"|"].location != NSNotFound
				   && [Trim([lines objectAtIndex:index]) length] ) {
				[rows addObject:SplitRow([lines objectAtIndex:index])];
				index++;
			}
			FRBlock *block = [FRBlock kind:@"table"];
			block->rows = [rows copy];
			[out addObject:block];
			joinable = nil;
			[listIndents removeAllObjects];
		} else {
			BOOL lineBreak = NO;
			NSString *content = LineContent(raw, &lineBreak);
			if ( joinable && !blank ) {
				[joinable->text appendString:hardBreak ? @"\n" : @" "];
				[joinable->text appendString:content];
			} else {
				FRBlock *block = [FRBlock kind:@"paragraph"];
				[block->text setString:content];
				[out addObject:block];
				joinable = block;
				[listIndents removeAllObjects];
			}
			hardBreak = lineBreak;
		}
		blank = NO;
	}
	return out;
}

#pragma mark markdown.ts: inline

@interface FRSpan : NSObject {
@public
	NSMutableString *text;
	NSDictionary *style;		// bold, code, italic, link, strike
	BOOL bare;
}
@end

@implementation FRSpan
+(FRSpan *) text:(NSString *)text style:(NSDictionary *)style bare:(BOOL)bare
{
	FRSpan *span = [[[FRSpan alloc] init] autorelease];
	span->text = [text mutableCopy];
	span->style = [style copy];
	span->bare = bare;
	return span;
}
-(void) dealloc
{
	[text release];
	[style release];
	[super dealloc];
}
@end

static void PushSpan(NSMutableArray *spans, FRSpan *span)
{
	if ( [span->text length] == 0 )
		return;
	FRSpan *last = [spans lastObject];
	if ( last && !last->bare && !span->bare && [last->style isEqualToDictionary:span->style] )
		[last->text appendString:span->text];
	else
		[spans addObject:[FRSpan text:span->text style:span->style bare:span->bare]];
}

static NSDictionary *WithStyle(NSDictionary *style, NSDictionary *extra)
{
	NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:style];
	[merged addEntriesFromDictionary:extra];
	return merged;
}

static NSUInteger BacktickRun(NSString *text, NSUInteger at)
{
	NSUInteger length = 0;
	while ( At(text, at + length) == '`' )
		length++;
	return length;
}

static NSInteger ClosingBackticks(NSString *text, NSUInteger from, NSUInteger length)
{
	for ( NSUInteger i = from; i < [text length]; i++ ) {
		if ( [text characterAtIndex:i] != '`' )
			continue;
		NSUInteger run = BacktickRun(text, i);
		if ( run == length )
			return i;
		i += run - 1;
	}
	return -1;
}

static NSInteger ClosingDouble(NSString *text, NSInteger at, unichar marker)
{
	if ( IsSpaceAt(text, at + 2) )
		return -1;
	if ( marker == '_' && IsWordAt(text, at - 1) )
		return -1;
	for ( NSInteger i = at + 3; i + 1 < (NSInteger)[text length]; i++ ) {
		if ( At(text, i) != marker || At(text, i + 1) != marker || At(text, i + 2) == marker )
			continue;
		if ( IsSpaceAt(text, i - 1) || At(text, i - 1) == '\\' )
			continue;
		if ( marker == '_' && IsWordAt(text, i + 2) )
			continue;
		return i;
	}
	return -1;
}

static NSInteger ClosingSingle(NSString *text, NSInteger at, unichar marker)
{
	if ( IsSpaceAt(text, at + 1) || IsWordAt(text, at - 1) || At(text, at - 1) == marker )
		return -1;
	for ( NSInteger i = at + 2; i < (NSInteger)[text length]; i++ ) {
		if ( At(text, i) != marker )
			continue;
		if ( At(text, i - 1) == marker || At(text, i + 1) == marker )
			continue;
		if ( IsSpaceAt(text, i - 1) || At(text, i - 1) == '\\' || IsWordAt(text, i + 1) )
			continue;
		return i;
	}
	return -1;
}

static BOOL LinkAt(NSString *text, NSUInteger at, NSString **label, NSString **url, NSUInteger *end)
{
	NSInteger depth = 0, close = -1;
	for ( NSUInteger i = at; i < [text length]; i++ ) {
		unichar c = [text characterAtIndex:i];
		if ( c == '\\' )
			i++;
		else if ( c == '[' )
			depth++;
		else if ( c == ']' && --depth == 0 ) {
			close = i;
			break;
		}
	}
	if ( close < 0 || At(text, close + 1) != '(' )
		return NO;
	NSUInteger i = close + 2;
	NSMutableString *destination = [NSMutableString string];
	if ( At(text, i) == '<' ) {
		NSRange gt = [text rangeOfString:@">" options:0 range:NSMakeRange(i, [text length] - i)];
		if ( gt.location == NSNotFound )
			return NO;
		[destination setString:[text substringWithRange:NSMakeRange(i + 1, gt.location - i - 1)]];
		i = gt.location + 1;
	} else {
		NSInteger parens = 0;
		for ( ; i < [text length]; i++ ) {
			unichar c = [text characterAtIndex:i];
			if ( IsSpaceChar(c) )
				break;
			if ( c == '(' )
				parens++;
			else if ( c == ')' && parens-- == 0 )
				break;
			[destination appendString:Char(c)];
		}
	}
	while ( At(text, i) == ' ' )
		i++;
	unichar quote = At(text, i);
	if ( quote == '"' || quote == '\'' ) {
		NSRange closing = [text rangeOfString:Char(quote) options:0 range:NSMakeRange(i + 1, [text length] - i - 1)];
		if ( closing.location == NSNotFound )
			return NO;
		i = closing.location + 1;
		while ( At(text, i) == ' ' )
			i++;
	}
	if ( At(text, i) != ')' )
		return NO;
	*label = [text substringWithRange:NSMakeRange(at + 1, close - at - 1)];
	*url = destination;
	*end = i + 1;
	return YES;
}

static NSString *BareUrlAt(NSString *text, NSUInteger at)
{
	if ( IsWordAt(text, (NSInteger)at - 1) )
		return nil;
	NSTextCheckingResult *match = MatchAt(@"https?://[^\\s<>]+", text, at);
	if ( !match )
		return nil;
	NSString *url = [text substringWithRange:[match range]];
	for ( ;; ) {
		unichar last = [url characterAtIndex:[url length] - 1];
		if ( [@".,;:!?'\"*_~" rangeOfString:Char(last)].location != NSNotFound )
			url = [url substringToIndex:[url length] - 1];
		else if ( last == ')' && CountOf(url, '(') < CountOf(url, ')') )
			url = [url substringToIndex:[url length] - 1];
		else
			break;
	}
	return Test(@"^https?://.", url) ? url : nil;
}

static NSArray *ParseInline(NSString *text, NSDictionary *style)
{
	NSMutableArray *spans = [NSMutableArray array];
	NSMutableString *literal = [NSMutableString string];
	void (^flush)(void) = ^{
		PushSpan(spans, [FRSpan text:literal style:style bare:NO]);
		[literal setString:@""];
	};
	NSUInteger index = 0, length = [text length];
	while ( index < length ) {
		unichar c = [text characterAtIndex:index];
		unichar next = At(text, index + 1);
		if ( c == '\\' && next && IsAsciiPunctuation(next) ) {
			[literal appendString:Char(next)];
			index += 2;
			continue;
		}
		if ( c == '`' ) {
			NSUInteger run = BacktickRun(text, index);
			NSInteger close = ClosingBackticks(text, index + run, run);
			if ( close < 0 ) {
				[literal appendString:Repeat(@"`", run)];
				index += run;
				continue;
			}
			flush();
			NSString *code = [text substringWithRange:NSMakeRange(index + run, close - index - run)];
			if ( [code length] >= 2 && [code hasPrefix:@" "] && [code hasSuffix:@" "] && [Trim(code) length] )
				code = [code substringWithRange:NSMakeRange(1, [code length] - 2)];
			PushSpan(spans, [FRSpan text:code style:WithStyle(style, @{@"code": @YES}) bare:NO]);
			index = close + run;
			continue;
		}
		if ( (c == '*' || c == '_' || c == '~') && next == c ) {
			NSInteger close = ClosingDouble(text, index, c);
			if ( close < 0 ) {
				[literal appendString:[NSString stringWithFormat:@"%C%C", c, c]];
				index += 2;
				continue;
			}
			flush();
			NSDictionary *extra = c == '~' ? @{@"strike": @YES} : @{@"bold": @YES};
			for ( FRSpan *span in ParseInline([text substringWithRange:NSMakeRange(index + 2, close - index - 2)], WithStyle(style, extra)) )
				PushSpan(spans, span);
			index = close + 2;
			continue;
		}
		if ( c == '*' || c == '_' ) {
			NSInteger close = ClosingSingle(text, index, c);
			if ( close >= 0 ) {
				flush();
				for ( FRSpan *span in ParseInline([text substringWithRange:NSMakeRange(index + 1, close - index - 1)], WithStyle(style, @{@"italic": @YES})) )
					PushSpan(spans, span);
				index = close + 1;
				continue;
			}
		}
		if ( c == '[' ) {
			NSString *label = nil, *url = nil;
			NSUInteger end = 0;
			if ( LinkAt(text, index, &label, &url, &end) ) {
				flush();
				for ( FRSpan *span in ParseInline([label length] ? label : url, WithStyle(style, @{@"link": url})) )
					PushSpan(spans, span);
				index = end;
				continue;
			}
		}
		if ( c == '<' ) {
			NSTextCheckingResult *match = MatchAt(@"<((?:https?|mailto):[^\\s<>]+)>", text, index);
			if ( match ) {
				flush();
				NSString *url = Group(match, text, 1);
				PushSpan(spans, [FRSpan text:url style:WithStyle(style, @{@"link": url}) bare:YES]);
				index += [url length] + 2;
				continue;
			}
		}
		if ( c == 'h' && ![style objectForKey:@"link"] ) {
			NSString *url = BareUrlAt(text, index);
			if ( url ) {
				flush();
				PushSpan(spans, [FRSpan text:url style:WithStyle(style, @{@"link": url}) bare:YES]);
				index += [url length];
				continue;
			}
		}
		[literal appendString:Char(c)];
		index++;
	}
	flush();
	return spans;
}

// Runs of spans that share a link (or have none), as {link?, bare, spans}.
static NSArray *LinkRuns(NSArray *spans)
{
	NSMutableArray *runs = [NSMutableArray array];
	for ( FRSpan *span in spans ) {
		NSMutableDictionary *last = [runs lastObject];
		NSString *link = [span->style objectForKey:@"link"];
		NSString *lastLink = [last objectForKey:@"link"];
		BOOL lastBare = [[last objectForKey:@"bare"] boolValue];
		if ( last && link && [lastLink isEqualToString:link] && !span->bare && !lastBare )
			[[last objectForKey:@"spans"] addObject:span];
		else if ( last && !link && !lastLink )
			[[last objectForKey:@"spans"] addObject:span];
		else {
			NSMutableDictionary *run = [NSMutableDictionary dictionaryWithObjectsAndKeys:@(span->bare), @"bare", [NSMutableArray arrayWithObject:span], @"spans", nil];
			if ( link )
				[run setObject:link forKey:@"link"];
			[runs addObject:run];
		}
	}
	return runs;
}

static NSString *SpansText(NSArray *spans)
{
	NSMutableString *text = [NSMutableString string];
	for ( FRSpan *span in spans )
		[text appendString:span->text];
	return text;
}

static NSString *PlainInline(NSString *text)
{
	NSMutableString *out = [NSMutableString string];
	for ( NSDictionary *run in LinkRuns(ParseInline(text, @{})) ) {
		NSString *label = SpansText([run objectForKey:@"spans"]);
		NSString *link = [run objectForKey:@"link"];
		if ( !link || [[run objectForKey:@"bare"] boolValue] || [label isEqualToString:link] )
			[out appendString:label];
		else
			[out appendFormat:@"%@ (%@)", label, link];
	}
	return out;
}

static NSString *PadEnd(NSString *s, NSUInteger width)
{
	return [s length] >= width ? s : [s stringByAppendingString:Repeat(@" ", width - [s length])];
}

static NSArray *TableLines(NSArray *rows)
{
	NSMutableArray *cells = [NSMutableArray array];
	NSUInteger columns = 0;
	for ( NSArray *row in rows ) {
		NSMutableArray *plain = [NSMutableArray array];
		for ( NSString *cell in row )
			[plain addObject:PlainInline(cell)];
		[cells addObject:plain];
		columns = MAX(columns, [plain count]);
	}
	NSMutableArray *widths = [NSMutableArray array];
	for ( NSUInteger column = 0; column < columns; column++ ) {
		NSUInteger width = 3;
		for ( NSArray *row in cells )
			if ( column < [row count] )
				width = MAX(width, [[row objectAtIndex:column] length]);
		[widths addObject:@(width)];
	}
	NSString *(^line)(NSArray *) = ^NSString *(NSArray *row) {
		NSMutableArray *padded = [NSMutableArray array];
		for ( NSUInteger column = 0; column < columns; column++ )
			[padded addObject:PadEnd(column < [row count] ? [row objectAtIndex:column] : @"", [[widths objectAtIndex:column] unsignedIntegerValue])];
		return [NSString stringWithFormat:@"| %@ |", [padded componentsJoinedByString:@" | "]];
	};
	NSMutableArray *dashes = [NSMutableArray array];
	for ( NSNumber *width in widths )
		[dashes addObject:Repeat(@"-", [width integerValue] + 2)];
	NSMutableArray *out = [NSMutableArray arrayWithObject:line([cells count] ? [cells objectAtIndex:0] : @[])];
	[out addObject:[NSString stringWithFormat:@"|%@|", [dashes componentsJoinedByString:@"|"]]];
	for ( NSUInteger i = 1; i < [cells count]; i++ )
		[out addObject:line([cells objectAtIndex:i])];
	return out;
}

#pragma mark markdown.ts: renderers

NSString *FlycutMarkdownToPlain(NSString *markdown, BOOL readable)
{
	NSMutableArray *counters = [NSMutableArray array];	// NSNull for "no number at this depth"
	NSMutableString *out = [NSMutableString string];
	FRBlock *previous = nil;
	for ( FRBlock *block in ParseBlocks(markdown) ) {
		if ( previous )
			[out appendString:[block is:@"item"] ? @"\n" : @"\n\n"];
		if ( ![block is:@"item"] )
			[counters removeAllObjects];
		if ( [block is:@"paragraph"] || [block is:@"heading"] )
			[out appendString:PlainInline(block->text)];
		else if ( [block is:@"item"] ) {
			if ( !readable )
				[out appendString:PlainInline(block->text)];
			else {
				NSInteger depth = block->depth;
				if ( (NSInteger)[counters count] > depth + 1 )
					[counters removeObjectsInRange:NSMakeRange(depth + 1, [counters count] - depth - 1)];
				while ( (NSInteger)[counters count] <= depth )
					[counters addObject:[NSNull null]];
				id last = [counters objectAtIndex:depth];
				NSString *marker = @"- ";
				if ( [block->list isEqualToString:@"ordered"] ) {
					NSInteger number = last == [NSNull null] ? block->number : [last integerValue] + 1;
					[counters replaceObjectAtIndex:depth withObject:@(number)];
					marker = [NSString stringWithFormat:@"%ld. ", (long)number];
				} else
					[counters replaceObjectAtIndex:depth withObject:[NSNull null]];
				[out appendFormat:@"%@%@%@", Repeat(@"   ", depth), marker, PlainInline(block->text)];
			}
		} else if ( [block is:@"code"] )
			[out appendString:readable ? [NSString stringWithFormat:@"```%@\n%@\n```", block->lang, block->text] : block->text];
		else if ( [block is:@"quote"] ) {
			NSMutableArray *lines = [NSMutableArray array];
			for ( NSString *line in block->lines )
				[lines addObject:readable ? ([line length] ? [@"> " stringByAppendingString:PlainInline(line)] : @">") : PlainInline(line)];
			[out appendString:[lines componentsJoinedByString:@"\n"]];
		} else if ( [block is:@"rule"] )
			[out appendString:@"---"];
		else if ( [block is:@"table"] )
			[out appendString:[TableLines(block->rows) componentsJoinedByString:@"\n"]];
		previous = block;
	}
	return out;
}

static NSDictionary *StyleAttributes(NSDictionary *style)
{
	NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
	for ( NSString *key in @[@"bold", @"code", @"italic", @"strike"] )
		if ( [[style objectForKey:key] boolValue] )
			[attributes setObject:@YES forKey:key];
	if ( [style objectForKey:@"link"] )
		[attributes setObject:[style objectForKey:@"link"] forKey:@"link"];
	return attributes;
}

static NSMutableDictionary *Op(NSString *insert, NSDictionary *attributes)
{
	NSMutableDictionary *op = [NSMutableDictionary dictionaryWithObject:[[insert mutableCopy] autorelease] forKey:@"insert"];
	if ( [attributes count] )
		[op setObject:attributes forKey:@"attributes"];
	return op;
}

static NSArray *TextOps(NSArray *spans)
{
	NSMutableArray *ops = [NSMutableArray array];
	for ( FRSpan *span in spans ) {
		NSDictionary *attributes = StyleAttributes(span->style);
		NSArray *parts = [span->text componentsSeparatedByString:@"\n"];
		for ( NSUInteger i = 0; i < [parts count]; i++ ) {
			if ( i > 0 )
				[ops addObject:Op(@"\n", nil)];
			if ( [[parts objectAtIndex:i] length] )
				[ops addObject:Op([parts objectAtIndex:i], attributes)];
		}
	}
	return ops;
}

NSDictionary *FlycutMarkdownToSlackDelta(NSString *markdown)
{
	NSMutableArray *ops = [NSMutableArray array];
	FRBlock *previous = nil;
	for ( FRBlock *block in ParseBlocks(markdown) ) {
		if ( previous && !([previous is:@"item"] && [block is:@"item"]) ) {
			BOOL terminated = [previous is:@"item"] || [previous is:@"code"] || [previous is:@"quote"] || [previous is:@"table"];
			[ops addObject:Op(terminated || [block is:@"item"] ? @"\n" : @"\n\n", nil)];
		}
		if ( [block is:@"paragraph"] )
			[ops addObjectsFromArray:TextOps(ParseInline(block->text, @{}))];
		else if ( [block is:@"heading"] )
			[ops addObjectsFromArray:TextOps(ParseInline(block->text, @{@"bold": @YES}))];
		else if ( [block is:@"item"] ) {
			[ops addObjectsFromArray:TextOps(ParseInline(block->text, @{}))];
			[ops addObject:Op(@"\n", block->depth > 0 ? @{@"indent": @(block->depth), @"list": block->list} : @{@"list": block->list})];
		} else if ( [block is:@"code"] || [block is:@"table"] ) {
			for ( NSString *text in [block is:@"code"] ? [block->text componentsSeparatedByString:@"\n"] : TableLines(block->rows) ) {
				if ( [text length] )
					[ops addObject:Op(text, nil)];
				[ops addObject:Op(@"\n", @{@"code-block": @YES})];
			}
		} else if ( [block is:@"quote"] ) {
			for ( NSString *text in block->lines ) {
				[ops addObjectsFromArray:TextOps(ParseInline(text, @{}))];
				[ops addObject:Op(@"\n", @{@"blockquote": @YES})];
			}
		} else if ( [block is:@"rule"] )
			[ops addObject:Op(@"---", nil)];
		previous = block;
	}
	NSMutableArray *merged = [NSMutableArray array];
	for ( NSMutableDictionary *op in ops ) {
		NSMutableDictionary *last = [merged lastObject];
		NSDictionary *a = [last objectForKey:@"attributes"] ?: @{}, *b = [op objectForKey:@"attributes"] ?: @{};
		if ( last && [a isEqualToDictionary:b] )
			[[last objectForKey:@"insert"] appendString:[op objectForKey:@"insert"]];
		else
			[merged addObject:op];
	}
	return @{@"ops": merged};
}

static NSString *EscapeHTML(NSString *text)
{
	NSMutableString *out = [[text mutableCopy] autorelease];
	[out replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [out length])];
	[out replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [out length])];
	[out replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [out length])];
	[out replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, [out length])];
	return out;
}

static NSString *HTMLInline(NSString *text)
{
	NSMutableString *out = [NSMutableString string];
	for ( NSDictionary *run in LinkRuns(ParseInline(text, @{})) ) {
		NSMutableString *inner = [NSMutableString string];
		for ( FRSpan *span in [run objectForKey:@"spans"] ) {
			NSString *html = [EscapeHTML(span->text) stringByReplacingOccurrencesOfString:@"\n" withString:@"<br />\n"];
			if ( [[span->style objectForKey:@"code"] boolValue] )
				html = [NSString stringWithFormat:@"<code>%@</code>", html];
			if ( [[span->style objectForKey:@"strike"] boolValue] )
				html = [NSString stringWithFormat:@"<del>%@</del>", html];
			if ( [[span->style objectForKey:@"italic"] boolValue] )
				html = [NSString stringWithFormat:@"<em>%@</em>", html];
			if ( [[span->style objectForKey:@"bold"] boolValue] )
				html = [NSString stringWithFormat:@"<strong>%@</strong>", html];
			[inner appendString:html];
		}
		NSString *link = [run objectForKey:@"link"];
		if ( link )
			[out appendFormat:@"<a href=\"%@\">%@</a>", EscapeHTML(link), inner];
		else
			[out appendString:inner];
	}
	return out;
}

static NSString *HTMLList(NSArray *items)
{
	NSMutableString *html = [NSMutableString string];
	NSMutableArray *open = [NSMutableArray array];
	void (^close)(void) = ^{
		[html appendFormat:@"</li>\n</%@>\n", [[open lastObject] isEqualToString:@"ordered"] ? @"ol" : @"ul"];
		[open removeLastObject];
	};
	for ( FRBlock *item in items ) {
		NSInteger depth = MIN(item->depth, (NSInteger)[open count]);
		while ( (NSInteger)[open count] > depth + 1 )
			close();
		if ( (NSInteger)[open count] == depth + 1 && ![[open lastObject] isEqualToString:item->list] )
			close();
		if ( (NSInteger)[open count] == depth + 1 )
			[html appendString:@"</li>\n"];
		else {
			if ( [open count] )
				[html appendString:@"\n"];
			BOOL ordered = [item->list isEqualToString:@"ordered"];
			NSString *start = ordered && item->number != 1 ? [NSString stringWithFormat:@" start=\"%ld\"", (long)item->number] : @"";
			[html appendString:ordered ? [NSString stringWithFormat:@"<ol%@>\n", start] : @"<ul>\n"];
			[open addObject:item->list];
		}
		[html appendFormat:@"<li>%@", HTMLInline(item->text)];
	}
	while ( [open count] )
		close();
	return html;
}

NSString *FlycutMarkdownToHTML(NSString *markdown)
{
	NSMutableString *html = [NSMutableString stringWithString:@"<meta charset=\"utf-8\">"];
	NSArray *blocks = ParseBlocks(markdown);
	for ( NSUInteger index = 0; index < [blocks count]; index++ ) {
		FRBlock *block = [blocks objectAtIndex:index];
		if ( [block is:@"paragraph"] )
			[html appendFormat:@"<p>%@</p>\n", HTMLInline(block->text)];
		else if ( [block is:@"heading"] )
			[html appendFormat:@"<h%ld>%@</h%ld>\n", (long)block->level, HTMLInline(block->text), (long)block->level];
		else if ( [block is:@"item"] ) {
			NSMutableArray *items = [NSMutableArray array];
			while ( index < [blocks count] && [[blocks objectAtIndex:index] is:@"item"] )
				[items addObject:[blocks objectAtIndex:index++]];
			index--;
			[html appendString:HTMLList(items)];
		} else if ( [block is:@"code"] ) {
			NSString *lang = [block->lang length] ? [NSString stringWithFormat:@" class=\"language-%@\"", EscapeHTML(block->lang)] : @"";
			[html appendFormat:@"<pre><code%@>%@%@</code></pre>\n", lang, EscapeHTML(block->text), [block->text length] ? @"\n" : @""];
		} else if ( [block is:@"quote"] ) {
			NSMutableArray *paragraphs = [NSMutableArray arrayWithObject:[NSMutableArray array]];
			for ( NSString *line in block->lines ) {
				if ( [line length] )
					[[paragraphs lastObject] addObject:HTMLInline(line)];
				else if ( [[paragraphs lastObject] count] )
					[paragraphs addObject:[NSMutableArray array]];
			}
			[html appendString:@"<blockquote>\n"];
			for ( NSArray *paragraph in paragraphs )
				if ( [paragraph count] )
					[html appendFormat:@"<p>%@</p>\n", [paragraph componentsJoinedByString:@"<br />\n"]];
			[html appendString:@"</blockquote>\n"];
		} else if ( [block is:@"rule"] )
			[html appendString:@"<hr />\n"];
		else if ( [block is:@"table"] ) {
			NSString *(^row)(NSArray *, NSString *) = ^NSString *(NSArray *cells, NSString *tag) {
				NSMutableString *out = [NSMutableString stringWithString:@"<tr>\n"];
				for ( NSString *cell in cells )
					[out appendFormat:@"<%@>%@</%@>\n", tag, HTMLInline(cell), tag];
				[out appendString:@"</tr>\n"];
				return out;
			};
			[html appendFormat:@"<table>\n<thead>\n%@</thead>\n", row([block->rows count] ? [block->rows objectAtIndex:0] : @[], @"th")];
			if ( [block->rows count] > 1 ) {
				[html appendString:@"<tbody>\n"];
				for ( NSUInteger i = 1; i < [block->rows count]; i++ )
					[html appendString:row([block->rows objectAtIndex:i], @"td")];
				[html appendString:@"</tbody>\n"];
			}
			[html appendString:@"</table>\n"];
		}
	}
	return html;
}

#pragma mark to-markdown.ts

@interface FRLine : NSObject {
@public
	NSMutableArray *spans;
	NSDictionary *format;		// blockquote, code-block, header, indent, list
}
@end

@implementation FRLine
+(FRLine *) spans:(NSArray *)spans format:(NSDictionary *)format
{
	FRLine *line = [[[FRLine alloc] init] autorelease];
	line->spans = [spans mutableCopy];
	line->format = [format copy];
	return line;
}
-(void) dealloc
{
	[spans release];
	[format release];
	[super dealloc];
}
@end

static BOOL Truthy(id value)
{
	if ( !value || value == [NSNull null] )
		return NO;
	if ( [value isKindOfClass:[NSString class]] )
		return [value length] > 0;
	if ( [value isKindOfClass:[NSNumber class]] )
		return [value doubleValue] != 0;
	return YES;
}

static NSDictionary *InlineStyle(NSDictionary *attributes)
{
	NSMutableDictionary *style = [NSMutableDictionary dictionary];
	for ( NSString *key in @[@"bold", @"code", @"italic", @"strike"] )
		if ( Truthy([attributes objectForKey:key]) )
			[style setObject:@YES forKey:key];
	id link = [attributes objectForKey:@"link"];
	if ( [link isKindOfClass:[NSString class]] && [link length] )
		[style setObject:link forKey:@"link"];
	return style;
}

static NSDictionary *LineFormat(NSDictionary *attributes)
{
	id list = [attributes objectForKey:@"list"];
	NSInteger indent = [[attributes objectForKey:@"indent"] respondsToSelector:@selector(integerValue)] ? [[attributes objectForKey:@"indent"] integerValue] : 0;
	NSInteger header = [[attributes objectForKey:@"header"] respondsToSelector:@selector(integerValue)] ? [[attributes objectForKey:@"header"] integerValue] : 0;
	if ( [list isEqual:@"ordered"] || [list isEqual:@"bullet"] )
		return indent > 0 ? @{@"indent": @(indent), @"list": list} : @{@"list": list};
	if ( Truthy([attributes objectForKey:@"code-block"]) )
		return @{@"code-block": @YES};
	if ( Truthy([attributes objectForKey:@"blockquote"]) )
		return @{@"blockquote": @YES};
	if ( header > 0 )
		return @{@"header": @(MIN(header, 6))};
	return @{};
}

static void AppendSpan(NSMutableArray *spans, NSString *text, NSDictionary *style)
{
	if ( ![text length] )
		return;
	FRSpan *last = [spans lastObject];
	if ( last && [last->style isEqualToDictionary:style] )
		[last->text appendString:text];
	else
		[spans addObject:[FRSpan text:text style:style bare:NO]];
}

static NSString *EmbedText(NSDictionary *insert)
{
	for ( id value in [insert allValues] ) {
		if ( ![value isKindOfClass:[NSDictionary class]] )
			continue;
		if ( [[value objectForKey:@"text"] isKindOfClass:[NSString class]] )
			return [value objectForKey:@"text"];
		if ( [[value objectForKey:@"name"] isKindOfClass:[NSString class]] )
			return [NSString stringWithFormat:@":%@:", [value objectForKey:@"name"]];
		if ( [[value objectForKey:@"label"] isKindOfClass:[NSString class]] )
			return [value objectForKey:@"label"];
	}
	return @"";
}

static NSArray *DeltaLines(NSArray *ops)
{
	NSMutableArray *lines = [NSMutableArray array];
	NSMutableArray *spans = [NSMutableArray array];
	for ( id op in ops ) {
		if ( ![op isKindOfClass:[NSDictionary class]] )
			continue;
		id insert = [op objectForKey:@"insert"];
		NSDictionary *attributes = [[op objectForKey:@"attributes"] isKindOfClass:[NSDictionary class]] ? [op objectForKey:@"attributes"] : nil;
		if ( [insert isKindOfClass:[NSDictionary class]] ) {
			AppendSpan(spans, EmbedText(insert), InlineStyle(attributes));
			continue;
		}
		if ( ![insert isKindOfClass:[NSString class]] )
			continue;
		NSArray *parts = [insert componentsSeparatedByString:@"\n"];
		for ( NSUInteger i = 0; i < [parts count]; i++ ) {
			AppendSpan(spans, [parts objectAtIndex:i], InlineStyle(attributes));
			if ( i < [parts count] - 1 ) {
				[lines addObject:[FRLine spans:spans format:LineFormat(attributes)]];
				spans = [NSMutableArray array];
			}
		}
	}
	if ( [spans count] )
		[lines addObject:[FRLine spans:spans format:@{}]];
	return lines;
}

static NSString *EscapeText(NSString *text)
{
	NSMutableString *out = [NSMutableString string];
	for ( NSUInteger i = 0; i < [text length]; i++ ) {
		unichar c = [text characterAtIndex:i];
		unichar previous = At(text, (NSInteger)i - 1), next = At(text, i + 1);
		if ( c == '\\' || c == '`' || c == '*' || c == '[' || c == ']' )
			[out appendFormat:@"\\%C", c];
		else if ( c == '_' && !(IsWordAt(text, (NSInteger)i - 1) && IsWordAt(text, i + 1)) )
			[out appendString:@"\\_"];
		else if ( c == '~' && (next == '~' || previous == '~') )
			[out appendString:@"\\~"];
		else if ( c == '<' && (next == 0 || MatchAt(@"<(?:https?|mailto):", text, i)) )
			[out appendString:@"\\<"];
		else
			[out appendString:Char(c)];
	}
	return out;
}

static NSString *EscapeLineStart(NSString *line)
{
	NSTextCheckingResult *match = Match(@"^(#{1,6}(?=[ \\t]|$)|>|[-+*](?=[ \\t])|\\d{1,9}(?=[.)][ \\t]))", line);
	if ( !match )
		return Test(@"^([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$", line) ? [@"\\" stringByAppendingString:line] : line;
	NSString *marker = Group(match, line, 0);
	unichar first = [marker characterAtIndex:0];
	if ( first >= '0' && first <= '9' )
		return [NSString stringWithFormat:@"%@\\%@", marker, [line substringFromIndex:[marker length]]];
	return [@"\\" stringByAppendingString:line];
}

static NSUInteger LongestRun(NSString *pattern, NSString *text)
{
	NSUInteger longest = 0;
	for ( NSTextCheckingResult *match in [Regex(pattern) matchesInString:text options:0 range:NSMakeRange(0, [text length])] )
		longest = MAX(longest, [match range].length);
	return longest;
}

static NSString *CodeMarkdown(NSString *text)
{
	NSString *fence = Repeat(@"`", LongestRun(@"`+", text) + 1);
	NSString *pad = [text hasPrefix:@"`"] || [text hasSuffix:@"`"] ? @" " : @"";
	return [NSString stringWithFormat:@"%@%@%@%@%@", fence, pad, text, pad, fence];
}

static NSString *StyleKey(FRSpan *span)
{
	return [NSString stringWithFormat:@"%@%@%@", [[span->style objectForKey:@"bold"] boolValue] ? @"b" : @"",
			[[span->style objectForKey:@"italic"] boolValue] ? @"i" : @"", [[span->style objectForKey:@"strike"] boolValue] ? @"s" : @""];
}

static NSString *StyledMarkdown(NSArray *spans)
{
	NSMutableString *out = [NSMutableString string];
	NSUInteger index = 0;
	while ( index < [spans count] ) {
		FRSpan *first = [spans objectAtIndex:index];
		NSString *key = StyleKey(first);
		NSMutableString *inner = [NSMutableString string];
		NSUInteger end = index;
		while ( end < [spans count] && [StyleKey([spans objectAtIndex:end]) isEqualToString:key] ) {
			FRSpan *span = [spans objectAtIndex:end];
			[inner appendString:[[span->style objectForKey:@"code"] boolValue] ? CodeMarkdown(span->text) : EscapeText(span->text)];
			end++;
		}
		NSString *trimmed = Trim(inner);
		if ( [trimmed length] && [key length] ) {
			NSString *leading = [inner substringToIndex:[inner length] - [TrimStart(inner) length]];
			NSString *trailing = [inner substringFromIndex:[TrimEnd(inner) length]];
			NSString *wrapped = trimmed;
			if ( [[first->style objectForKey:@"strike"] boolValue] )
				wrapped = [NSString stringWithFormat:@"~~%@~~", wrapped];
			if ( [[first->style objectForKey:@"italic"] boolValue] )
				wrapped = [NSString stringWithFormat:@"_%@_", wrapped];
			if ( [[first->style objectForKey:@"bold"] boolValue] )
				wrapped = [NSString stringWithFormat:@"**%@**", wrapped];
			[out appendFormat:@"%@%@%@", leading, wrapped, trailing];
		} else
			[out appendString:inner];
		index = end;
	}
	return out;
}

static NSString *InlineMarkdown(NSArray *spans)
{
	NSMutableString *out = [NSMutableString string];
	NSUInteger index = 0;
	while ( index < [spans count] ) {
		NSString *link = [((FRSpan *)[spans objectAtIndex:index])->style objectForKey:@"link"];
		NSUInteger end = index;
		while ( end < [spans count] ) {
			NSString *other = [((FRSpan *)[spans objectAtIndex:end])->style objectForKey:@"link"];
			if ( !(link == other || [link isEqualToString:other]) )
				break;
			end++;
		}
		NSArray *run = [spans subarrayWithRange:NSMakeRange(index, end - index)];
		if ( !link )
			[out appendString:StyledMarkdown(run)];
		else {
			NSString *label = SpansText(run);
			BOOL plainRun = YES;
			for ( FRSpan *span in run )
				plainRun &= [StyleKey(span) length] == 0 && ![[span->style objectForKey:@"code"] boolValue];
			if ( [label isEqualToString:link] && plainRun && Test(@"^https?://\\S+$", link) )
				[out appendString:link];
			else {
				NSString *destination = Test(@"[\\s()<>]", link) ? [NSString stringWithFormat:@"<%@>", link] : link;
				NSMutableArray *unlinked = [NSMutableArray array];
				for ( FRSpan *span in run ) {
					NSMutableDictionary *style = [NSMutableDictionary dictionaryWithDictionary:span->style];
					[style removeObjectForKey:@"link"];
					[unlinked addObject:[FRSpan text:span->text style:style bare:span->bare]];
				}
				[out appendFormat:@"[%@](%@)", StyledMarkdown(unlinked), destination];
			}
		}
		index = end;
	}
	return out;
}

static NSString *LinesToMarkdown(NSArray *lines)
{
	NSMutableArray *chunks = [NSMutableArray array];
	NSUInteger index = 0;
	while ( index < [lines count] ) {
		FRLine *line = [lines objectAtIndex:index];
		NSDictionary *format = line->format;
		if ( [format objectForKey:@"list"] ) {
			NSMutableArray *items = [NSMutableArray array];
			NSMutableArray *counters = [NSMutableArray array];
			for ( ; index < [lines count] && [((FRLine *)[lines objectAtIndex:index])->format objectForKey:@"list"]; index++ ) {
				FRLine *item = [lines objectAtIndex:index];
				NSInteger depth = [[item->format objectForKey:@"indent"] integerValue];
				if ( (NSInteger)[counters count] > depth + 1 )
					[counters removeObjectsInRange:NSMakeRange(depth + 1, [counters count] - depth - 1)];
				while ( (NSInteger)[counters count] <= depth )
					[counters addObject:[NSNull null]];
				id last = [counters objectAtIndex:depth];
				BOOL ordered = [[item->format objectForKey:@"list"] isEqual:@"ordered"];
				NSInteger number = ordered ? (last == [NSNull null] ? 0 : [last integerValue]) + 1 : 0;
				[counters replaceObjectAtIndex:depth withObject:ordered ? (id)@(number) : (id)[NSNull null]];
				NSString *content = Trim(InlineMarkdown(item->spans));
				if ( ![content length] )
					continue;
				[items addObject:[NSString stringWithFormat:@"%@%@ %@", Repeat(@"    ", depth),
								  ordered ? [NSString stringWithFormat:@"%ld.", (long)number] : @"-", content]];
			}
			if ( [items count] )
				[chunks addObject:[items componentsJoinedByString:@"\n"]];
		} else if ( [format objectForKey:@"code-block"] ) {
			NSMutableArray *body = [NSMutableArray array];
			for ( ; index < [lines count] && [((FRLine *)[lines objectAtIndex:index])->format objectForKey:@"code-block"]; index++ )
				[body addObject:SpansText(((FRLine *)[lines objectAtIndex:index])->spans)];
			NSUInteger longest = 2;
			for ( NSString *row in body )
				longest = MAX(longest, LongestRun(@"^`{3,}", row));
			NSString *fence = Repeat(@"`", longest + 1);
			[chunks addObject:[NSString stringWithFormat:@"%@\n%@\n%@", fence, [body componentsJoinedByString:@"\n"], fence]];
		} else if ( [format objectForKey:@"blockquote"] ) {
			NSMutableArray *quoted = [NSMutableArray array];
			for ( ; index < [lines count] && [((FRLine *)[lines objectAtIndex:index])->format objectForKey:@"blockquote"]; index++ ) {
				NSString *content = Trim(InlineMarkdown(((FRLine *)[lines objectAtIndex:index])->spans));
				[quoted addObject:[content length] ? [@"> " stringByAppendingString:content] : @">"];
			}
			[chunks addObject:[quoted componentsJoinedByString:@"\n"]];
		} else if ( [format objectForKey:@"header"] ) {
			NSString *content = Trim(InlineMarkdown(line->spans));
			if ( [content length] )
				[chunks addObject:[NSString stringWithFormat:@"%@ %@", Repeat(@"#", [[format objectForKey:@"header"] integerValue]), content]];
			index++;
		} else {
			NSMutableArray *paragraph = [NSMutableArray array];
			for ( ; index < [lines count]; index++ ) {
				FRLine *next = [lines objectAtIndex:index];
				if ( [next->format count] )
					break;
				NSString *content = Trim(InlineMarkdown(next->spans));
				if ( ![content length] ) {
					index++;
					break;
				}
				[paragraph addObject:EscapeLineStart(content)];
			}
			if ( [paragraph count] )
				[chunks addObject:[paragraph componentsJoinedByString:@"\\\n"]];
		}
	}
	return [chunks componentsJoinedByString:@"\n\n"];
}

NSString *FlycutSlackDeltaToMarkdown(NSDictionary *delta)
{
	id ops = [delta objectForKey:@"ops"];
	return [ops isKindOfClass:[NSArray class]] ? LinesToMarkdown(DeltaLines(ops)) : @"";
}

static NSString *DecodeEntities(NSString *text)
{
	static NSDictionary *named = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		named = [@{@"amp": @"&", @"apos": @"'", @"gt": @">", @"lt": @"<", @"nbsp": @" ", @"quot": @"\""} retain];
	});
	NSMutableString *out = [NSMutableString string];
	NSUInteger position = 0;
	for ( NSTextCheckingResult *match in [Regex(@"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") matchesInString:text options:0 range:NSMakeRange(0, [text length])] ) {
		[out appendString:[text substringWithRange:NSMakeRange(position, [match range].location - position)]];
		NSString *name = Group(match, text, 1);
		NSString *replacement = nil;
		if ( [name hasPrefix:@"#x"] || [name hasPrefix:@"#X"] || [name hasPrefix:@"#"] ) {
			BOOL hex = [name length] > 1 && ([name characterAtIndex:1] == 'x' || [name characterAtIndex:1] == 'X');
			unsigned long long code = strtoull([[name substringFromIndex:hex ? 2 : 1] UTF8String], NULL, hex ? 16 : 10);
			if ( !hex && code == 160 )
				replacement = @" ";
			else if ( code <= 0x10FFFF ) {
				UTF32Char scalar = (UTF32Char)code;
				replacement = [[[NSString alloc] initWithBytes:&scalar length:4 encoding:NSUTF32LittleEndianStringEncoding] autorelease];
			}
		} else
			replacement = [named objectForKey:[name lowercaseString]];
		[out appendString:replacement ?: Group(match, text, 0)];
		position = NSMaxRange([match range]);
	}
	[out appendString:[text substringFromIndex:position]];
	return out;
}

static NSString *const kToken = @"<!--[\\s\\S]*?-->|<(/?)([a-zA-Z][a-zA-Z0-9-]*)((?:\\s+[^\\s=/>]+(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+))?)*)\\s*/?>|[^<]+|<";
static NSString *const kAttribute = @"([^\\s=/>]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+)))?";

static NSDictionary *AttributesOf(NSString *source)
{
	NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
	for ( NSTextCheckingResult *match in [Regex(kAttribute) matchesInString:source options:0 range:NSMakeRange(0, [source length])] ) {
		NSString *value = Group(match, source, 2) ?: Group(match, source, 3) ?: Group(match, source, 4) ?: @"";
		[attributes setObject:DecodeEntities(value) forKey:[Group(match, source, 1) lowercaseString]];
	}
	return attributes;
}

static NSDictionary *TagStyle(NSString *tag, NSDictionary *attributes)
{
	NSString *css = Replace(@"\\s+", [[attributes objectForKey:@"style"] ?: @"" lowercaseString], @"");
	NSString *stringify = [attributes objectForKey:@"data-stringify-type"];
	NSMutableDictionary *style = [NSMutableDictionary dictionary];
	if ( (([tag isEqualToString:@"b"] || [tag isEqualToString:@"strong"]) && !Test(@"font-weight:(normal|400)", css))
		|| [stringify isEqualToString:@"bold"] || Test(@"font-weight:(bold|[6-9]00)", css) )
		[style setObject:@YES forKey:@"bold"];
	if ( [tag isEqualToString:@"i"] || [tag isEqualToString:@"em"] || [stringify isEqualToString:@"italic"] || [css rangeOfString:@"font-style:italic"].location != NSNotFound )
		[style setObject:@YES forKey:@"italic"];
	if ( [tag isEqualToString:@"s"] || [tag isEqualToString:@"del"] || [tag isEqualToString:@"strike"] || [stringify isEqualToString:@"strike"]
		|| [css rangeOfString:@"line-through"].location != NSNotFound )
		[style setObject:@YES forKey:@"strike"];
	if ( [tag isEqualToString:@"code"] || [stringify isEqualToString:@"code"] )
		[style setObject:@YES forKey:@"code"];
	NSString *href = [attributes objectForKey:@"data-stringify-link"] ?: [attributes objectForKey:@"href"];
	if ( [tag isEqualToString:@"a"] && [href length] && ![href hasPrefix:@"#"] && ![href hasPrefix:@"javascript:"] )
		[style setObject:href forKey:@"link"];
	return [style count] ? style : nil;
}

static NSArray *HTMLLines(NSString *html)
{
	static NSSet *skipped, *blocks, *gapAfter;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		skipped = [[NSSet alloc] initWithArray:@[@"script", @"style", @"head", @"title", @"template", @"noscript"]];
		blocks = [[NSSet alloc] initWithArray:@[@"p", @"div", @"section", @"article", @"header", @"footer", @"main", @"aside", @"nav", @"figure", @"ul", @"ol", @"li",
												@"pre", @"blockquote", @"table", @"thead", @"tbody", @"tr", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"dl", @"dt", @"dd"]];
		gapAfter = [[NSSet alloc] initWithArray:@[@"p", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"ul", @"ol", @"pre", @"blockquote", @"table"]];
	});
	NSMutableArray *lines = [NSMutableArray array];
	NSMutableArray *styles = [NSMutableArray array];		// {tag, style}
	NSMutableArray *lists = [NSMutableArray array];		// {kind, indent}
	__block NSMutableArray *spans = [NSMutableArray array];
	NSString *skip = nil;
	__block NSInteger pre = 0, quote = 0, heading = 0;
	__block NSDictionary *item = nil;

	NSDictionary *(^current)(void) = ^NSDictionary *{
		NSMutableDictionary *merged = [NSMutableDictionary dictionary];
		for ( NSDictionary *entry in styles )
			[merged addEntriesFromDictionary:[entry objectForKey:@"style"]];
		if ( pre > 0 )
			[merged removeObjectForKey:@"code"];
		return InlineStyle(merged);
	};
	NSDictionary *(^format)(void) = ^NSDictionary *{
		if ( pre > 0 )
			return @{@"code-block": @YES};
		if ( item )
			return item;
		if ( quote > 0 )
			return @{@"blockquote": @YES};
		if ( heading > 0 )
			return @{@"header": @(heading)};
		return @{};
	};
	void (^gap)(void) = ^{
		if ( [lines count] && [((FRLine *)[lines lastObject])->spans count] )
			[lines addObject:[FRLine spans:@[] format:@{}]];
	};
	void (^flush)(BOOL) = ^(BOOL force) {
		if ( pre > 0 ) {
			NSString *text = SpansText(spans);
			if ( [text hasSuffix:@"\n"] )
				text = [text substringToIndex:[text length] - 1];
			if ( [text length] || force )
				for ( NSString *row in [text componentsSeparatedByString:@"\n"] )
					[lines addObject:[FRLine spans:[row length] ? @[[FRSpan text:row style:@{} bare:NO]] : @[] format:@{@"code-block": @YES}]];
			spans = [NSMutableArray array];
			return;
		}
		FRSpan *first = [spans firstObject];
		if ( first )
			[first->text setString:Replace(@"^ +", first->text, @"")];
		FRSpan *last = [spans lastObject];
		if ( last )
			[last->text setString:Replace(@" +$", last->text, @"")];
		[spans filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(FRSpan *span, NSDictionary *bindings) { return [span->text length] > 0; }]];
		if ( [spans count] || force )
			[lines addObject:[FRLine spans:spans format:format()]];
		spans = [NSMutableArray array];
	};

	for ( NSTextCheckingResult *match in [Regex(kToken) matchesInString:html options:0 range:NSMakeRange(0, [html length])] ) {
		NSString *token = Group(match, html, 0);
		if ( [token hasPrefix:@"<!--"] )
			continue;
		NSString *tag = [Group(match, html, 2) lowercaseString];
		BOOL closing = [Group(match, html, 1) isEqualToString:@"/"];
		if ( skip ) {
			if ( [tag isEqualToString:skip] && closing )
				skip = nil;
			continue;
		}
		if ( !tag ) {
			NSString *text = DecodeEntities(token);
			if ( pre == 0 ) {
				text = Replace(@"[ \\t\\r\\n\\f]+", text, @" ");
				if ( [spans count] == 0 || [((FRSpan *)[spans lastObject])->text hasSuffix:@" "] )
					text = Replace(@"^ ", text, @"");
			}
			AppendSpan(spans, text, current());
			continue;
		}
		NSDictionary *attributes = closing ? @{} : AttributesOf(Group(match, html, 3) ?: @"");
		if ( !closing && [skipped containsObject:tag] ) {
			skip = tag;
			continue;
		}
		if ( [tag isEqualToString:@"br"] ) {
			flush(YES);
			continue;
		}
		if ( [tag isEqualToString:@"img"] ) {
			AppendSpan(spans, [attributes objectForKey:@"data-stringify-emoji"] ?: [attributes objectForKey:@"alt"] ?: @"", current());
			continue;
		}
		if ( [tag isEqualToString:@"hr"] || [[attributes objectForKey:@"data-stringify-type"] isEqualToString:@"paragraph-break"] ) {
			flush(NO);
			gap();
			continue;
		}
		if ( [tag isEqualToString:@"td"] || [tag isEqualToString:@"th"] ) {
			if ( !closing && [spans count] )
				AppendSpan(spans, @" | ", current());
			continue;
		}
		if ( [blocks containsObject:tag] ) {
			flush(NO);
			if ( [tag isEqualToString:@"ul"] || [tag isEqualToString:@"ol"] ) {
				if ( closing ) {
					if ( [lists count] )
						[lists removeLastObject];
				} else
					[lists addObject:@{@"kind": [tag isEqualToString:@"ol"] ? @"ordered" : @"bullet",
									   @"indent": @(MAX(0, [[attributes objectForKey:@"data-indent"] integerValue]))}];
				item = nil;
			} else if ( [tag isEqualToString:@"li"] ) {
				NSDictionary *list = [lists lastObject];
				if ( closing || !list )
					item = nil;
				else {
					NSInteger indent = MAX((NSInteger)[lists count] - 1, [[list objectForKey:@"indent"] integerValue]);
					item = indent > 0 ? @{@"indent": @(indent), @"list": [list objectForKey:@"kind"]} : @{@"list": [list objectForKey:@"kind"]};
				}
			} else if ( [tag isEqualToString:@"pre"] )
				pre = MAX(0, pre + (closing ? -1 : 1));
			else if ( [tag isEqualToString:@"blockquote"] )
				quote = MAX(0, quote + (closing ? -1 : 1));
			else if ( Test(@"^h[1-6]$", tag) )
				heading = closing ? 0 : [[tag substringFromIndex:1] integerValue];
			if ( closing && [gapAfter containsObject:tag] && [lists count] == 0 )
				gap();
			continue;
		}
		if ( closing ) {
			for ( NSInteger i = (NSInteger)[styles count] - 1; i >= 0; i-- )
				if ( [[[styles objectAtIndex:i] objectForKey:@"tag"] isEqualToString:tag] ) {
					[styles removeObjectAtIndex:i];
					break;
				}
		} else {
			NSDictionary *style = TagStyle(tag, attributes);
			if ( style )
				[styles addObject:@{@"tag": tag, @"style": style}];
		}
	}
	flush(NO);
	while ( [lines count] && [((FRLine *)[lines lastObject])->spans count] == 0 && ![((FRLine *)[lines lastObject])->format objectForKey:@"code-block"] )
		[lines removeLastObject];
	return lines;
}

NSString *FlycutHTMLToMarkdown(NSString *html)
{
	return LinesToMarkdown(HTMLLines(html));
}

BOOL FlycutIsSlackHTML(NSString *html)
{
	return Test(@"\\sdata-stringify-type=|class=\"[^\"]*\\bp-rich_text_section\\b", html);
}

#pragma mark detect.ts

static NSString *const kDetectItem = @"^\\s*(?:\\d{1,9}[.)]|[-*+])\\s+\\S";
static NSString *const kDetectHeading = @"^ {0,3}#{1,6}[ \\t]+\\p{L}";

BOOL FlycutLooksLikeMarkdown(NSString *text)
{
	static NSString *codeLine = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		codeLine = [[@[@"[;{]\\s*$",
					   @"^\\s*[})\\]][;,)]*\\s*$",
					   @"^\\s*(?:import|export|from|const|let|var|function|def|class|return|if|for|while|public|private|#include|package|use)\\b.*[^.!?]$",
					   @"^\\s*[$%>] \\S",
					   @"^#!",
					   @"=>|->|::|&&|\\|\\||==",
					   @"^\\s*[A-Za-z0-9_.-]+\\s*=\\s*\\S",
					   @"^\\s*</?[a-zA-Z][^>]*>\\s*$"] componentsJoinedByString:@"|"] retain];
	});
	if ( [text length] > 256 * 1024 || Test(@"(?m)^(?:diff --git |@@ -[0-9]|\\+\\+\\+ |--- a/|index [0-9a-f]{7,})", text) )
		return NO;
	NSArray *lines = SplitLines(text);
	NSMutableArray *prose = [NSMutableArray array];
	BOOL fenced = NO;
	NSInteger fences = 0, items = 0, headings = 0, quotes = 0, tables = 0, nonBlank = 0;
	for ( NSUInteger i = 0; i < [lines count]; i++ ) {
		NSString *line = [lines objectAtIndex:i];
		if ( !IsBlank(line) )
			nonBlank++;
		if ( Test(@"^ {0,3}(?:`{3,}|~{3,})", line) ) {
			if ( fenced )
				fences++;
			fenced = !fenced;
			continue;
		}
		if ( fenced || IsBlank(line) )
			continue;
		[prose addObject:line];
		if ( Test(kDetectItem, line) )
			items++;
		else if ( Test(kDetectHeading, line) )
			headings++;
		else if ( Test(@"^ {0,3}>[ \\t]?\\S", line) )
			quotes++;
		else if ( [line rangeOfString:@"|"].location != NSNotFound && Test(kTableDelimiter, i + 1 < [lines count] ? [lines objectAtIndex:i + 1] : @"") )
			tables++;
	}
	if ( nonBlank < 2 || [prose count] == 0 )
		return NO;
	NSInteger codeLike = 0, timestamps = 0;
	BOOL sentence = NO;
	for ( NSString *line in prose ) {
		if ( !Test(kDetectItem, line) && !Test(kDetectHeading, line) && Test(codeLine, line) )
			codeLike++;
		if ( Test(@"^\\s*\\[?(?:[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}|[0-9]{2}:[0-9]{2}:[0-9]{2}|[A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2})", line) )
			timestamps++;
		sentence |= Test(@"^\\s*(?:\\S+\\s+){4,}\\S*[.!?:]\\s*$", line);
	}
	if ( codeLike * 3 >= (NSInteger)[prose count] || timestamps * 2 >= (NSInteger)[prose count] )
		return NO;
	NSString *body = [prose componentsJoinedByString:@"\n"];
	return items >= 2 || (headings > 0 && sentence) || fences > 0 || quotes > 0 || tables > 0
		|| Test(@"\\[[^\\]\\n]+\\]\\((?:<[^>\\n]+>|[^)\\s]+)\\)", body)
		|| Test(@"(?:\\*\\*|__)(?=\\S)[^\\n]*?\\S(?:\\*\\*|__)|~~(?=\\S)[^\\n]*?\\S~~", body);
}

#pragma mark chromium-custom-data.ts

static void AppendUInt32(NSMutableData *data, uint32_t value)
{
	uint32_t little = CFSwapInt32HostToLittle(value);
	[data appendBytes:&little length:4];
}

NSData *FlycutChromiumWebCustomData(NSArray *pairs)
{
	NSMutableData *body = [NSMutableData data];
	AppendUInt32(body, (uint32_t)[pairs count]);
	static const char zeros[4] = {0, 0, 0, 0};
	for ( NSArray *pair in pairs )
		for ( NSString *string in pair ) {
			NSData *units = [string dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
			AppendUInt32(body, (uint32_t)([units length] / 2));
			[body appendData:units];
			[body appendBytes:zeros length:(4 - [units length] % 4) % 4];
		}
	NSMutableData *data = [NSMutableData data];
	AppendUInt32(data, (uint32_t)[body length]);
	[data appendData:body];
	return data;
}

NSArray *FlycutParseChromiumWebCustomData(NSData *data)
{
	const uint8_t *bytes = [data bytes];
	NSUInteger length = [data length];
	uint32_t (^read32)(NSUInteger) = ^uint32_t(NSUInteger at) {
		uint32_t value;
		memcpy(&value, bytes + at, 4);
		return CFSwapInt32LittleToHost(value);
	};
	if ( length < 8 || read32(0) > length - 4 )
		return @[];
	NSUInteger end = 4 + read32(0), offset = 8;
	NSMutableArray *pairs = [NSMutableArray array];
	uint32_t count = read32(4);
	for ( uint32_t index = 0; index < count; index++ ) {
		NSString *strings[2];
		for ( int part = 0; part < 2; part++ ) {
			if ( offset + 4 > end )
				return @[];
			NSUInteger units = read32(offset), start = offset + 4;
			if ( units > (end - start) / 2 )
				return @[];
			offset = start + units * 2 + (4 - (units * 2) % 4) % 4;
			strings[part] = [[[NSString alloc] initWithBytes:bytes + start length:units * 2 encoding:NSUTF16LittleEndianStringEncoding] autorelease] ?: @"";
		}
		[pairs addObject:@[strings[0], strings[1]]];
	}
	return pairs;
}

#pragma mark enrich.ts

@implementation FlycutRichEnrichment

@synthesize kind, markdown, text, html, webCustomData;

-(instancetype) initWithKind:(NSString *)aKind markdown:(NSString *)aMarkdown text:(NSString *)aText html:(NSString *)anHTML webCustomData:(NSData *)data
{
	if ( (self = [super init]) ) {
		kind = [aKind copy];
		markdown = [aMarkdown copy];
		text = [aText copy];
		html = [anHTML copy];
		webCustomData = [data copy];
	}
	return self;
}

-(void) dealloc
{
	[kind release];
	[markdown release];
	[text release];
	[html release];
	[webCustomData release];
	[super dealloc];
}

@end

static NSString *PairValue(NSArray *pairs, NSString *key)
{
	for ( NSArray *pair in pairs )
		if ( [[pair objectAtIndex:0] isEqualToString:key] )
			return [pair objectAtIndex:1];
	return nil;
}

// The same bytes as JSON.stringify: sorted keys match the TypeScript key order, and slashes are left
// unescaped by hand because NSJSONWritingWithoutEscapingSlashes needs macOS 10.15.
static NSString *JSONString(id object)
{
	NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
	NSString *json = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : @"";
	return [json stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
}

static NSString *TextyMarkdown(NSString *texty)
{
	id delta = [NSJSONSerialization JSONObjectWithData:[texty dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:NULL];
	return [delta isKindOfClass:[NSDictionary class]] ? FlycutSlackDeltaToMarkdown(delta) : @"";
}

FlycutRichEnrichment *FlycutEnrichFlavors(NSString *text, NSString *html, NSString *markdown, NSData *webCustomData)
{
	NSArray *pairs = webCustomData ? FlycutParseChromiumWebCustomData(webCustomData) : @[];
	if ( PairValue(pairs, FlycutRichSourceMarkerType) )
		return nil;
	NSString *texty = PairValue(pairs, kSlackTextyType);
	BOOL slackHTML = html && FlycutIsSlackHTML(html);
	NSString *fromTexty = texty ? TextyMarkdown(texty) : @"";
	NSString *slackMarkdown = [fromTexty length] ? fromTexty : (slackHTML ? FlycutHTMLToMarkdown(html) : @"");
	if ( [slackMarkdown length] ) {
		NSMutableArray *marked = [NSMutableArray arrayWithArray:pairs];
		[marked addObject:@[FlycutRichSourceMarkerType, @"slack"]];
		return [[[FlycutRichEnrichment alloc] initWithKind:@"slack" markdown:slackMarkdown text:FlycutMarkdownToPlain(slackMarkdown, YES)
													  html:[fromTexty length] ? FlycutMarkdownToHTML(slackMarkdown) : html
											 webCustomData:FlycutChromiumWebCustomData(marked)] autorelease];
	}
	NSString *source = markdown ?: text;
	if ( ![source length] || (!markdown && !FlycutLooksLikeMarkdown(source)) )
		return nil;
	NSMutableArray *newPairs = [NSMutableArray arrayWithObjects:@[kPlainPairType, text ?: source], @[kSlackTextyType, JSONString(FlycutMarkdownToSlackDelta(source))], nil];
	for ( NSArray *pair in pairs )
		if ( ![[pair objectAtIndex:0] isEqualToString:kPlainPairType] && ![[pair objectAtIndex:0] isEqualToString:kSlackTextyType] )
			[newPairs addObject:pair];
	[newPairs addObject:@[FlycutRichSourceMarkerType, @"markdown"]];
	return [[[FlycutRichEnrichment alloc] initWithKind:@"markdown" markdown:source text:text ?: source html:FlycutMarkdownToHTML(source)
										 webCustomData:FlycutChromiumWebCustomData(newPairs)] autorelease];
}

BOOL FlycutWriteRichMarkdown(NSString *text, NSPasteboard *pasteboard)
{
	FlycutRichEnrichment *enrichment = FlycutEnrichFlavors(text, nil, nil, nil);
	if ( ![[enrichment kind] isEqualToString:@"markdown"] )
		return NO;
	NSPasteboardItem *item = [[[NSPasteboardItem alloc] init] autorelease];
	[item setString:[enrichment text] forType:NSPasteboardTypeString];
	[item setString:[enrichment html] forType:NSPasteboardTypeHTML];
	[item setData:[enrichment webCustomData] forType:FlycutWebCustomDataType];
	[pasteboard clearContents];
	return [pasteboard writeObjects:@[item]];
}
