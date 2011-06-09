//
//  AIMFeedbagHandler.m
//  LibOrange
//
//  Created by Alex Nichol on 6/4/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "AIMFeedbagHandler.h"

@interface AIMFeedbagHandler (private)

- (void)_handleFeedbagResponse:(SNAC *)feedbagSnac;

- (void)_handleInsert:(NSArray *)feedbagItems;
- (void)_handleDelete:(NSArray *)feedbagItems;
- (void)_handleUpdate:(NSArray *)feedbagItems;

/* Update Handlers */
- (void)_handleGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)item;
- (void)_handleRootGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)newItem;

/* Informers */
- (void)_delegateInformHasBlist;
- (void)_delegateInformAddedB:(AIMBlistBuddy *)theBuddy;
- (void)_delegateInformRemovedB:(AIMBlistBuddy *)theBuddy;
- (void)_delegateInformAddedG:(AIMBlistGroup *)theGroup;
- (void)_delegateInformRemovedG:(AIMBlistGroup *)theGroup;
- (void)_delegateInformRenamed:(AIMBlistGroup *)theGroup;

/* Transactions */
- (void)handleTransactionStatus:(SNAC *)statusCodes;
- (void)execNextOperation;
- (SNAC *)prevOperation;

@end

@implementation AIMFeedbagHandler

@synthesize feedbag;
@synthesize session;
@synthesize delegate;
@synthesize feedbagRights;
@synthesize tempBuddyHandler;

- (id)initWithSession:(AIMSession *)theSession {
	if ((self = [super init])) {
		session = theSession;
		[session addHandler:self];
		transactions = [[NSMutableArray alloc] init];
	}
	return self;
}

- (BOOL)sendFeedbagRequest {
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	SNAC * query = [[SNAC alloc] initWithID:SNAC_ID_NEW(19, 4) flags:0 requestID:[session generateReqID] data:nil];
	BOOL success = [session writeSnac:query];
	[query release];
	return success;
}

- (UInt8)currentPDMode:(BOOL *)isPresent {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	AIMFeedbagItem * pdInfo = [feedbag findPDMode];
	if (!pdInfo) {
		if (isPresent) *isPresent = NO;
		return 1;
	} else {
		for (TLV * attr in pdInfo.attributes) {
			if ([attr type] == FEEDBAG_ATTRIBUTE_PD_MODE && [[attr tlvData] length] == 1) {
				UInt8 pdMode = *(const UInt8 *)([[attr tlvData] bytes]);
				if (isPresent) *isPresent = YES;
				return pdMode;
			}
		}
		if (isPresent) *isPresent = NO;
		return 1;
	}
}

- (void)handleIncomingSnac:(SNAC *)aSnac {
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__REPLY))) {
		[self _handleFeedbagResponse:aSnac];
	} else if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__INSERT_ITEMS))) {
		NSArray * items = [AIMFeedbagItem decodeArray:[aSnac innerContents]];
		[self performSelector:@selector(_handleInsert:) onThread:session.mainThread withObject:items waitUntilDone:YES];
	} else if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__UPDATE_ITEMS))) {
		NSArray * items = [AIMFeedbagItem decodeArray:[aSnac innerContents]];
		[self performSelector:@selector(_handleUpdate:) onThread:session.mainThread withObject:items waitUntilDone:YES];
	} else if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__DELETE_ITEMS))) {
		NSArray * items = [AIMFeedbagItem decodeArray:[aSnac innerContents]];
		[self performSelector:@selector(_handleDelete:) onThread:session.mainThread withObject:items waitUntilDone:YES];
	} else if (SNAC_ID_IS_EQUAL([aSnac snac_id], SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__STATUS))) {
		[self handleTransactionStatus:aSnac];
	}
}

- (void)_handleFeedbagResponse:(SNAC *)aSnac {
	if (!feedbag) {
		feedbag = [[AIMFeedbag alloc] initWithSnac:aSnac];
	} else {
		AIMFeedbag * theFeedbag = [[AIMFeedbag alloc] initWithSnac:aSnac];
		[feedbag appendFeedbagItems:theFeedbag];
		[theFeedbag release];
	}
	if ([aSnac isLastResponse]) {
		SNAC * feedbagUse = [[SNAC alloc] initWithID:SNAC_ID_NEW(SNAC_FEEDBAG, FEEDBAG__USE) flags:0 requestID:[session generateReqID] data:nil];
		[session writeSnac:feedbagUse];
		[feedbagUse release];
		session.buddyList = [[[AIMBlist alloc] initWithFeedbag:feedbag tempBuddyHandler:tempBuddyHandler] autorelease];
		[self performSelector:@selector(_delegateInformHasBlist) onThread:[session mainThread] withObject:nil waitUntilDone:NO];
		
		if (![feedbag findRootGroup]) {
			FTCreateRootGroup * createRootGroup = [[FTCreateRootGroup alloc] init];
			[self pushTransaction:createRootGroup];
			[createRootGroup release];
		}
		if (![feedbag findPDMode]) {
			FTSetPDMode * setMode = [[FTSetPDMode alloc] initWithPDMode:PD_MODE_PERMIT_ALL pdFlags:1];
			[self pushTransaction:setMode];
			[setMode release];
		}
	}
}

