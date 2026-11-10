//
//  FlycutCredentialDetector.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutCredentialDetector.h"
#include <math.h>

static double ShannonEntropy(NSString *text)
{
	NSUInteger length = [text length];
	if ( length == 0 )
		return 0;
	NSMutableDictionary *counts = [NSMutableDictionary dictionary];
	for ( NSUInteger i = 0; i < length; i++ ) {
		NSNumber *key = @([text characterAtIndex:i]);
		[counts setObject:@([[counts objectForKey:key] unsignedIntegerValue] + 1) forKey:key];
	}
	double entropy = 0;
	for ( NSNumber *count in [counts allValues] ) {
		double p = [count doubleValue] / length;
		entropy -= p * log2(p);
	}
	return entropy;
}

@implementation FlycutCredentialDetector {
	NSArray *rules;	// {id, regex, keywords, entropy, allowSecret}
	NSArray *standaloneAllow;
	NSDictionary *standalone;
	NSUInteger scanLimit;
}

@synthesize rulesVersion;

+(instancetype) sharedDetector
{
	static FlycutCredentialDetector *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *path = [[NSBundle mainBundle] pathForResource:@"credential-rules" ofType:@"json"];
		shared = [[FlycutCredentialDetector alloc] initWithRulesData:[NSData dataWithContentsOfFile:path]];
		if ( !shared )
			NSLog(@"Flycut: cannot load credential rules from %@", path);
	});
	return shared;
}

static NSRegularExpression *Compile(NSString *pattern)
{
	NSError *error = nil;
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
	if ( !regex )
		NSLog(@"Flycut: bad credential rule %@: %@", pattern, error);
	return regex;
}

-(instancetype) initWithRulesData:(NSData *)data
{
	self = [super init];
	if ( !self )
		return nil;
	NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
	if ( ![config isKindOfClass:[NSDictionary class]] ) {
		[self release];
		return nil;
	}
	rulesVersion = [[config objectForKey:@"version"] intValue];
	scanLimit = [[config objectForKey:@"scanLimit"] unsignedIntegerValue] ?: 65536;

	NSMutableArray *compiled = [NSMutableArray array];
	for ( NSDictionary *rule in [config objectForKey:@"rules"] ) {
		NSRegularExpression *regex = Compile([rule objectForKey:@"regex"]);
		if ( !regex ) {
			[self release];
			return nil;
		}
		NSMutableArray *allowSecret = [NSMutableArray array];
		for ( NSString *pattern in [rule objectForKey:@"allowSecret"] ) {
			NSRegularExpression *allow = Compile(pattern);
			if ( !allow ) {
				[self release];
				return nil;
			}
			[allowSecret addObject:allow];
		}
		[compiled addObject:@{@"id": [rule objectForKey:@"id"], @"regex": regex,
							  @"keywords": [rule objectForKey:@"keywords"] ?: @[],
							  @"entropy": [rule objectForKey:@"entropy"] ?: @0, @"allowSecret": allowSecret}];
	}
	rules = [compiled copy];

	standalone = [[config objectForKey:@"standalone"] retain];
	NSMutableArray *allow = [NSMutableArray array];
	for ( NSString *pattern in [standalone objectForKey:@"allow"] ) {
		NSRegularExpression *regex = Compile(pattern);
		if ( !regex ) {
			[self release];
			return nil;
		}
		[allow addObject:regex];
	}
	standaloneAllow = [allow copy];
	return self;
}

