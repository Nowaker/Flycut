#import <Foundation/Foundation.h>
#import "../FlycutEngine/FlycutArchive.h"

#ifndef FLYCUT_CLOUDKIT
#define FLYCUT_CLOUDKIT 0
#endif
#ifndef FLYCUT_ICLOUD_CONTAINER
#define FLYCUT_ICLOUD_CONTAINER "iCloud.net.nowaker.flycut"
#endif

extern NSString * const FlycutSyncErrorDomain;
extern NSString * const FlycutSyncStatusDidChangeNotification;
typedef NS_ENUM(NSInteger, FlycutSyncErrorCode) {
    FlycutSyncTransientError = 1001
};
BOOL FlycutSyncValidateManifest(NSDictionary *manifest, NSError **error);
BOOL FlycutSyncIsSandboxed(void);
BOOL FlycutSyncPerformBatch(BOOL (^operation)(NSError **), NSError **error);
NSURL *FlycutSyncResolveFileURL(NSString *path, NSData *bookmark, BOOL readOnly,
                             NSData **refreshedBookmark, NSError **error);

// Transports are synchronous. The controller runs them on its utility queue.
@protocol FlycutSyncTransport <NSObject>
@property(nonatomic, readonly, copy) NSString *backendID;
- (NSString *)prepareCollection:(NSString *)localCollection error:(NSError **)error;
- (BOOL)synchronizeArchive:(FlycutArchive *)archive error:(NSError **)error;
@end

@interface FlycutFolderSync : NSObject <FlycutSyncTransport>
- (instancetype)initWithDirectoryURL:(NSURL *)directory;
@end

@interface FlycutServerSync : NSObject <FlycutSyncTransport, NSURLSessionTaskDelegate>
- (instancetype)initWithURL:(NSURL *)url collectionID:(NSString *)collectionID
             credentialFileURL:(NSURL *)credentialFile securedTailnetHTTP:(BOOL)securedTailnetHTTP;
@end

#if FLYCUT_CLOUDKIT
@interface FlycutCloudKitSync : NSObject <FlycutSyncTransport>
- (instancetype)initWithContainerIdentifier:(NSString *)identifier;
@end
#endif

@interface FlycutSyncController : NSObject
- (instancetype)initWithArchive:(FlycutArchive *)archive;
@property(nonatomic, readonly, strong) FlycutArchive *archive;
@property(nonatomic, readonly, copy) NSString *status;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) BOOL connected;
- (void)configureTransport:(id<FlycutSyncTransport>)transport sharingExistingEvents:(BOOL)share
               completion:(void (^)(NSError *error))completion;
- (void)synchronize;
- (void)resetCheckpoint;
- (void)failConfiguration:(NSError *)error;
- (void)stop;
@end
