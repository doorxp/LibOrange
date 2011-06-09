//
//  MyTest.m
//  LibOrange
//
//  Created by Alex Nichol on 6/1/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

#import "MyTest.h"

#define kSignoffTime 120

static void stripNL (char * buff) {
	if (strlen(buff) == 0) return;
	if (buff[strlen(buff) - 1] == '\n') {
		buff[strlen(buff) - 1] = 0;
	}
}

@implementation MyTest

- (void)beginTest {
	mainThread = [NSThread currentThread];
	char buffer[512];
	printf("Enter username: ");
	fgets(buffer, 512, stdin);
	stripNL(buffer);
	NSString * username = [NSString stringWithUTF8String:buffer];
	
	printf("Enter password: ");
	fgets(buffer, 512, stdin);
	stripNL(buffer);
	NSString * password = [NSString stringWithUTF8String:buffer];
	
	login = [[AIMLogin alloc] initWithUsername:username password:password];
	[login setDelegate:self];
	if (![login beginAuthorization]) {
		NSLog(@"Failed to start authenticating.");
		abort();
	}
	[self blockingCheck];
}

- (void)blockingCheck {
	static NSDate * lastTime = nil;
	if (!lastTime) {
		lastTime = [[NSDate date] retain];
	} else {
		NSDate * newTime = [NSDate date];
		NSTimeInterval ti = [newTime timeIntervalSinceDate:lastTime];
		if (ti > 0.2) {
			NSLog(@"Main thread blocked for %d milliseconds.", (int)round(ti * 1000.0));
		}
		[lastTime release];
		lastTime = [newTime retain];
	}
	[self performSelector:@selector(blockingCheck) withObject:nil afterDelay:0.05];
}

- (void)checkThreading {
	if ([NSThread currentThread] != mainThread) {
		NSLog(@"warning: NOT RUNNING ON MAIN THREAD!");
	}
}

#pragma mark Login Delegate

- (void)aimLogin:(AIMLogin *)theLogin failedWithError:(NSError *)error {
	[self checkThreading];
	NSLog(@"AIM login failed: %@", error);
	[login release];
	exit(-1);
}

- (void)aimLogin:(AIMLogin *)theLogin openedSession:(AIMSessionManager *)session {
	[self checkThreading];
	[session setDelegate:self];
	[login release];
	login = nil;
	theSession = [session retain];
	
	/* Set handler delegates */
	session.feedbagHandler.delegate = self;
	session.messageHandler.delegate = self;
	session.statusHandler.delegate = self;
	
	AIMBuddyStatus * newStatus = [[AIMBuddyStatus alloc] initWithMessage:@"LibOrange test for Mac!" type:AIMBuddyStatusAvailable timeIdle:0];
	[session.statusHandler updateStatus:newStatus];
	[newStatus release];
	
	NSLog(@"Got session: %@", session);
	NSLog(@"Our status: %@", session.statusHandler.userStatus);
	NSLog(@"Disconnecting in %d seconds ...", kSignoffTime);
	[[session session] performSelector:@selector(closeConnection) withObject:nil afterDelay:kSignoffTime];
}

#pragma mark Session Delegate

- (void)aimSessionManagerSignedOff:(AIMSessionManager *)sender {
	[self checkThreading];
	[theSession autorelease];
	theSession = nil;
	NSLog(@"Session signed off");
}

#pragma mark Buddy List Methods

- (void)aimFeedbagHandlerGotBuddyList:(AIMFeedbagHandler *)feedbagHandler {
	[self checkThreading];
	NSLog(@"%@ got the buddy list.", feedbagHandler);
	NSLog(@"%@", [theSession.session buddyList]);
}

- (void)aimFeedbagHandler:(AIMFeedbagHandler *)sender buddyAdded:(AIMBlistBuddy *)newBuddy {
	[self checkThreading];
	NSLog(@"Buddy added: %@", newBuddy);
}