#pragma mark Modification Handlers

- (void)_handleInsert:(NSArray *)feedbagItems {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	for (AIMFeedbagItem * item in feedbagItems) {
		[[feedbag items] addObject:item];
	}
}
- (void)_handleDelete:(NSArray *)feedbagItems {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	for (AIMFeedbagItem * item in feedbagItems) {
		for (int i = 0; i < [[feedbag items] count]; i++) {
			AIMFeedbagItem * oldItem = [[feedbag items] objectAtIndex:i];
			if ([oldItem groupID] == [item groupID] && [oldItem itemID] == [item itemID]) {
				[[feedbag items] removeObjectAtIndex:i];
				break;
			}
		}
	}
}
- (void)_handleUpdate:(NSArray *)feedbagItems {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	for (AIMFeedbagItem * item in feedbagItems) {
		for (int i = 0; i < [[feedbag items] count]; i++) {
			AIMFeedbagItem * oldItem = [[feedbag items] objectAtIndex:i];
			if ([oldItem groupID] == [item groupID] && [oldItem itemID] == [item itemID]) {
				if ([oldItem classID] == FEEDBAG_GROUP && [oldItem groupID] != 0) {
					[self _handleGroupChanged:oldItem newItem:item];
					if (![[oldItem itemName] isEqual:[item itemName]]) {
						AIMBlistGroup * group = [session.buddyList groupWithFeedbagID:item.groupID];
						if (group) {
							[group setName:[item itemName]];
							/* Should already be on main thread. */
							[self performSelector:@selector(_delegateInformRenamed:) onThread:session.mainThread withObject:group waitUntilDone:YES];
						}
					}
				} else if ([oldItem classID] == FEEDBAG_GROUP && [oldItem groupID] == 0) {
					[self _handleRootGroupChanged:oldItem newItem:item];
				}
				[oldItem setAttributes:[item attributes]];
				[oldItem setItemName:[item itemName]];
				break;
			}
		}
	}
}

- (void)_handleGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)item {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	NSArray * added = nil;
	NSArray * removed = nil;
	BOOL changed = [oldItem orderChangeToItem:item added:&added removed:&removed];
	if (changed) {
		for (NSNumber * removedID in removed) {
			UInt16 itemID = [removedID unsignedShortValue];
			AIMBlistBuddy * buddy = [[session.buddyList buddyWithFeedbagID:itemID] retain];
			if (buddy) {
				AIMBlistGroup * group = [buddy group];
				NSMutableArray * buddies = (NSMutableArray *)[group buddies];
				[buddies removeObject:buddy];
				/* Should be running on main thread anyway. */
				[self performSelector:@selector(_delegateInformRemovedB:) onThread:session.mainThread withObject:buddy waitUntilDone:YES];
				[buddy release];
			}
		}
		for (NSNumber * addedID in added) {
			AIMFeedbagItem * theItem = [feedbag itemWithItemID:[addedID unsignedShortValue]];
			if (theItem) {
				AIMBlistBuddy * buddy = [[AIMBlistBuddy alloc] initWithUsername:[theItem itemName]];
				AIMBlistGroup * group = [session.buddyList groupWithFeedbagID:[oldItem groupID]];
				if (group) {
					NSMutableArray * buddies = (NSMutableArray *)[group buddies];
					[buddies addObject:buddy];
					[buddy setGroup:group];
					[buddy setFeedbagItemID:[theItem itemID]];
					/* Should be running on main thread anyway. */
					AIMBlistBuddy * tempBuddy = [tempBuddyHandler tempBuddyWithName:[theItem itemName]];
					if (tempBuddy) {
						[buddy setStatus:[tempBuddy status]];
						[tempBuddyHandler deleteTempBuddy:tempBuddy];
					}
					[self performSelector:@selector(_delegateInformAddedB:) onThread:session.mainThread withObject:buddy waitUntilDone:YES];
				} else {
					NSLog(@"%@ added to unknown group %@", buddy, [oldItem itemName]);
				}
				[buddy release];
			}
		}
	}
}

