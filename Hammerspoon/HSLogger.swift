//
//  HSLogger.swift
//  Hammerspoon
//
//  Created by Chris Jones on 22/01/2018.
//  Copyright © 2018 Hammerspoon. All rights reserved.
//

import Foundation
import LuaSkin

/// Convenience wrapper matching the ObjC HSNSLOG macro.
func HSNSLOG(_ format: String, _ args: CVarArg...) {
    NSLog(format, args)
}

@objcMembers
class HSLogger: NSObject, LuaSkinDelegate {

    private var _L: OpaquePointer?

    var L: OpaquePointer? {
        return _L
    }

    init(lua L: OpaquePointer?) {
        _L = L
        super.init()
    }

    func setLuaState(_ L: OpaquePointer?) {
        _L = L
    }

    // VERY IMPORTANT NOTE: DO NOT CALL HSNSLOG() IN THIS METHOD.
    func logForLuaSkin(atLevel level: Int32, withMessage theMessage: String) {
        // If we haven't been given a lua_State object yet, log locally
        guard let L = _L else {
            logBreadcrumb("%@", theMessage)
            return
        }

        // Send logs to the appropriate location, depending on their level
        // Note that hs.handleLogMessage also does this kind of filtering. We are special casing
        // here for LS_LOG_BREADCRUMB to entirely bypass calling into Lua (because such logs don't
        // need to be shown to the user, just stored in our crashlog in case we crash).
        switch level {
        case LS_LOG_BREADCRUMB:
            logBreadcrumb("%@", theMessage)

        case LS_LOG_ERROR, LS_LOG_WARN, LS_LOG_INFO:
            // Capture anything that isn't verbose/debug logging, in Sentry.
            // These intentionally fall through to the default Lua dispatch.
            logBreadcrumb("%@", theMessage)
            fallthrough

        default:
            lua_getglobal(L, "hs")
            lua_getfield(L, -1, "handleLogMessage")
            lua_remove(L, -2)
            lua_pushinteger(L, lua_Integer(level))
            lua_pushstring(L, theMessage)
            let errState = lua_pcall(L, 2, 0, 0)
            if errState != LUA_OK {
                let stateLabels = ["OK", "YIELD", "ERRRUN", "ERRSYNTAX", "ERRMEM", "ERRGCMM", "ERRERR"]
                let errString = String(cString: luaL_tolstring(L, -1, nil))
                logBreadcrumb("logForLuaSkin: error, state %@: %@",
                              stateLabels[Int(errState)],
                              errString)
                lua_pop(L, 2) // lua_pcall error + converted string from luaL_tolstring
            }
        }
    }

    func handleCatastrophe(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Hammerspoon critical error."
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .critical
        alert.runModal()
        exit(1)
    }

    func logBreadcrumb(_ format: String, _ args: CVarArg...) {
        let message = String(format: format, arguments: args)
        NSLog("BREADCRUMB: %@", message)
    }
}