-(BOOL) rule:(NSDictionary *)rule matchesText:(NSString *)text lowercase:(NSString *)lowercase
{
	NSArray *keywords = [rule objectForKey:@"keywords"];
	if ( [keywords count] ) {
		BOOL found = NO;
		for ( NSString *keyword in keywords )
			if ( [lowercase rangeOfString:keyword].location != NSNotFound ) {
				found = YES;
				break;
			}
		if ( !found )
			return NO;
	}
	double minimumEntropy = [[rule objectForKey:@"entropy"] doubleValue];
	NSRegularExpression *regex = [rule objectForKey:@"regex"];
	NSArray *allowSecret = [rule objectForKey:@"allowSecret"];
	for ( NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0, [text length])] ) {
		NSRange range = [match numberOfRanges] > 1 && [match rangeAtIndex:1].location != NSNotFound ? [match rangeAtIndex:1] : [match range];
		NSString *secret = [text substringWithRange:range];
		if ( minimumEntropy > 0 && ShannonEntropy(secret) < minimumEntropy )
			continue;
		BOOL allowed = NO;
		for ( NSRegularExpression *allow in allowSecret )
			if ( [allow firstMatchInString:secret options:0 range:NSMakeRange(0, [secret length])] )
				allowed = YES;
		if ( !allowed )
			return YES;
	}
	return NO;
}

-(BOOL) isLoneRandomWord:(NSString *)word
{
	NSUInteger length = [word length];
	if ( length < [[standalone objectForKey:@"minLength"] unsignedIntegerValue] || length > [[standalone objectForKey:@"maxLength"] unsignedIntegerValue] )
		return NO;
	if ( [word rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound )
		return NO;
	for ( NSRegularExpression *allow in standaloneAllow )
		if ( [allow firstMatchInString:word options:0 range:NSMakeRange(0, length)] )
			return NO;

	BOOL lower = NO, upper = NO, digit = NO, other = NO, tokenCharactersOnly = YES;
	NSUInteger digitRuns = 0, alphanumericRun = 0, longestAlphanumericRun = 0;
	BOOL inDigits = NO;
	for ( NSUInteger i = 0; i < length; i++ ) {
		unichar c = [word characterAtIndex:i];
		BOOL isDigit = c >= '0' && c <= '9';
		BOOL isAlphanumeric = isDigit || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
		alphanumericRun = isAlphanumeric ? alphanumericRun + 1 : 0;
		longestAlphanumericRun = MAX(longestAlphanumericRun, alphanumericRun);
		if ( c >= 'a' && c <= 'z' )
			lower = YES;
		else if ( c >= 'A' && c <= 'Z' )
			upper = YES;
		else if ( isDigit )
			digit = YES;
		else {
			other = YES;
			if ( c > 127 || !strchr("_+/=.-", (char)c) )
				tokenCharactersOnly = NO;
		}
		if ( isDigit && !inDigits )
			digitRuns++;
		inDigits = isDigit;
	}
	double entropy = ShannonEntropy(word);
	if ( lower && upper && digit && other && entropy >= [[standalone objectForKey:@"passwordEntropy"] doubleValue] )
		return YES;
	return tokenCharactersOnly && (lower || upper) && digit
		&& length >= [[standalone objectForKey:@"tokenMinLength"] unsignedIntegerValue]
		&& digitRuns >= [[standalone objectForKey:@"tokenDigitRuns"] unsignedIntegerValue]
		&& longestAlphanumericRun >= [[standalone objectForKey:@"tokenLongestRun"] unsignedIntegerValue]
		&& entropy >= [[standalone objectForKey:@"tokenEntropy"] doubleValue];
}

-(NSString *) credentialRuleInText:(NSString *)text
{
	if ( [text length] > scanLimit )
		text = [text substringToIndex:scanLimit];
	text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if ( [text length] == 0 )
		return nil;
	NSString *lowercase = [text lowercaseString];
	for ( NSDictionary *rule in rules )
		if ( [self rule:rule matchesText:text lowercase:lowercase] )
			return [rule objectForKey:@"id"];
	if ( standalone && [self isLoneRandomWord:text] )
		return @"standalone";
	return nil;
}

-(BOOL) isCredential:(NSString *)text
{
	return nil != [self credentialRuleInText:text];
}

-(BOOL) isCredentialClipping:(FlycutClipping *)clipping
{
	if ( [clipping credentialState] == FlycutCredentialUnknown )
		[clipping setCredentialState:[self isCredential:[clipping contents]] ? FlycutCredentialYes : FlycutCredentialNo];
	return [clipping credentialState] == FlycutCredentialYes;
}

-(void) dealloc
{
	[rules release];
	[standaloneAllow release];
	[standalone release];
	[super dealloc];
}

@end
