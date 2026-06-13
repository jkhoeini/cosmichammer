import Foundation
import CLua
import Lua
import Cocoa
import WebKit
import os.log

private let USERDATA_UCC_TAG = "hs.webview.usercontent"

// MARK: - HSUserContentController

private class HSUserContentController: WKUserContentController, WKScriptMessageHandler {
    var name: String = ""
    var udRef: LuaValue?
    var userContentCallback: LuaValue?
    var generation: UInt64 = 0

    convenience init(name: String) {
        self.init()
        self.name = name
        self.udRef = nil
        self.userContentCallback = nil
        self.add(self, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard lua_isStateGenerationValid(generation) else { return }
        if message.name == name, let cb = userContentCallback {
            let L = lua_getCurrentState()!
            cb.push(onto: L)
            wv_pushAny(L, message)
            if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

// MARK: - The module methods and constructor

/// hs.webview.usercontent.new(name) -> usercontentControllerObject
/// Constructor
/// Create a new user content controller for a webview and create the message port with the specified name for JavaScript message support.
///
/// Parameters:
///  * name - the name of the message port which JavaScript in the webview can use to post messages to Cosmic Hammer.
///
/// Returns:
///  * the usercontentControllerObject
///
/// Notes:
///  * This object should be provided as the final argument to the `hs.webview.new` constructor in order to tie the webview to this content controller.  All new windows which are created from this parent webview will also use this controller.
///  * See `hs.webview.usercontent:setCallback` for more information about the message port.
private func ucc_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)

    let theName = lua_tovalue(L, at: 1) as! String
    let newUCC = HSUserContentController(name: theName)
    HSUserContentController_toLua(L, newUCC)
    return 1
}

/// hs.webview.usercontent:injectScript(scriptTable) -> usercontentControllerObject
/// Method
/// Add a script to be injected into webviews which use this user content controller.
///
/// Parameters:
///  * scriptTable - a table containing the following keys which define the script and how it is to be injected:
///    * source        - the javascript which is injected (required)
///    * mainFrame     - a boolean value which indicates whether this script is only injected for the main webview frame (true) or for all frames within the webview (false).  Defaults to true.
///    * injectionTime - a string which indicates whether the script is injected at "documentStart" or "documentEnd". Defaults to "documentStart".
///
/// Returns:
///  * the usercontentControllerObject or nil if the script table was malformed in some way.
private func ucc_inject(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_UCC_TAG)

    luaL_checktype(L, 2, LUA_TTABLE)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ucc = Unmanaged<HSUserContentController>.fromOpaque(ptr.pointee!).takeUnretainedValue()

    let userScript = table_toWKUserScript(L, 2) as? WKUserScript
    if let userScript = userScript {
        ucc.addUserScript(userScript)
        lua_pushvalue(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.webview.usercontent:userScripts() -> array
/// Method
/// Get a table containing all of the currently defined injection scripts for this user content controller
///
/// Parameters:
///  * None
///
/// Returns:
///  * An array of injected user scripts.  Each entry in the array will be a table containing the following keys:
///    * source        - the javascript which is injected
///    * mainFrame     - a boolean value which indicates whether this script is only injected for the main webview frame (true) or for all frames within the webview (false)
///    * injectionTime - a string which indicates whether the script is injected at "documentStart" or "documentEnd".
///
/// Notes:
///  * Because the WKUserContentController class only allows for removing all scripts, you can use this method to generate a list of all scripts, modify it, and then use it in a loop to reapply the scripts if you need to remove just a few scripts.
private func ucc_userScripts(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_UCC_TAG)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ucc = Unmanaged<HSUserContentController>.fromOpaque(ptr.pointee!).takeUnretainedValue()

    lua_createtable(L, Int32(ucc.userScripts.count), 0)
    for script in ucc.userScripts {
        wv_pushAny(L, script)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

/// hs.webview.usercontent:removeAllScripts() -> usercontentControllerObject
/// Method
/// Removes all user scripts currently defined for this user content controller.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the usercontentControllerObject
/// Notes:
///  * The WKUserContentController class only allows for removing all scripts.  If you need finer control, make a copy of the current scripts with `hs.webview.usercontent.userScripts()` first so you can recreate the scripts you want to keep.
private func ucc_removeAllScripts(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_UCC_TAG)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ucc = Unmanaged<HSUserContentController>.fromOpaque(ptr.pointee!).takeUnretainedValue()

    ucc.removeAllUserScripts()
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview.usercontent:setCallback(fn) -> usercontentControllerObject
/// Method
/// Set or remove the callback function to handle message posted to this user content's message port.
///
/// Parameters:
///  * fn - The function which should receive messages posted to this user content's message port.  Specify an explicit nil to disable the callback.  The function should take one argument which will be the message posted and any returned value will be ignored.
///
/// Returns:
///  * the usercontentControllerObject
///
/// Notes:
///  * Within your (injected or served) JavaScript, you can post messages via the message port created with the constructor like this:
///
///      try {
///          webkit.messageHandlers.*name*>.postMessage(*message-object*);
///      } catch(err) {
///          console.log('The controller does not exist yet');
///      }
///
///  * Where *name* matches the name specified in the constructor and *message-object* is the object to post to the function.  This object can be a number, string, date, array, dictionary(table), or nil.
private func ucc_setCallback(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, USERDATA_UCC_TAG)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ucc = Unmanaged<HSUserContentController>.fromOpaque(ptr.pointee!).takeUnretainedValue()

    ucc.userContentCallback = nil

    if lua_type(L, 2) == LUA_TFUNCTION {
        ucc.userContentCallback = L.ref(index: 2)
        ucc.generation = lua_currentStateGeneration()
    }

    lua_pushvalue(L, 1)
    return 1
}

// MARK: - NSObject <-> Lua converters

private func HSUserContentController_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let ucc = obj as! HSUserContentController

    if ucc.udRef == nil {
        let uccPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        uccPtr.pointee = Unmanaged.passRetained(ucc).toOpaque()
        luaL_getmetatable(L, USERDATA_UCC_TAG)
        lua_setmetatable(L, -2)
        ucc.udRef = L.ref(index: -1)
    }

    ucc.udRef!.push(onto: L)
    return 1
}

func wv_WKUserScript_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let script = obj as! WKUserScript

    lua_newtable(L)
    lua_pushboolean(L, script.isForMainFrameOnly ? 1 : 0)
    lua_setfield(L, -2, "forMainFrameOnly")
    switch script.injectionTime {
    case .atDocumentStart: lua_pushstring(L, "documentStart")
    case .atDocumentEnd:   lua_pushstring(L, "documentEnd")
    @unknown default:      lua_pushstring(L, "unknown")
    }
    lua_setfield(L, -2, "injectionTime")
    lua_pushany(L, script.source as NSString)
    lua_setfield(L, -2, "source")
    return 1
}

func wv_WKScriptMessage_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let message = obj as! WKScriptMessage

    lua_newtable(L)
    wv_pushAny(L, message.body)
    lua_setfield(L, -2, "body")
    wv_pushAny(L, message.frameInfo)
    lua_setfield(L, -2, "frameInfo")
    lua_pushany(L, message.name as NSString)
    lua_setfield(L, -2, "name")
    wv_pushAny(L, message.webView?.window as? HSWebViewWindow)
    lua_setfield(L, -2, "webView")
    return 1
}

private func table_toWKUserScript(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {

    if lua_type(L, idx) == LUA_TTABLE {
        var mainFrame: Bool = true
        var source: String?
        var injectionTime: WKUserScriptInjectionTime = .atDocumentStart

        if lua_getfield(L, idx, "mainFrame") == LUA_TBOOLEAN {
            mainFrame = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "source") == LUA_TSTRING {
            source = lua_tovalue(L, at: -1) as? String
            lua_pop(L, 1)
        } else {
            lua_pop(L, 1)
            os_log(.info, "%{public}s", "source is required and must be a string")
            return nil
        }

        if lua_getfield(L, idx, "injectionTime") == LUA_TSTRING {
            let label = lua_tovalue(L, at: -1) as? String ?? ""
            if label == "documentStart" {
                injectionTime = .atDocumentStart
            } else if label == "documentEnd" {
                injectionTime = .atDocumentEnd
            } else {
                os_log(.info, "%{public}s", "invalid injectionTime, \(label), defaulting to `documentStart`")
            }
        }
        lua_pop(L, 1)

        let script = WKUserScript(source: source!,
                                  injectionTime: injectionTime,
                                  forMainFrameOnly: mainFrame)
        return script
    } else {
        os_log(.info, "%{public}s", String(format: "%s:invalid type for userscript, expected table, found %s",
                            USERDATA_UCC_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
        return nil
    }
}

// MARK: - Lua infrastructure support

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    var name: String
    if let rawPtr = ptr.pointee {
        let ucc = Unmanaged<HSUserContentController>.fromOpaque(rawPtr).takeUnretainedValue()
        name = ucc.name.isEmpty ? "" : ucc.name
    } else {
        name = "<deleted>"
    }
    let str = "\(USERDATA_UCC_TAG): \(name) (\(lua_topointer(L, 1)!))"
    lua_pushstring(L, str)
    return 1
}

private func userdata_eq(_ L: LuaState) throws -> CInt {
    let ptr1 = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ptr2 = luaL_checkudata(L, 2, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let raw1 = ptr1.pointee, let raw2 = ptr2.pointee {
        let ucc1 = Unmanaged<HSUserContentController>.fromOpaque(raw1).takeUnretainedValue()
        let ucc2 = Unmanaged<HSUserContentController>.fromOpaque(raw2).takeUnretainedValue()
        lua_pushboolean(L, ucc1 === ucc2 ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: LuaState) throws -> CInt {
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)

    if let rawPtr = ptr.pointee {
        let ucc = Unmanaged<HSUserContentController>.fromOpaque(rawPtr).takeRetainedValue()
        ucc.udRef = nil
        ucc.userContentCallback = nil
        ucc.removeAllUserScripts()
        ucc.removeScriptMessageHandler(forName: ucc.name)
        ptr.pointee = nil
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

@_cdecl("luaopen_hs_libwebviewusercontent")
public func luaopen_hs_libwebviewusercontent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_UCC_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(ucc_inject)
        lua_setfield(L, -2, "injectScript")
        L.push(ucc_userScripts)
        lua_setfield(L, -2, "userScripts")
        L.push(ucc_removeAllScripts)
        lua_setfield(L, -2, "removeAllScripts")
        L.push(ucc_setCallback)
        lua_setfield(L, -2, "setCallback")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(userdata_eq)
        lua_setfield(L, -2, "__eq")
        L.push(userdata_gc)
        lua_setfield(L, -2, "__gc")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(ucc_new)
        lua_setfield(L, -2, "new")
    }
}
