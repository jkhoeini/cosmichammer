//
//  MJAppDelegate.h
//  Hammerspoon
//
//  Created by Chris Jones on 02/09/2015.
//  Copyright (c) 2015 Hammerspoon. All rights reserved.
//

@protocol HSOpenFileDelegate <NSObject>

-(void)callbackWithURL:(NSString *)openUrl senderPID:(pid_t)pid;

@end

@interface MJAppDelegate : NSObject <NSApplicationDelegate>
@property IBOutlet NSMenu* menuBarMenu;
@property (nonatomic, copy) NSAppleEventDescriptor *startupEvent;
@property (nonatomic, copy) NSString *startupFile;
@property (nonatomic, weak) id<HSOpenFileDelegate> openFileDelegate;
@end
