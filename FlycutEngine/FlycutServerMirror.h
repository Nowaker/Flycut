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

@class FlycutClipping, FlycutBlobStore;

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

// The server's web history (/web/). A one-time link that signs a browser in; it works once, within two minutes.
-(void) requestWebAdmission:(void (^)(NSURL *link, NSString *error))completion;
// The optional login and password for signing in without Flycut. A nil password removes it.
-(void) fetchWebLogin:(void (^)(NSString *login, BOOL hasPassword, NSString *error))completion;
-(void) setWebLogin:(NSString *)login password:(NSString *)password completion:(void (^)(NSString *error))completion;

// The server's archive, every machine's merged history (GET /v1/archive/search): clippings matching all the
// words in contents, app or machine, newest first, beyond what this machine keeps. Each result is a clipping to
// show, its sealed contents opened, with the put event it came from at the same index of events.
-(void) searchArchive:(NSString *)words inList:(int)list limit:(NSUInteger)limit
		   completion:(void (^)(NSArray *clippings, NSArray *events, NSUInteger matched, NSString *error))completion;
// Fetches an archive event's pasteboard data into the store, opening sealed data, and hands back the items in
// FlycutClipping's form; nil items when the event has none. Data the server no longer has is left out.
-(void) importItemsOfArchiveEvent:(NSDictionary *)event intoStore:(FlycutBlobStore *)store
					   completion:(void (^)(NSArray *items, NSString *error))completion;

// For each clipping (by id), where the server keeps its data: local address -> {"m": machine, "b": address on
// the server, "s": sealed}, only for data the server has. Read from the local copies of the logs.
-(void) locateDataOfClippings:(NSArray *)clippings completion:(void (^)(NSDictionary *sources, NSString *error))completion;
// Fetches the clipping's data missing from the store back from the server; complete when nothing is missing after.
-(void) restoreDataOfClipping:(FlycutClipping *)clipping inStore:(FlycutBlobStore *)store
				   completion:(void (^)(BOOL complete, NSString *error))completion;

// Where the local copy of a server's logs is kept for this app.
+(NSString *) localFolderForServerURL:(NSURL *)serverURL;

// The bearer token, kept in the login keychain.
+(NSString *) tokenForServerURL:(NSURL *)serverURL;
+(void) setToken:(NSString *)token forServerURL:(NSURL *)serverURL;

@end
