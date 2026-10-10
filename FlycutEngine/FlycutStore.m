//
//  FlycutStore.m
//  Flycut
//
//  Flycut by Gennadiy Potapov and contributors. Based on Jumpcut by Steve Cook.
//  Copyright 2011 General Arcade. All rights reserved.
//
//  This code is open-source software subject to the MIT License; see the homepage
//  at <https://github.com/TermiT/Flycut> for details.
//
//

#import "FlycutStore.h"
#import "FlycutClipping.h"

@implementation FlycutStore

-(id) init
{
    return [self initRemembering:20
                displaying:10	
                withDisplayLength:40 ];
}

-(id) initRemembering:(int)nowRemembering
        displaying:(int)nowDisplaying
        withDisplayLength:(int)displayLength
{
	// Ensure that we don't remember zero or fewer clippings.  Very unlikely, but this provides a safeguard just in case.
	if ( nowRemembering <= 0 )
		nowRemembering = 40;

    [super init];
    jcList = [[NSMutableArray alloc] init];
	insertionJournal = [[NSMutableArray alloc] init];
	deletionJournal = [[NSMutableArray alloc] init];
    [self setRememberNum:nowRemembering];
    [self setDisplayNum:nowDisplaying];
    [self setDisplayLen:displayLength];
    return self;
}

-(int) indexOfClipping:(NSString *)clipping ofType:(NSString *)type fromAppLocalizedName:(NSString *)appLocalizedName fromAppBundleURL:(NSString *)bundleURL atTimestamp:(int) timestamp{
	if ([clipping length] == 0) {
		return -1;
	}
	// Clipping object
	FlycutClipping * newClipping;
	// Create clipping
	newClipping = [[FlycutClipping alloc] initWithContents:clipping
												  withType:type
										 withDisplayLength:[self displayLen]
									  withAppLocalizedName:appLocalizedName
										  withAppBundleURL:bundleURL
											 withTimestamp:timestamp];

	int result = [self indexOfClipping: newClipping];

	[newClipping release];

	return result;
}

-(int) indexOfClippingIdenticalTo:(FlycutClipping*) clipping{
	NSUInteger index = [jcList indexOfObjectIdenticalTo:clipping];
	return NSNotFound == index ? -1 : (int)index;
}

-(int) indexOfClipping:(FlycutClipping*) clipping{
	return [self indexOfClipping:clipping afterIndex:-1];
}

-(int) indexOfClipping:(FlycutClipping*) clipping afterIndex:(int) after{
	NSUInteger index = [jcList indexOfObject:clipping
									 inRange:NSMakeRange(after + 1, [jcList count] - (after + 1) )];
	if ( NSNotFound == index ) {
		return -1;
	}
	return (int)index;
}

// Add a clipping
-(bool) addClipping:(NSString *)clipping ofType:(NSString *)type fromAppLocalizedName:(NSString *)appLocalizedName fromAppBundleURL:(NSString *)bundleURL atTimestamp:(int) timestamp{
    if ([clipping length] == 0) {
        return NO;
    }
    // Clipping object
    FlycutClipping * newClipping;
	// Create clipping
    newClipping = [[FlycutClipping alloc] initWithContents:clipping
												   withType:type
										  withDisplayLength:[self displayLen]
									   withAppLocalizedName:appLocalizedName
										   withAppBundleURL:bundleURL
											  withTimestamp:timestamp];
	
	[self addClipping:newClipping];
	
	[newClipping release];
	return YES;
}

-(bool) removeDuplicates{
	return [[[NSUserDefaults standardUserDefaults] valueForKey:@"removeDuplicates"] boolValue];
}

-(void) addClipping:(FlycutClipping*) clipping{
	[self insertClipping:clipping atIndex:0];
}

