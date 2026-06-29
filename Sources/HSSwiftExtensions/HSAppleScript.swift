//
//  HSAppleScript.swift
//  Cosmic Hammer
//
//  Ported from HSAppleScript.m by Mohammad Sadegh Khoeini.
//  Copyright © 2017 Cosmic Hammer. All rights reserved.
//

import Foundation
import CLua
import HSDSTCore
import os.log

// MARK: - UserDefaults key

private let HSAppleScriptEnabledKey = "HSAppleScriptEnabledKey"

// MARK: - Error message

private let appleScriptErrorMessage =
    "Cosmic Hammer's AppleScript support is currently disabled. " +
    "Please enable it in Cosmic Hammer by using the hs.allowAppleScript(true) command."

// MARK: - C-linkage helpers (called from MJLua.m)

@_cdecl("HSAppleScriptEnabled")
func HSAppleScriptEnabled() -> Bool {
    if let env = environmentGetGlobalOrNil() {
        return env.settings.bool(forKey: HSAppleScriptEnabledKey)
    }
    return UserDefaults.standard.bool(forKey: HSAppleScriptEnabledKey)
}

@_cdecl("HSAppleScriptSetEnabled")
func HSAppleScriptSetEnabled(_ enabled: Bool) {
    if let env = environmentGetGlobalOrNil() {
        env.settings.set(enabled, forKey: HSAppleScriptEnabledKey)
        env.telemetry.recordLog(
            level: "info",
            message: "permission.applescript.set",
            attributes: [
                TelemetrySemanticConventions.Attribute.Permission.name: "applescript",
                TelemetrySemanticConventions.Attribute.Permission.enabled: enabled,
            ],
            timestamp: nil
        )
    } else {
        UserDefaults.standard.set(enabled, forKey: HSAppleScriptEnabledKey)
    }
}

// MARK: - Run Lua string

private func HSAppleScriptRunString(_ command: String, errorFor cmd: NSScriptCommand) -> String {
    let L = lua_getCurrentState()!
    _lua_stackguard_entry(L)

    lua_getglobal(L, "hs")
    if lua_getfield(L, -1, "__appleScriptRunString") != LUA_TFUNCTION {
        let typeName = String(cString: lua_typename(L, lua_type(L, -1)))
        os_log(.error, "hs.__appleScriptRunString is not a function; found %{public}s", typeName)
        cmd.scriptErrorNumber = -50
        cmd.scriptErrorString = "hs.__appleScriptRunString is not a function"
        lua_pop(L, 2) // "hs", and whatever "hs.__appleScriptRunString" is
        _lua_stackguard_exit(L)
        return "Error"
    }

    lua_pushstring(L, command)
    if luaTelemetryPCall(
        L,
        nargs: 1,
        nresults: 2,
        callbackName: "applescript.bridge.executeLua",
        attributes: [TelemetrySemanticConventions.Attribute.Lua.commandLength: command.count]
    ) != LUA_OK {
        let errMsg: String
        if let cStr = lua_tostring(L, -1) {
            errMsg = "hs.__appleScriptRunString callback error:\(String(cString: cStr))"
        } else {
            errMsg = "hs.__appleScriptRunString callback error: (unknown)"
        }
        os_log(.error, "%{public}s", errMsg)
        cmd.scriptErrorNumber = -50
        cmd.scriptErrorString = errMsg
        lua_pop(L, 2) // "hs", and error message
        _lua_stackguard_exit(L)
        return "Error"
    }

    let str = lua_tovalue(L, at: -1) as? String ?? ""
    let good = lua_toboolean(L, -2) != 0
    lua_pop(L, 3) // "hs" and two results from hs.__appleScriptRunString: boolean, string
    if good {
        _lua_stackguard_exit(L)
        return str
    } else {
        cmd.scriptErrorNumber = -50
        cmd.scriptErrorString = str
        _lua_stackguard_exit(L)
        return "Error"
    }
}

// MARK: - NSScriptCommand subclass

/// Handles the AppleScript `execute` verb for Cosmic Hammer.
/// The class name `executeLua` must match the `cocoa class` attribute in
/// `Cosmic Hammer.sdef`, so it is exposed to the Objective-C runtime under that
/// exact name via `@objc(executeLua)`.
@objc(executeLua)
final class executeLua: NSScriptCommand {

    override func performDefaultImplementation() -> Any? {
        let args = evaluatedArguments ?? [:]
        guard args.count > 0, let stringToExecute = args[""] as? String else {
            scriptErrorNumber = -50
            scriptErrorString =
                "A Parameter is expected for the verb 'execute'. " +
                "You need to tell Cosmic Hammer what Lua code you want to execute."
            return "Error"
        }

        if HSAppleScriptEnabled() {
            return HSAppleScriptRunString(stringToExecute, errorFor: self)
        } else {
            scriptErrorNumber = -50
            scriptErrorString = appleScriptErrorMessage
            return "Error"
        }
    }
}
