//
//  FlycutClipping.h
//  Flycut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(int, FlycutCredentialState) {
	FlycutCredentialUnknown = 0,
	FlycutCredentialNo,
	FlycutCredentialYes,
};

@interface FlycutClipping : NSObject {
// What must a clipping hold?
// The text
    NSString * clipContents;
// The text type
    NSString * clipType;
// The display length
    int clipDisplayLength;
// The display string
    NSString * clipDisplayString;
// Does it have a name?
    BOOL clipHasName;
// The app name it came from
    NSString * appLocalizedName;
// The the bunle URL of the app it came from
    NSString * appBundleURL;
// The time
    NSInteger clipTimestamp;
// Stable identity for persistence and sync; contents alone are not unique when duplicates are kept
    NSString * clipId;
// Sort key within a persisted list, higher is more recent
    double clipRank;
// Whether the contents look like a credential, worked out on first use (FlycutCredentialDetector)
    FlycutCredentialState credentialState;
    NSArray * clipItems;
    BOOL clipContentsDescribeItems;
}

// The pasteboard items the clipping was copied with, each an array of representations
// {"t": pasteboard type, "b": FlycutBlobStore address, "n": byte count}. nil when the copy was
// plain text only, so the contents are all there is.
@property (nonatomic, copy) NSArray *items;
// The contents describe the items ("[image: PNG, 1920×1080, 1.2 MB]") because they have no text.
@property (nonatomic, assign) BOOL contentsDescribeItems;

// Identifies the items' data: equal for two copies of the same data, empty without items.
-(NSString *) itemsFingerprint;
// What duplicate removal compares: the text, or for a described clipping, its data.
-(NSString *) dedupeKey;
-(NSArray *) blobAddresses;

-(id) initWithContents:(NSString *)contents withType:(NSString *)type withDisplayLength:(int)displayLength withAppLocalizedName:(NSString *)localizedName withAppBundleURL:(NSString *)bundleURL withTimestamp:(NSInteger)timestamp;
/* -(id) initWithCoder:(NSCoder *)coder;
-(void) decodeWithCoder:(NSCoder *)coder; */
-(NSString *) description;

// set values
-(void) setContents:(NSString *)newContents setDisplayLength:(int)newDisplayLength;
-(void) setContents:(NSString *)newContents;
-(void) setType:(NSString *)newType;
-(void) setDisplayLength:(int)newDisplayLength;
-(void) setHasName:(BOOL)newHasName;
-(void) setClipId:(NSString *)newClipId;
-(void) setRank:(double)newRank;
-(void) setCredentialState:(FlycutCredentialState)newState;

// Retrieve values
-(FlycutClipping *) clipping;
-(NSString *) contents;
-(int) displayLength;
-(NSString *) displayString;
-(NSString *) type;
-(NSString *) appLocalizedName;
-(NSString *) appBundleURL;
-(NSInteger) timestamp;
-(BOOL) hasName;
-(NSString *) clipId;
-(double) rank;
-(FlycutCredentialState) credentialState;

// Additional functions
-(void) resetDisplayString;

@end