-(void) insertClipping:(FlycutClipping*) clipping atIndex:(int) index{
	[self delegateBeginUpdates];

	NSMutableArray *removedClippings = [NSMutableArray array];
	int moveFromIndex = -1;
	if ([jcList containsObject:clipping] && [self removeDuplicates]) {
		moveFromIndex = (int)[jcList indexOfObject:clipping];
		[removedClippings addObjectsFromArray:[jcList objectsAtIndexes:[jcList indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
			return [obj isEqual:clipping];
		}]]];
        [jcList removeObject:clipping];
    }

    // Push it onto our recent clippings stack
	if ( index < [jcList count] ) {
		[jcList insertObject:clipping atIndex:index];
	}
	else {
		// If the index is beyond the current count then just append it and disregard requested index.
		// This doesn't alter the remember number and the jcList is self-growing so it is fine to append.
		index = [jcList count];
		[jcList addObject:clipping];
	}
	[self assignRankToClippingAtIndex:index];
	if ( moveFromIndex >= 0 )
		[self delegateMoveClippingAtIndex:moveFromIndex toIndex:index];
	else
		[self delegateInsertClippingAtIndex:index];

	// Delete clippings older than jcRememberNum
	NSMutableArray *droppedClippings = [NSMutableArray array];
	while ( [jcList count] > jcRememberNum ) {
		[self delegateWillDeleteClippingAtIndex:jcRememberNum];
		[droppedClippings addObject:[jcList objectAtIndex:jcRememberNum]];
		[jcList removeObjectAtIndex:jcRememberNum];
		[self delegateDeleteClippingAtIndex:(jcRememberNum-1)]; // -1 for before-add indexing
	}

	[self persistRemovedClippings:removedClippings];
	[self persistDroppedClippings:droppedClippings];
	[self.persistence store:self didSaveClipping:clipping];

	[self delegateEndUpdates];
}

// Ranks order a persisted list without renumbering it: a clipping placed between two others takes the midpoint of their ranks.
-(void) assignRankToClippingAtIndex:(int)index
{
	FlycutClipping *clipping = [jcList objectAtIndex:index];
	BOOL hasNewer = index > 0;
	BOOL hasOlder = index + 1 < [jcList count];
	double newerRank = hasNewer ? [[jcList objectAtIndex:index - 1] rank] : 0;
	double olderRank = hasOlder ? [[jcList objectAtIndex:index + 1] rank] : 0;

	// A new top clipping ranks by the current time, so tops from different machines interleave by when they were made.
	// Stepping past an older top by a millisecond rather than a second keeps rapid moves from running ahead of the clock.
	if ( hasNewer && hasOlder )
		[clipping setRank:(newerRank + olderRank) / 2];
	else if ( hasNewer )
		[clipping setRank:newerRank - 1];
	else
		[clipping setRank:MAX(olderRank + 0.001, [[NSDate date] timeIntervalSince1970])];
}

-(void) persistRemovedClippings:(NSArray *)clippings
{
	if ( [clippings count] > 0 )
		[self.persistence store:self didRemoveClippings:clippings];
}

-(void) persistDroppedClippings:(NSArray *)clippings
{
	if ( [clippings count] == 0 )
		return;
	if ( [self.persistence respondsToSelector:@selector(store:didDropClippings:)] )
		[self.persistence store:self didDropClippings:clippings];
	else
		[self.persistence store:self didRemoveClippings:clippings];
}

-(int) indexOfClippingWithId:(NSString *)clipId
{
	NSUInteger index = [jcList indexOfObjectPassingTest:^BOOL(FlycutClipping *clipping, NSUInteger idx, BOOL *stop) {
		return [[clipping clipId] isEqualToString:clipId];
	}];
	return index == NSNotFound ? -1 : (int)index;
}

static BOOL ClippingOutranks(FlycutClipping *a, FlycutClipping *b)
{
	if ( [a rank] != [b rank] )
		return [a rank] > [b rank];
	return [[a clipId] compare:[b clipId]] == NSOrderedDescending;
}

