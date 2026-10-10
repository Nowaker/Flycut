//
//  FlycutServerMirror.h
//  Flycut
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//

// FlycutServerMirror makes a flycut-sync-server (sync-server/ in this repository) look like a synced
// folder: it keeps a local folder holding a copy of every machine's log on the server, and uploads
// what FlycutFolderSync appends to this machine's own log there. FlycutFolderSync runs on that folder
// unchanged. Network work happens on a background queue; completion handlers run on the main thread.

#import <Foundation/Foundation.h>

@interface FlycutServerMirror : NSObject

-(instancetype) initWithServerURL:(NSURL *)serverURL
							token:(NSString *)token
					  localFolder:(NSString *)localFolder
						machineId:(NSString *)machineId;

// One round: download what other machines appended, then upload what this machine appended.
// The handler gets YES if anything was downloaded.
-(void) syncWithCompletion:(void (^)(BOOL downloaded))completion;

// Repeats syncWithCompletion: every interval until stopped.
-(void) startWithInterval:(NSTimeInterval)interval onDownload:(void (^)(void))onDownload;
-(void) stop;

@property (nonatomic, readonly) NSString *localFolder;
@property (nonatomic, readonly) NSURL *serverURL;
@property (atomic, readonly) NSString *lastError;	// nil after a round that went through

// Where the local copy of a server's logs is kept for this app.
+(NSString *) localFolderForServerURL:(NSURL *)serverURL;

// The bearer token, kept in the login keychain.
+(NSString *) tokenForServerURL:(NSURL *)serverURL;
+(void) setToken:(NSString *)token forServerURL:(NSURL *)serverURL;

@end
