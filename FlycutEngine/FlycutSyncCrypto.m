//
//  FlycutSyncCrypto.m
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import "FlycutSyncCrypto.h"
#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>

static NSString *const kPrefix = @"v1:";
static const char kTagLabel[] = "flycut-v1";
static const char kBlobNonceLabel[] = "flycut-blob-v1";
enum { kNonceLength = 16, kTagLength = CC_SHA256_DIGEST_LENGTH, kKeyLength = 32 };

static NSData *HMAC(NSData *key, NSData *message)
{
	unsigned char digest[CC_SHA256_DIGEST_LENGTH];
	CCHmac(kCCHmacAlgSHA256, [key bytes], [key length], [message bytes], [message length], digest);
	return [NSData dataWithBytes:digest length:sizeof digest];
}

// RFC 5869 with SHA-256, for at most two output blocks.
static NSData *HKDF(NSData *ikm, NSData *salt, NSData *info, NSUInteger length)
{
	NSData *prk = HMAC(salt, ikm);
	NSMutableData *output = [NSMutableData data];
	NSData *previous = [NSData data];
	for ( unsigned char counter = 1; [output length] < length; counter++ ) {
		NSMutableData *block = [NSMutableData dataWithData:previous];
		[block appendData:info];
		[block appendBytes:&counter length:1];
		previous = HMAC(prk, block);
		[output appendData:previous];
	}
	return [output subdataWithRange:NSMakeRange(0, length)];
}

static NSData *AESCTR(NSData *key, NSData *nonce, NSData *input)
{
	CCCryptorRef cryptor = NULL;
	if ( CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding, [nonce bytes],
								 [key bytes], [key length], NULL, 0, 0, 0, &cryptor) != kCCSuccess )
		return nil;
	NSMutableData *output = [NSMutableData dataWithLength:[input length]];
	size_t moved = 0;
	CCCryptorStatus status = CCCryptorUpdate(cryptor, [input bytes], [input length], [output mutableBytes], [output length], &moved);
	CCCryptorRelease(cryptor);
	return status == kCCSuccess && moved == [input length] ? output : nil;
}

@implementation FlycutSyncCrypto {
	NSData *encryptionKey;
	NSData *macKey;
}

-(instancetype) initWithToken:(NSString *)token
{
	self = [super init];
	if ( !self )
		return nil;
	NSData *keys = HKDF([token dataUsingEncoding:NSUTF8StringEncoding], [@"flycut-sync" dataUsingEncoding:NSUTF8StringEncoding],
						[@"clipping contents v1" dataUsingEncoding:NSUTF8StringEncoding], 2 * kKeyLength);
	encryptionKey = [[keys subdataWithRange:NSMakeRange(0, kKeyLength)] retain];
	macKey = [[keys subdataWithRange:NSMakeRange(kKeyLength, kKeyLength)] retain];
	return self;
}

-(NSData *) tagForNonce:(NSData *)nonce ciphertext:(NSData *)ciphertext
{
	NSMutableData *message = [NSMutableData dataWithBytes:kTagLabel length:strlen(kTagLabel)];
	[message appendData:nonce];
	[message appendData:ciphertext];
	return HMAC(macKey, message);
}

-(NSData *) sealData:(NSData *)plaintext withNonce:(NSData *)nonce
{
	NSData *ciphertext = AESCTR(encryptionKey, nonce, plaintext);
	if ( !ciphertext )
		return nil;
	NSMutableData *sealed = [NSMutableData dataWithData:nonce];
	[sealed appendData:ciphertext];
	[sealed appendData:[self tagForNonce:nonce ciphertext:ciphertext]];
	return sealed;
}

-(NSString *) seal:(NSString *)plaintext
{
	NSMutableData *nonce = [NSMutableData dataWithLength:kNonceLength];
	if ( SecRandomCopyBytes(kSecRandomDefault, kNonceLength, [nonce mutableBytes]) != errSecSuccess )
		return nil;
	NSData *sealed = [self sealData:[plaintext dataUsingEncoding:NSUTF8StringEncoding] withNonce:nonce];
	return sealed ? [kPrefix stringByAppendingString:[sealed base64EncodedStringWithOptions:0]] : nil;
}

-(NSData *) sealData:(NSData *)data
{
	NSMutableData *message = [NSMutableData dataWithBytes:kBlobNonceLabel length:strlen(kBlobNonceLabel)];
	[message appendData:data];
	return [self sealData:data withNonce:[HMAC(macKey, message) subdataWithRange:NSMakeRange(0, kNonceLength)]];
}

-(NSString *) open:(NSString *)sealed
{
	if ( ![sealed isKindOfClass:[NSString class]] || ![sealed hasPrefix:kPrefix] )
		return nil;
	NSData *data = [[[NSData alloc] initWithBase64EncodedString:[sealed substringFromIndex:[kPrefix length]] options:0] autorelease];
	NSData *plaintext = [self openData:data];
	return plaintext ? [[[NSString alloc] initWithData:plaintext encoding:NSUTF8StringEncoding] autorelease] : nil;
}

-(NSData *) openData:(NSData *)data
{
	if ( [data length] < kNonceLength + kTagLength )
		return nil;
	NSData *nonce = [data subdataWithRange:NSMakeRange(0, kNonceLength)];
	NSData *ciphertext = [data subdataWithRange:NSMakeRange(kNonceLength, [data length] - kNonceLength - kTagLength)];
	NSData *tag = [data subdataWithRange:NSMakeRange([data length] - kTagLength, kTagLength)];

	NSData *expected = [self tagForNonce:nonce ciphertext:ciphertext];
	const unsigned char *a = [tag bytes], *b = [expected bytes];
	unsigned char difference = 0;
	for ( NSUInteger i = 0; i < kTagLength; i++ )
		difference |= a[i] ^ b[i];
	if ( difference )
		return nil;
	return AESCTR(encryptionKey, nonce, ciphertext);
}

-(void) dealloc
{
	[encryptionKey release];
	[macKey release];
	[super dealloc];
}

@end
