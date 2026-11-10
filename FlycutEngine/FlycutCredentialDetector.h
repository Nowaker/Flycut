//
//  FlycutCredentialDetector.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutCredentialDetector tells whether a clipping holds a credential, using the gitleaks-style rules in
// credential-rules.json (shared with the Linux bridge) plus a check for a lone random-looking word, which is
// what a copied password or token looks like. Credentials are shown in red and encrypted in sync logs.

#import <Foundation/Foundation.h>
#import "FlycutClipping.h"

@interface FlycutCredentialDetector : NSObject

// Rules from credential-rules.json in the main bundle.
+(instancetype) sharedDetector;

// Returns nil if the rules can't be read or don't compile.
-(instancetype) initWithRulesData:(NSData *)data;

// The id of the first rule that matches, or nil.
-(NSString *) credentialRuleInText:(NSString *)text;
-(BOOL) isCredential:(NSString *)text;

// Remembered on the clipping, so lists can ask for every row they draw.
-(BOOL) isCredentialClipping:(FlycutClipping *)clipping;

@property (nonatomic, readonly) int rulesVersion;

@end