- (void)_handleRootGroupChanged:(AIMFeedbagItem *)oldItem newItem:(AIMFeedbagItem *)newItem {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	NSArray * added = nil;
	NSArray * removed = nil;
	BOOL changed = [oldItem orderChangeToItem:newItem added:&added removed:&removed];
	if (changed) {
		for (NSNumber * removedID in removed) {
			UInt16 groupID = [removedID unsignedShortValue];
			AIMBlistGroup * group = [[session.buddyList groupWithFeedbagID:groupID] retain];
			NSMutableArray * groups = (NSMutableArray *)[session.buddyList groups];
			[groups removeObject:group];
			/* Should be running on main thread anyway. */
			[self performSelector:@selector(_delegateInformRemovedG:) onThread:session.mainThread withObject:group waitUntilDone:NO];
			[group release];
		}
		for (NSNumber * addedID in added) {
			UInt16 groupID = [addedID unsignedShortValue];
			AIMFeedbagItem * item = [feedbag groupWithGroupID:groupID];
			AIMBlistGroup * group = [session.buddyList loadGroup:item inFeedbag:feedbag];
			NSMutableArray * groups = (NSMutableArray *)[session.buddyList groups];
			[groups addObject:group];
			for (AIMBlistBuddy * buddy in [group buddies]) {
				AIMBlistBuddy * tempBuddy = [tempBuddyHandler tempBuddyWithName:[buddy username]];
				if (tempBuddy) {
					[buddy setStatus:[tempBuddy status]];
					[tempBuddyHandler deleteTempBuddy:tempBuddy];
				}
			}
			/* Should be running on main thread anyway. */
			[self performSelector:@selector(_delegateInformAddedG:) onThread:session.mainThread withObject:group waitUntilDone:NO];
		}
	}
}

#pragma mark Private

- (void)_delegateInformHasBlist {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandlerGotBuddyList:)]) {
		[delegate aimFeedbagHandlerGotBuddyList:self];
	}
}

- (void)_delegateInformAddedB:(AIMBlistBuddy *)theBuddy {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:buddyAdded:)]) {
		[delegate aimFeedbagHandler:self buddyAdded:theBuddy];
	}
}
- (void)_delegateInformRemovedB:(AIMBlistBuddy *)theBuddy {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:buddyDeleted:)]) {
		[delegate aimFeedbagHandler:self buddyDeleted:theBuddy];
	}
}
- (void)_delegateInformAddedG:(AIMBlistGroup *)theGroup {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:groupAdded:)]) {
		[delegate aimFeedbagHandler:self groupAdded:theGroup];
	}
}
- (void)_delegateInformRemovedG:(AIMBlistGroup *)theGroup {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:groupDeleted:)]) {
		[delegate aimFeedbagHandler:self groupDeleted:theGroup];
	}
}
- (void)_delegateInformRenamed:(AIMBlistGroup *)theGroup {
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([delegate respondsToSelector:@selector(aimFeedbagHandler:groupRenamed:)]) {
		[delegate aimFeedbagHandler:self groupRenamed:theGroup];
	}
}

#pragma mark Transactions

- (void)pushTransaction:(id<FeedbagTransaction>)transaction {
	if ([NSThread currentThread] != session.backgroundThread) {
		[self performSelector:@selector(pushTransaction:) onThread:session.backgroundThread withObject:transaction waitUntilDone:NO];
		return;
	}
	// should never be asserted...
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	[transactions addObject:transaction];
	if ([transactions count] == 1) {
		[self execNextOperation];
	}
}

- (void)execNextOperation {
	if ([NSThread currentThread] != [session mainThread]) {
		[self performSelector:@selector(execNextOperation) onThread:[session mainThread] withObject:nil waitUntilDone:NO];
		return;
	}
	// should never be asserted...
	NSAssert([NSThread currentThread] == [session mainThread], @"Running on incorrect thread");
	if ([transactions count] == 0) return;
	id<FeedbagTransaction> trans = [transactions objectAtIndex:0];
	if (![trans hasCreatedOperations]) [trans createOperationsWithFeedbag:feedbag session:session];
	SNAC * nextTrans = [trans nextTransactionSNAC];
	if (!nextTrans) {
		[transactions removeObjectAtIndex:0];
		[self execNextOperation];
	} else {
		[session performSelector:@selector(writeSnac:) onThread:session.backgroundThread withObject:nextTrans waitUntilDone:NO];
	}
}

- (SNAC *)prevOperation {
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	if ([transactions count] == 0) return nil;
	id<FeedbagTransaction> trans = [transactions objectAtIndex:0];
	SNAC * prevTrans = [trans currentTransactionSNAC];
	return prevTrans;
}

- (void)handleTransactionStatus:(SNAC *)statusCodes {
	NSAssert([NSThread currentThread] == [session backgroundThread], @"Running on incorrect thread");
	AIMFeedbagStatus * statuses = [[AIMFeedbagStatus alloc] initWithCodeData:[statusCodes innerContents]];
	for (NSUInteger i = 0; i < [statuses statusCodeCount]; i++) {
		AIMFeedbagStatusType type = [statuses statusAtIndex:i];
		if (type != FBS_SUCCESS) {
			// failure.
			NSLog(@"Feedbag operation failed with code %d", type);
			[transactions removeObjectAtIndex:0];
			[self execNextOperation];
		} else {
			SNAC * prev = [self prevOperation];
			/* 
			 * Simulate that the transaction SNAC was sent from the client, thus
			 * applying it to the feedbag FOR US!
			 */
			[self handleIncomingSnac:prev];
			[self execNextOperation];
		}
	}
	[statuses release];
}

- (void)dealloc {
	[transactions release];
	[feedbag release];
	self.feedbagRights = nil;
	[super dealloc];
}

@end
