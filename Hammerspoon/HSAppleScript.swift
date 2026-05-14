//
//  HSAppleScript.swift
//  Hammerspoon
//
//  Created by Chris Hocking on 5/4/17.
//  Copyright © 2017 Hammerspoon. All rights reserved.
//

import Foundation
import LuaSkin

private let appleScriptErrorMessage = "Hammerspoon's AppleScript support is currently disabled. Please enable it in Hammerspoon by using the hs.allowAppleScript(true) command."

private let hsAppleScriptEnabledKey = "HSAppleScriptEnabledKey"

@objc func HSAppleScriptEnabled() -> Bool {
    UserDefaults.standard.bool(forKey: hsAppleScriptEnabledKey)
}

@objc func HSAppleScriptSetEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: hsAppleScriptEnabledKey)
}

private func hsAppleScriptRunString(_ command: NSScriptCommand, code: String) -> String {
    let skin = LuaSkin.shared(withState: nil)
    guard let L = skin.L else { return "Error" }
    let stackTop = lua_gettop(L)

    lua_getglobal(L, "hs")
    if lua_getfield(L, -1, "__appleScriptRunString") != LUA_TFUNCTION {
        skin.logError("\(String(cString: lua_typename(L, lua_type(L, -1))))")
        command.scriptErrorNumber = -50
        command.scriptErrorString = "hs.__appleScriptRunString is not a function"
        lua_pop(L, 2)
        assert(stackTop == lua_gettop(L))
        return "Error"
    }

    lua_pushstring(L, code)
    if !skin.protectedCallAndTraceback(1, nresults: 2) {
        let errMsg = "hs.__appleScriptRunString callback error:\(String(cString: lua_tostring(L, -1)))"
        skin.logError(errMsg)
        command.scriptErrorNumber = -50
        command.scriptErrorString = errMsg
        lua_pop(L, 2)
        assert(stackTop == lua_gettop(L))
        return "Error"
    }

    let str = skin.toNSObject(atIndex: -1) as? String ?? ""
    let good = lua_toboolean(L, -2) != 0
    lua_pop(L, 3)

    if good {
        assert(stackTop == lua_gettop(L))
        return str
    } else {
        command.scriptErrorNumber = -50
        command.scriptErrorString = str
        assert(stackTop == lua_gettop(L))
        return "Error"
    }
}

@objc(executeLua)
class ExecuteLua: NSScriptCommand {

    override func performDefaultImplementation() -> Any? {
        guard let args = evaluatedArguments, !args.isEmpty,
              let stringToExecute = args[""] as? String else {
            scriptErrorNumber = -50
            scriptErrorString = "A Parameter is expected for the verb 'execute'. You need to tell Hammerspoon what Lua code you want to execute."
            return "Error"
        }

        if HSAppleScriptEnabled() {
            return hsAppleScriptRunString(self, code: stringToExecute)
        } else {
            scriptErrorNumber = -50
            scriptErrorString = appleScriptErrorMessage
            return "Error"
        }
    }
}