-(void) placeClippings:(NSArray *)clippings
{
	if ( [clippings count] == 0 )
		return;
	[self delegateBeginUpdates];

	NSMutableDictionary *incoming = [NSMutableDictionary dictionaryWithCapacity:[clippings count]];
	for ( FlycutClipping *clipping in clippings ) {
		[clipping setDisplayLength:jcDisplayLen];
		[incoming setObject:clipping forKey:[clipping clipId]];
	}

	// Clippings being replaced are dropped from the database only if their replacement doesn't make it in.
	NSMutableDictionary *replaced = [NSMutableDictionary dictionary];
	NSMutableArray *candidates = [NSMutableArray arrayWithCapacity:[jcList count] + [incoming count]];
	for ( FlycutClipping *clipping in jcList ) {
		if ( [incoming objectForKey:[clipping clipId]] )
			[replaced setObject:clipping forKey:[clipping clipId]];
		else
			[candidates addObject:clipping];
	}
	[candidates addObjectsFromArray:[incoming allValues]];
	[candidates sortUsingComparator:^NSComparisonResult(FlycutClipping *a, FlycutClipping *b) {
		if ( ClippingOutranks(a, b) )
			return NSOrderedAscending;
		return ClippingOutranks(b, a) ? NSOrderedDescending : NSOrderedSame;
	}];

	NSMutableArray *droppedClippings = [NSMutableArray array];
	NSMutableArray *placed = [NSMutableArray arrayWithCapacity:[candidates count]];
	NSMutableSet *seenContents = [self removeDuplicates] ? [NSMutableSet set] : nil;
	for ( FlycutClipping *clipping in candidates ) {
		if ( seenContents ) {
			if ( [seenContents containsObject:[clipping contents]] ) {
				if ( ![incoming objectForKey:[clipping clipId]] )
					[droppedClippings addObject:clipping];
				continue;
			}
			[seenContents addObject:[clipping contents]];
		}
		[placed addObject:clipping];
	}

	for ( int i = (int)[jcList count] ; i > 0 ; i-- )
		[self delegateDeleteClippingAtIndex:(i-1)];
	[jcList setArray:placed];
	while ( [jcList count] > jcRememberNum ) {
		[self delegateWillDeleteClippingAtIndex:jcRememberNum];
		[droppedClippings addObject:[jcList objectAtIndex:jcRememberNum]];
		[jcList removeObjectAtIndex:jcRememberNum];
	}
	for ( int i = 0 ; i < [jcList count] ; i++ )
		[self delegateInsertClippingAtIndex:i];

	NSMutableSet *keptIds = [NSMutableSet setWithArray:[jcList valueForKey:@"clipId"]];
	for ( NSString *clipId in replaced )
		if ( ![keptIds containsObject:clipId] )
			[droppedClippings addObject:[replaced objectForKey:clipId]];
	[self persistDroppedClippings:droppedClippings];
	for ( FlycutClipping *clipping in [incoming allValues] )
		if ( [keptIds containsObject:[clipping clipId]] )
			[self.persistence store:self didSaveClipping:clipping];

	modifiedSinceLastSaveStore = YES;
	[self delegateEndUpdates];
}

-(void) removeClippingsWithIds:(NSSet *)clipIds
{
	NSMutableArray *removedClippings = [NSMutableArray array];
	[self delegateBeginUpdates];
	for ( int i = (int)[jcList count] - 1 ; i >= 0 ; i-- ) {
		FlycutClipping *clipping = [jcList objectAtIndex:i];
		// Not reported as about to be deleted: these were deleted on purpose, like a user's delete, so they aren't autosaved as forgotten.
		if ( ![clipIds containsObject:[clipping clipId]] )
			continue;
		[removedClippings addObject:clipping];
		[jcList removeObjectAtIndex:i];
		[self delegateDeleteClippingAtIndex:i];
	}
	[self persistRemovedClippings:removedClippings];
	if ( [removedClippings count] )
		modifiedSinceLastSaveStore = YES;
	[self delegateEndUpdates];
}

-(NSArray *) allClippings
{
	return [[jcList copy] autorelease];
}

-(void) loadPersistedClippings:(NSArray *)clippings
{
	[self delegateBeginUpdates];
	for ( int i = (int)[jcList count] ; i > 0 ; i-- )
		[self delegateDeleteClippingAtIndex:(i-1)];
	[jcList setArray:clippings];
	for ( FlycutClipping *aClipping in jcList )
		[aClipping setDisplayLength:jcDisplayLen];
	if ( self.delegate && [self.delegate respondsToSelector:@selector(insertClippingAtIndex:)] )
		for ( int i = 0 ; i < [jcList count] ; i++ )
			[self.delegate insertClippingAtIndex:i];
	[self delegateEndUpdates];

	[self setRememberNum:jcRememberNum];
	[self clearModifiedSinceLastSaveStore];
}

