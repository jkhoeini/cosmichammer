//
//  HSLogger.h
//  Cosmic Hammer
//
//  Created by Chris Jones on 22/01/2018.
//  Copyright © 2018 Cosmic Hammer. All rights reserved.
//

#import <LuaSkin/LuaSkin.h>

#define HSNSLOG(__FORMAT__, ...) NSLog(__FORMAT__, ##__VA_ARGS__)

// Factory functions implemented in HSLogger.swift.
// Using C entry points avoids the need to import the generated -Swift.h header
// in ObjC files that are part of the same SPM target.
extern id<LuaSkinDelegate> HSLoggerCreateWithLua(lua_State *L);
extern void HSLoggerSetLuaState(id<LuaSkinDelegate> logger, lua_State *L);
