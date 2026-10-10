#import <Foundation/Foundation.h>

extern NSString * const FlycutArchiveErrorDomain;
extern NSString * const FlycutArchiveDidChangeNotification;
extern NSString * const FlycutArchiveProtocol;

typedef NS_ENUM(NSInteger, FlycutArchiveErrorCode) {
	FlycutArchiveStorageError = 1,
	FlycutArchiveInvalidEvent,
	FlycutArchiveConflictingEvent,
	FlycutArchiveCollectionMismatch,
	FlycutArchiveStaleCursor,
	FlycutArchiveClockExhausted,
	FlycutArchiveInvalidArgument
};

// All methods are synchronous and serialized. Call storage work off the UI thread.
// Notifications are posted on the caller's thread, only after a durable commit.
// No operation reads/writes the clipboard or global preferences.
@interface FlycutArchive : NSObject {
@private
	void *_database;
	NSString *_path;
}

- (id)initWithPath:(NSString *)path error:(NSError **)error;
@property(nonatomic, readonly, copy) NSString *collectionID;
@property(nonatomic, readonly, copy) NSString *deviceID;
@property(nonatomic, readonly) long long revision;

// Item dictionaries: item_id, text, content_type, captured_at_ms, source_app,
// source_id, favorite, recent_clock (decimal string), recent_device, recent_event.
// Nullable metadata is NSNull. Separate captures always get separate UUIDs.
- (NSDictionary *)captureText:(NSString *)text
					 sourceApp:(NSString *)sourceApp
					  sourceID:(NSString *)sourceID
				  capturedAtMS:(NSNumber *)capturedAtMS
					  favorite:(BOOL)favorite error:(NSError **)error;
- (NSDictionary *)itemWithID:(NSString *)itemID error:(NSError **)error;
- (BOOL)setFavorite:(BOOL)favorite forItemID:(NSString *)itemID error:(NSError **)error;
- (BOOL)touchItemID:(NSString *)itemID error:(NSError **)error;
- (BOOL)deleteItemID:(NSString *)itemID error:(NSError **)error;
// Deletes locally known live nonfavorites only; unseen remote captures may arrive
// later. Deletion is not secure erasure. Events/tombstones are retained forever.
- (BOOL)clearHistory:(NSError **)error;

// Page: items (bounded array), next_cursor (dictionary or NSNull), has_more,
// revision. limit 1..1000. Query is literal case-insensitive substring (not SQL
// LIKE syntax). favoritesOnly filters favorites. groupDuplicates groups exact
// text, returning the newest representative; mutations target that item's ID.
// Cursor binds all filters and revision; stale cursor returns StaleCursor and
// caller must restart at nil. No full-archive projection is materialized.
- (NSDictionary *)searchText:(NSString *)query favoritesOnly:(BOOL)favoritesOnly
				groupDuplicates:(BOOL)groupDuplicates limit:(NSUInteger)limit
						 cursor:(NSDictionary *)cursor error:(NSError **)error;

// Export ordered by durable insertion sequence, NOT Lamport clock. Page keys:
// events, next_sequence (NSNumber), has_more. afterSequence starts at 0.
- (NSDictionary *)eventsAfterSequence:(long long)sequence limit:(NSUInteger)limit
								 error:(NSError **)error;
// Atomic batch validation, event insertion/reduction, local clock advancement,
// and optional backend download checkpoint. Equivalent retries are harmless;
// conflicting reuse of IDs fails the entire batch. No derived events.
- (BOOL)ingestEvents:(NSArray *)events backend:(NSString *)backend
		 checkpoint:(NSString *)checkpoint error:(NSError **)error;
+ (BOOL)validateEvent:(NSDictionary *)event error:(NSError **)error;

// Checkpoint dictionary: upload_sequence (NSNumber), download_cursor (NSNull or
// string). Upload acknowledgement is separate from import/download checkpoint.
- (NSDictionary *)checkpointForBackend:(NSString *)backend error:(NSError **)error;
- (BOOL)acknowledgeUploadThroughSequence:(long long)sequence backend:(NSString *)backend
								 error:(NSError **)error;
- (BOOL)resetCheckpointForBackend:(NSString *)backend error:(NSError **)error;

// Explicit collection decision ONLY. Empty archives may adopt with share NO.
// Nonempty archives require share YES: relabel all retained event envelopes in
// one transaction, preserve every event/item ID, and reset all checkpoints.
// Does not merge collections or discard events, and preserves the device ID.
- (BOOL)adoptCollectionID:(NSString *)collectionID sharingExistingEvents:(BOOL)share
					 error:(NSError **)error;

// Pass the RAW legacy persistent-domain dictionary (not a capped FlycutStore).
// Reads store.jcList/favoritesList; stores the entire raw property-list backup
// in SQLite atomically with import and the migration marker. Idempotent.
// Matched favorites inherit history recency; unmatched favorites retain their
// relative order. One item cannot preserve two conflicting legacy list orders.
// Caller stops legacy defaults history writes after this succeeds. Never uses
// standardUserDefaults or writes either app's persistent domain.
- (BOOL)migrateLegacyDefaults:(NSDictionary *)defaults error:(NSError **)error;
- (NSDictionary *)legacyDefaultsBackup:(NSError **)error;

@end