-(void) removeClippingsOlderThan:(NSInteger)cutoffTimestamp
{
	NSMutableArray *removedClippings = [NSMutableArray array];
	[self delegateBeginUpdates];
	for ( int i = (int)[jcList count] - 1 ; i >= 0 ; i-- )
	{
		FlycutClipping *clipping = [jcList objectAtIndex:i];
		if ( [clipping timestamp] > 0 && [clipping timestamp] < cutoffTimestamp )
		{
			[self delegateWillDeleteClippingAtIndex:i];
			[removedClippings addObject:clipping];
			[jcList removeObjectAtIndex:i];
			[self delegateDeleteClippingAtIndex:i];
		}
	}
	[self persistDroppedClippings:removedClippings];
	[self delegateEndUpdates];
}

-(void) addClipping:(NSString *)clipping ofType:(NSString *)type withPBCount:(int *)pbCount
{
    [self addClipping:clipping ofType:type fromAppLocalizedName:@"PBCount" fromAppBundleURL:nil atTimestamp:0];
}

// Clear remembered and listed
-(void) clearList {
    [self delegateBeginUpdates];

    for ( int i = (int)[jcList count] ; i > 0 ; i-- )
	{
		[self delegateWillDeleteClippingAtIndex:(i-1)];
        [self delegateDeleteClippingAtIndex:(i-1)];
	}

    NSMutableArray *emptyJCList;
    emptyJCList = [[NSMutableArray alloc] init];
    [jcList release];
    jcList = emptyJCList;
    [self.persistence storeDidClear:self];

    [self delegateEndUpdates];
}

-(void) mergeList {
    NSString *merge = [[[[jcList reverseObjectEnumerator] allObjects] valueForKey:@"clipContents"] componentsJoinedByString:@"\n"];
    [self addClipping:merge ofType:NSStringFromClass([merge class]) fromAppLocalizedName:@"Merge" fromAppBundleURL:nil atTimestamp:0];
}

-(void) clearItem:(int)index
{
    [self delegateBeginUpdates];

	[self delegateWillDeleteClippingAtIndex:index];
	FlycutClipping *removedClipping = [[jcList objectAtIndex:index] retain];
    [jcList removeObjectAtIndex:index];
    [self delegateDeleteClippingAtIndex:index];
	[self persistRemovedClippings:@[removedClipping]];
	[removedClipping release];

    [self delegateEndUpdates];
}

-(void) clippingMoveToTop:(int)index
{
	[self clippingMoveFrom:index To:0];
}

-(void) clippingMoveFrom:(int)index To:(int)toIndex
{
	[self delegateBeginUpdates];

	FlycutClipping *clipping = [jcList objectAtIndex:index];
	[jcList insertObject:clipping atIndex:toIndex];
	[jcList removeObjectAtIndex:index+1];
	[self assignRankToClippingAtIndex:toIndex];
	[self delegateMoveClippingAtIndex:index toIndex:toIndex];
	[self.persistence store:self didSaveClipping:clipping];

	[self delegateEndUpdates];
}

// Set various values
-(void) setRememberNum:(int)nowRemembering
{
    if ( nowRemembering  > 0 ) {
        jcRememberNum = nowRemembering;

		if ( [jcList count] > jcRememberNum ) {
			[self delegateBeginUpdates];

			NSMutableArray *removedClippings = [NSMutableArray array];
			while ( [jcList count] > jcRememberNum ) {
				[self delegateWillDeleteClippingAtIndex:jcRememberNum];
				[removedClippings addObject:[jcList objectAtIndex:jcRememberNum]];
				[jcList removeObjectAtIndex:jcRememberNum];
				[self delegateDeleteClippingAtIndex:jcRememberNum];
			}
			[self persistDroppedClippings:removedClippings];
			[self delegateEndUpdates];
		}
    }
}

-(void) setDisplayNum:(int)nowDisplaying
{
    if ( nowDisplaying > 0 ) {
        jcDisplayNum = nowDisplaying;
    }
}

