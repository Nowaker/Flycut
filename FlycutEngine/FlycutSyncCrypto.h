//
//  FlycutSyncCrypto.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutSyncCrypto seals credential clippings in sync logs, so reading the logs on the server or in a sync
// folder shows ciphertext for them, while every client holding the server token can still read them.
//
// Sealed text is "v1:" + base64(nonce[16] || ciphertext || tag[32]):
//   encKey || macKey = HKDF-SHA256(ikm = token, salt = "flycut-sync", info = "clipping contents v1", 64 bytes)
//   ciphertext = AES-256-CTR(encKey, initial counter block = nonce, UTF-8 plaintext)
//   tag = HMAC-SHA256(macKey, "flycut-v1" || nonce || ciphertext)
// Sealed data (a credential clipping's pasteboard data, stored as a blob) is the same nonce || ciphertext || tag,
// unencoded, with nonce = HMAC-SHA256(macKey, "flycut-blob-v1" || data)[0..15]: equal data seals the same, so a
// blob a clipping is sealed into keeps its address however often the clipping is written out.
// linux-bridge/flycut-copyq-bridge.py and sync-server (reveal) implement the same format.

#import <Foundation/Foundation.h>

@interface FlycutSyncCrypto : NSObject

-(instancetype) initWithToken:(NSString *)token;

-(NSString *) seal:(NSString *)plaintext;
// nil when the text was sealed with another key or was altered.
-(NSString *) open:(NSString *)sealed;

-(NSData *) sealData:(NSData *)data;
-(NSData *) openData:(NSData *)sealed;

@end
