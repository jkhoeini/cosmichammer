//
//  HSLogger.swift
//  Cosmic Hammer
//
//  Created by Mohammad Sadegh Khoeini on 15/05/2026.
//  Copyright © 2026 Cosmic Hammer. All rights reserved.
//

import Foundation
import AppKit
import CLua
import os.log

// Log level constants (formerly from LuaSkin's Skin.h)
private let LS_LOG_ERROR: Int32      = 1
private let LS_LOG_WARN: Int32       = 2
private let LS_LOG_INFO: Int32       = 3
private let LS_LOG_DEBUG: Int32      = 4
private let LS_LOG_VERBOSE: Int32    = 5
private let LS_LOG_BREADCRUMB: Int32 = 6

@objc(HSLogger)
class HSLogger: NSObject {

    private var _L: UnsafeMutablePointer<lua_State>?

    var L: UnsafeMutablePointer<lua_State>? { return _L }

    init(lua L: UnsafeMutablePointer<lua_State>?) {
        self._L = L
        super.init()
    }

    func setLuaState(_ L: UnsafeMutablePointer<lua_State>?) {
        _L = L
    }

    // VERY IMPORTANT NOTE: DO NOT CALL NSLog (i.e. logBreadcrumb) IN THIS METHOD
    // indirectly — the breadcrumb path calls NSLog directly.
    func logForLuaSkin(atLevel level: Int32, withMessage theMessage: String) {
        guard let L = _L else {
            logBreadcrumb(theMessage)
            return
        }

        switch level {
        case Int32(LS_LOG_BREADCRUMB):
            logBreadcrumb(theMessage)

        case Int32(LS_LOG_ERROR), Int32(LS_LOG_WARN), Int32(LS_LOG_INFO):
            logBreadcrumb(theMessage)
            fallthrough

        default:
            lua_getglobal(L, "hs")
            lua_getfield(L, -1, "handleLogMessage")
            lua_remove(L, -2)
            lua_pushinteger(L, lua_Integer(level))
            theMessage.withCString { lua_pushstring(L, $0) }
            let errState = lua_pcall(L, 2, 0, 0)
            if errState != LUA_OK {
                let stateLabels = ["OK", "YIELD", "ERRRUN", "ERRSYNTAX", "ERRMEM", "ERRGCMM", "ERRERR"]
                let label = (errState >= 0 && Int(errState) < stateLabels.count)
                    ? stateLabels[Int(errState)] : "UNKNOWN"
                let errStr = String(cString: luaL_tolstring(L, -1, nil))
                logBreadcrumb("logForLuaSkin: error, state \(label): \(errStr)")
                lua_pop(L, 2)  // lua_pcall error + converted string from luaL_tolstring
            }
        }
    }

    func handleCatastrophe(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Cosmic Hammer critical error."
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .critical
        alert.runModal()
        exit(1)
    }

    /// Non-variadic breadcrumb logger. Swift cannot bridge ObjC-style variadic methods,
    /// so call sites pass a pre-formatted string directly.
    func logBreadcrumb(_ message: String) {
        os_log(.default, "BREADCRUMB: %{public}s", message)
    }
}

// MARK: - C factory functions for ObjC callers (avoids -Swift.h dependency)

@_cdecl("HSLoggerCreateWithLua")
func HSLoggerCreateWithLua(_ L: UnsafeMutablePointer<lua_State>?) -> AnyObject {
    return HSLogger(lua: L)
}

@_cdecl("HSLoggerSetLuaState")
func HSLoggerSetLuaState(_ logger: AnyObject, _ L: UnsafeMutablePointer<lua_State>?) {
    (logger as? HSLogger)?.setLuaState(L)
}