-(void) setDisplayLen:(int)newDisplayLength
{
  
    if ( newDisplayLength > 0 ) {
        jcDisplayLen = newDisplayLength;
        for (FlycutClipping *aClipping in jcList) {
            [aClipping setDisplayLength:newDisplayLength];
        }
    }
}

-(void) clearModifiedSinceLastSaveStore
{
	modifiedSinceLastSaveStore = NO;
	insertionJournalCountLastSave = [insertionJournal count];
	deletionJournalCountLastSave = [deletionJournal count];
}

-(void) pruneJournals
{
	[self clearInsertionJournalCount:insertionJournalCountLastSave];
	[self clearDeletionJournalCount:deletionJournalCountLastSave];
}

-(void) clearInsertionJournalCount:(NSUInteger)count
{
	while ( count-- > 0 )
	{
		[insertionJournal removeLastObject];
		if ( insertionJournalCountLastSave > 0 )
			insertionJournalCountLastSave--;
	}
}

-(void) clearDeletionJournalCount:(NSUInteger)count
{
	while ( count-- > 0 )
	{
		[deletionJournal removeLastObject];
		if ( deletionJournalCountLastSave > 0 )
			deletionJournalCountLastSave--;
	}
}

-(int) rememberNum
{
    return jcRememberNum;
}

-(int) displayLen
{
    return jcDisplayLen;
}

-(int) jcListCount
{
    return [jcList count];
}

-(bool) modifiedSinceLastSaveStore
{
	return modifiedSinceLastSaveStore;
}

-(NSArray *) insertionJournal
{
	return insertionJournal;
}

-(NSArray *) deletionJournal
{
	return deletionJournal;
}

-(FlycutClipping *) clippingAtPosition:(int)index
{
    if ( index >= [jcList count] ) {
        return nil;
    } else {
        return [[jcList objectAtIndex:index] clipping];
    }
}

-(NSString *) clippingContentsAtPosition:(int)index
{
	if ( index >= [jcList count] ) {
		return nil;
	} else {
		return [NSString stringWithString:[[jcList objectAtIndex:index] contents]];
	}
}

-(NSString *) clippingDisplayStringAtPosition:(int)index
{
    return [[jcList objectAtIndex:index] displayString];
}

-(NSString *) clippingTypeAtPosition:(int)index
{
    NSString *returnString;
    returnString = [NSString stringWithString:[[jcList objectAtIndex:index] type]];
//    return [[jcList objectAtIndex:index] type];
    return returnString;
}

-(NSArray *) previousContents:(int)howMany
{
    NSRange theRange;
    NSArray *subArray;
    NSMutableArray *returnArray = [[[NSMutableArray alloc] init] autorelease];
    NSEnumerator *enumerator;
    FlycutClipping *aClipping;
    theRange.location = 0;
    theRange.length = howMany;
    if ( howMany > [jcList count] ) {
        subArray = jcList;
    } else {
        subArray = [jcList subarrayWithRange:theRange];
    }
    enumerator = [subArray reverseObjectEnumerator];
    while ( aClipping = [enumerator nextObject] ) {
        [returnArray insertObject:[aClipping contents] atIndex:0];
    }
    return returnArray;
}

-(NSArray *) previousDisplayStrings:(int)howMany
{
    return [self previousDisplayStrings:howMany containing:nil];
}

