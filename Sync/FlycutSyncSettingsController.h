#import <Cocoa/Cocoa.h>
#import "FlycutSync.h"

@interface FlycutSyncSettingsController : NSWindowController
- (instancetype)initWithSyncController:(FlycutSyncController *)controller;
+ (void)restoreSyncForController:(FlycutSyncController *)controller;
@end
