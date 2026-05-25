import Foundation
import Cocoa
import WebKit
import LuaSkin

private let USERDATA_UCC_TAG = "hs.webview.usercontent"
private var refTable: Int32 = 0

// MARK: - HSUserContentController

private class HSUserContentController: WKUserContentController, WKScriptMessageHandler {
    var name: String = ""
    var udRef: Int32 = LUA_NOREF
    var userContentCallback: Int32 = LUA_NOREF

    convenience init(name: String) {
        self.init()
        self.name = name
        self.udRef = LUA_NOREF
        self.userContentCallback = LUA_NOREF
        self.add(self, name: name)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == name && userContentCallback != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: userContentCallback)
            skin.pushNSObject(message)
            skin.protectedCallAndError("hs.webview.usercontent callback", nargs: 1, nresults: 0)
            _lua_stackguard_exit(skin.l)
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
private func ucc_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let theName = skin.toNSObject(atIndex: 1) as! String
    let newUCC = HSUserContentController(name: theName)
    skin.pushNSObject(newUCC)
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
private func ucc_inject(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_UCC_TAG, LS_TTABLE, LS_TBREAK)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ucc = Unmanaged<HSUserContentController>.fromOpaque(ptr.pointee!).takeUnretainedValue()

    let userScript = skin.luaObject(at: 2, toClass: "WKUserScript") as? WKUserScript
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
private func ucc_userScripts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_UCC_TAG, LS_TBREAK)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ucc = Unmanaged<HSUserContentController>.fromOpaque(ptr.pointee!).takeUnretainedValue()

    skin.pushNSObject(ucc.userScripts as NSArray)
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
private func ucc_removeAllScripts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_UCC_TAG, LS_TBREAK)
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
private func ucc_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_UCC_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ucc = Unmanaged<HSUserContentController>.fromOpaque(ptr.pointee!).takeUnretainedValue()

    ucc.userContentCallback = skin.luaUnref(refTable, ref: ucc.userContentCallback)

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        ucc.userContentCallback = skin.luaRef(refTable)
    }

    lua_pushvalue(L, 1)
    return 1
}

// MARK: - NSObject <-> Lua converters

private func HSUserContentController_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ucc = obj as! HSUserContentController

    if ucc.udRef == LUA_NOREF {
        let uccPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        uccPtr.pointee = Unmanaged.passRetained(ucc).toOpaque()
        luaL_getmetatable(L, USERDATA_UCC_TAG)
        lua_setmetatable(L, -2)
        ucc.udRef = skin.luaRef(refTable)
    }

    skin.pushLuaRef(refTable, ref: ucc.udRef)
    return 1
}

private func WKUserScript_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
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
    skin.pushNSObject(script.source as NSString)
    lua_setfield(L, -2, "source")
    return 1
}

private func WKScriptMessage_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let message = obj as! WKScriptMessage

    lua_newtable(L)
    skin.pushNSObject(message.body as? NSObject)
    lua_setfield(L, -2, "body")
    skin.pushNSObject(message.frameInfo)
    lua_setfield(L, -2, "frameInfo")
    skin.pushNSObject(message.name as NSString)
    lua_setfield(L, -2, "name")
    skin.pushNSObject(message.webView?.window as? NSObject)
    lua_setfield(L, -2, "webView")
    return 1
}

private func table_toWKUserScript(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)

    if lua_type(L, idx) == LUA_TTABLE {
        var mainFrame: Bool = true
        var source: String?
        var injectionTime: WKUserScriptInjectionTime = .atDocumentStart

        if lua_getfield(L, idx, "mainFrame") == LUA_TBOOLEAN {
            mainFrame = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, idx, "source") == LUA_TSTRING {
            source = skin.toNSObject(atIndex: -1) as? String
            lua_pop(L, 1)
        } else {
            lua_pop(L, 1)
            skin.logWarn("source is required and must be a string")
            return nil
        }

        if lua_getfield(L, idx, "injectionTime") == LUA_TSTRING {
            let label = skin.toNSObject(atIndex: -1) as? String ?? ""
            if label == "documentStart" {
                injectionTime = .atDocumentStart
            } else if label == "documentEnd" {
                injectionTime = .atDocumentEnd
            } else {
                skin.logWarn("invalid injectionTime, \(label), defaulting to `documentStart`")
            }
        }
        lua_pop(L, 1)

        let script = WKUserScript(source: source!,
                                  injectionTime: injectionTime,
                                  forMainFrameOnly: mainFrame)
        return script
    } else {
        skin.logWarn(String(format: "%s:invalid type for userscript, expected table, found %s",
                            USERDATA_UCC_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
        return nil
    }
}

// MARK: - Lua infrastructure support

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

private func userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr1 = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    let ptr2 = luaL_checkudata(L, 2, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let raw1 = ptr1.pointee, let raw2 = ptr2.pointee {
        let ucc1 = Unmanaged<HSUserContentController>.fromOpaque(raw1).takeUnretainedValue()
        let ucc2 = Unmanaged<HSUserContentController>.fromOpaque(raw2).takeUnretainedValue()
        lua_pushboolean(L, ucc1.udRef == ucc2.udRef ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let ptr = luaL_checkudata(L, 1, USERDATA_UCC_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)

    if let rawPtr = ptr.pointee {
        let ucc = Unmanaged<HSUserContentController>.fromOpaque(rawPtr).takeRetainedValue()
        ucc.udRef = skin.luaUnref(refTable, ref: ucc.udRef)
        ucc.removeAllUserScripts()
        ucc.removeScriptMessageHandler(forName: ucc.name)
        ptr.pointee = nil
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("injectScript"), func: ucc_inject),
    luaL_Reg(name: strdup("userScripts"), func: ucc_userScripts),
    luaL_Reg(name: strdup("removeAllScripts"), func: ucc_removeAllScripts),
    luaL_Reg(name: strdup("setCallback"), func: ucc_setCallback),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"), func: userdata_eq),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: ucc_new),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwebviewusercontent")
public func luaopen_hs_libwebviewusercontent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    refTable = skin.registerLibrary(withObject: USERDATA_UCC_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(HSUserContentController_toLua, forClass: "HSUserContentController")
    skin.registerPushNSHelper(WKUserScript_toLua, forClass: "WKUserScript")
    skin.registerPushNSHelper(WKScriptMessage_toLua, forClass: "WKScriptMessage")

    skin.registerLuaObjectHelper(table_toWKUserScript, forClass: "WKUserScript")

    return 1
}