-(NSArray *) previousDisplayStrings:(int)howMany containing:(NSString*)search
{
    NSRange theRange;
    NSArray *subArray;
    NSMutableArray *returnArray = [[[NSMutableArray alloc] init] autorelease];
    NSEnumerator *enumerator;
    FlycutClipping *aClipping;

    // If we have a search, do that.  Pretty much a mix of the other two paths below, but separated out to avoid extra processing.
    if (nil != search && search.length > 0) {
        subArray = [[jcList copy] autorelease];
        enumerator = [subArray objectEnumerator];
        int index = 0;
        while ( aClipping = [enumerator nextObject] ) { // Forward enumerator so we find the most recent N matches
            if ([[aClipping contents] rangeOfString:search options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [returnArray insertObject:[aClipping displayString] atIndex:0];
                howMany--;
                if (0 == howMany)
                    break;
            }
            index++;
        }
        return [[returnArray reverseObjectEnumerator] allObjects]; // Reverse the results since the caller expects the most recent to be last.
    }

    theRange.location = 0;
    theRange.length = howMany;
    if ( howMany > [jcList count] ) {
        subArray = jcList;
    } else {
        subArray = [jcList subarrayWithRange:theRange];
    }
    enumerator = [subArray reverseObjectEnumerator];
    while ( aClipping = [enumerator nextObject] ) {
        [returnArray insertObject:[aClipping displayString] atIndex:0];
    }
    return returnArray;
}

-(NSArray *) previousIndexes:(int)howMany containing:(NSString*)search // This method is in newest-first order.
{
    NSArray *subArray;
    NSMutableArray *returnArray = [[[NSMutableArray alloc] init] autorelease];
    NSEnumerator *enumerator;
    FlycutClipping *aClipping;

    // If we have a search, do that.
    if (nil != search && search.length > 0) {
        subArray = [[jcList copy] autorelease];
        enumerator = [subArray objectEnumerator];
        int index = 0;
        while ( aClipping = [enumerator nextObject] ) { // Forward enumerator so we find the most recent N matches
            if ([[aClipping contents] rangeOfString:search options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [returnArray addObject:[NSNumber numberWithInt:index]];
                howMany--;
                if (0 == howMany)
                    break;
            }
            index++;
        }
    }
    else
    {
        for ( int i = 0 ; i < howMany ; i++ )
            [returnArray addObject:[NSNumber numberWithInt:i]];
    }
    return returnArray;
}

-(void) delegateBeginUpdates
{
	if ( self.delegate && [self.delegate respondsToSelector:@selector(beginUpdates)] )
		[self.delegate beginUpdates];
}

-(void) delegateEndUpdates
{
	if ( self.delegate && [self.delegate respondsToSelector:@selector(endUpdates)] )
		[self.delegate endUpdates];
}

// The journals only feed iCloud merges, so an unlimited history must not grow them without bound.
-(NSUInteger) journalCapacity
{
	return MIN( jcRememberNum, 1000 );
}

-(void) delegateInsertClippingAtIndex:(int)index
{
	[insertionJournal insertObject:[jcList objectAtIndex:index] atIndex:0];
	if ( [insertionJournal count] > [self journalCapacity] )
		[self clearInsertionJournalCount:( [insertionJournal count] - [self journalCapacity] )];

	modifiedSinceLastSaveStore = YES;
	if ( self.delegate && [self.delegate respondsToSelector:@selector(insertClippingAtIndex:)] )
		[self.delegate insertClippingAtIndex:index];
}

-(void) delegateWillDeleteClippingAtIndex:(int)index
{
	[deletionJournal insertObject:[jcList objectAtIndex:index] atIndex:0];
	if ( [deletionJournal count] > [self journalCapacity] )
		[self clearDeletionJournalCount:( [deletionJournal count] - [self journalCapacity] )];

	if ( self.deleteDelegate && [self.deleteDelegate respondsToSelector:@selector(willDeleteClippingFromStore:AtIndex:)] )
		[self.deleteDelegate willDeleteClippingFromStore:self AtIndex:index];
}

-(void) delegateDeleteClippingAtIndex:(int)index
{
	modifiedSinceLastSaveStore = YES;
	if ( self.delegate && [self.delegate respondsToSelector:@selector(deleteClippingAtIndex:)] )
		[self.delegate deleteClippingAtIndex:index];
}

-(void) delegateReloadClippingAtIndex:(int)index
{
	modifiedSinceLastSaveStore = YES;
	if ( self.delegate && [self.delegate respondsToSelector:@selector(reloadClippingAtIndex:)] )
		[self.delegate reloadClippingAtIndex:index];
}

-(void) delegateMoveClippingAtIndex:(int)index toIndex:(int)newIndex
{
	modifiedSinceLastSaveStore = YES;
	if ( self.delegate && [self.delegate respondsToSelector:@selector(moveClippingAtIndex:toIndex:)] )
		[self.delegate moveClippingAtIndex:index toIndex:newIndex];
}

-(void) dealloc
{
    // Free preferences
    jcRememberNum = 0;
    jcDisplayNum = 0;
    jcDisplayLen = 0;

    // Free collections
    [jcList release];
   
    [super dealloc];
}

@end