- (void)aimFeedbagHandler:(AIMFeedbagHandler *)sender buddyDeleted:(AIMBlistBuddy *)oldBuddy {
	[self checkThreading];
	NSLog(@"Buddy removed: %@", oldBuddy);
}

- (void)aimFeedbagHandler:(AIMFeedbagHandler *)sender groupAdded:(AIMBlistGroup *)newGroup {
	[self checkThreading];
	NSLog(@"Group added: %@", [newGroup name]);
}

- (void)aimFeedbagHandler:(AIMFeedbagHandler *)sender groupDeleted:(AIMBlistGroup *)oldGroup {
	[self checkThreading];
	NSLog(@"Group removed: %@", [oldGroup name]);
}

- (void)aimFeedbagHandler:(AIMFeedbagHandler *)sender groupRenamed:(AIMBlistGroup *)theGroup {
	[self checkThreading];
	NSLog(@"Group renamed: %@", [theGroup name]);
	NSLog(@"Blist: %@", theSession.session.buddyList);
}

#pragma mark Message Handler

- (void)aimICBMHandler:(AIMICBMHandler *)sender gotMessage:(AIMMessage *)message {
	[self checkThreading];
	
	NSString * msgTxt = [message plainTextMessage];
	
	NSString * autoresp = [message isAutoresponse] ? @" (Auto-Response)" : @"";
	NSLog(@"(%@) %@%@: %@", [NSDate date], [[message buddy] username], autoresp, [message plainTextMessage]);
	
	if ([msgTxt hasPrefix:@"add "]) {
		[self handleAddBuddyMsg:message msgSender:sender];
	} else if ([msgTxt isEqual:@"blist"]) {
		NSString * desc = [[theSession.session buddyList] description];
		AIMMessage * blistMsg = [AIMMessage messageWithBuddy:[message buddy] message:[desc stringByAddingAOLRTFTags]];
		[sender sendMessage:blistMsg];
	} else {
		AIMMessage * reply = [AIMMessage autoresponseMessageWithBuddy:[message buddy] message:@"I am a robot!"];
		[sender sendMessage:reply];
	}
}

- (void)aimICBMHandler:(AIMICBMHandler *)sender gotMissedCall:(AIMMissedCall *)missedCall {
	[self checkThreading];
	NSLog(@"Missed call from %@", [missedCall buddy]);
}

- (void)handleAddBuddyMsg:(AIMMessage *)message msgSender:(AIMICBMHandler *)sender {
	NSString * msgTxt = [message plainTextMessage];
	NSString * buddyName = [msgTxt substringFromIndex:4];
	if (!buddyName || [buddyName length] == 0) {
		AIMMessage * reply = [AIMMessage messageWithBuddy:[message buddy] message:@"Invalid buddy name."];
		[sender sendMessage:reply];
	} else {
		AIMBlistGroup * group = [theSession.session.buddyList groupWithName:@"Buddies"];
		if (!group) {
			AIMMessage * reply = [AIMMessage messageWithBuddy:[message buddy] message:@"Err: No \"Buddies\" group found!"];
			[sender sendMessage:reply];
		} else {
			FTAddBuddy * addBudd = [[FTAddBuddy alloc] initWithUsername:buddyName group:group];
			[theSession.feedbagHandler pushTransaction:addBudd];
			[addBudd release];
			AIMMessage * reply = [AIMMessage messageWithBuddy:[message buddy] message:@"Buddy insert requested."];
			[sender sendMessage:reply];
		}
	}
}

#pragma mark Status Handler

- (void)aimStatusHandler:(AIMStatusHandler *)handler buddy:(AIMBlistBuddy *)theBuddy statusChanged:(AIMBuddyStatus *)status {
	[self checkThreading];
	NSLog(@"%@ status = %@", theBuddy, status);
}

- (void)aimStatusHandlerUserStatusUpdated:(AIMStatusHandler *)handler {
	[self checkThreading];
	NSLog(@"our user status = %@", [handler userStatus]);
}

@end
