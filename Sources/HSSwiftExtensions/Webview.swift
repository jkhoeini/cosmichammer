import Foundation
import Cocoa
import WebKit
import LuaSkin

let wv_USERDATA_TAG = "hs.webview"
private let USERDATA_UCC_TAG = "hs.webview.usercontent"
private let USERDATA_DS_TAG = "hs.webview.datastore"
private let USERDATA_TB_TAG = "hs.webview.toolbar"

var wv_refTable: Int32 = 0
var wv_ProcessPool: WKProcessPool?
var wv_delayTimers: NSMapTable<HSWebViewView, Timer>?

func wv_RectWithFlippedYCoordinate(_ theRect: NSRect) -> NSRect {
    return NSMakeRect(theRect.origin.x,
                      NSScreen.screens[0].frame.size.height - theRect.origin.y - theRect.size.height,
                      theRect.size.width,
                      theRect.size.height)
}

// forward declarations handled by Swift naturally

func wv_delayUntilViewStopsLoading(_ theView: HSWebViewView, block: @escaping () -> Void) {
    if wv_delayTimers == nil { wv_delayTimers = NSMapTable<HSWebViewView, Timer>.strongToWeakObjects() }

    if let existingTimer = wv_delayTimers?.object(forKey: theView) {
        existingTimer.invalidate()
        wv_delayTimers?.removeObject(forKey: theView)
    }

    let newDelay = Timer(timeInterval: 0.001, repeats: true) { timer in
        if timer.isValid {
            if !theView.isLoading {
                theView.stopLoading()
                wv_delayTimers?.removeObject(forKey: theView)
                timer.invalidate()
                block()
            }
        }
    }

    wv_delayTimers?.setObject(newDelay, forKey: theView)
    newDelay.fireDate = Date(timeIntervalSinceNow: 0)
    RunLoop.current.add(newDelay, forMode: .common)
}


// HSWebViewWindow -> WebviewWindow.swift
// HSWebViewView -> WebviewView.swift

// MARK: - WKWebView Related Methods

/// hs.webview:privateBrowsing() -> boolean
/// Method
/// Returns whether or not the webview browser is set up for private browsing (i.e. uses a non-persistent datastore)
///
/// Parameters:
///  * None
///
/// Returns:
///  * a boolean value indicating whether or not the datastore is non-persistent.
func webview_privateBrowsing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = Unmanaged<HSWebViewWindow>.fromOpaque(
        luaL_checkudata(L, 1, wv_USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee!
    ).takeUnretainedValue()
    let theView = theWindow.contentView as! HSWebViewView
    let theConfiguration = theView.configuration
    lua_pushboolean(L, !theConfiguration.websiteDataStore.isPersistent ? 1 : 0)
    return 1
}

// Helper to get HSWebViewWindow from userdata at stack index
func wv_getWindowFromUD(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSWebViewWindow {
    let ptr = luaL_checkudata(L, idx, wv_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    return Unmanaged<HSWebViewWindow>.fromOpaque(ptr.pointee!).takeUnretainedValue()
}

/// hs.webview:children() -> array
/// Method
/// Returns an array of webview objects which have been opened as children of this webview.
func webview_children(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    lua_newtable(L)
    for child in theWindow.children {
        skin.pushNSObject(child as? HSWebViewWindow)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

/// hs.webview:parent() -> webviewObject | nil
/// Method
/// Get the parent webview object for the calling webview object, or nil if the webview has no parent.
func webview_parent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    if let parent = theWindow.parentWebView { skin.pushNSObject(parent) } else { lua_pushnil(L) }
    return 1
}

/// hs.webview:url([URL]) -> webviewObject, navigationIdentifier | url
/// Method
/// Get or set the URL to render for the webview.
func webview_url(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TSTRING | LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        skin.pushNSObject(theView.url?.absoluteString as NSString?)
        return 1
    } else {
        let theNSURL = skin.luaObject(at: 2, toClass: "NSURLRequest") as? URLRequest
        if let theNSURL = theNSURL {
            wv_delayUntilViewStopsLoading(theView) {
                let navID = theView.load(theNSURL)
                theView.trackingID = navID
            }
            lua_pushvalue(L, 1)
            return 1
        } else {
            return luaL_error(L, "Invalid URL type.  String or table expected.")
        }
    }
}

/// hs.webview:userAgent([agent]) -> webviewObject | current value
/// Method
/// Get or set the webview's user agent string
func webview_userAgent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        skin.pushNSObject(theView.customUserAgent as NSString?)
    } else {
        theView.customUserAgent = skin.toNSObject(atIndex: 2) as? String
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:certificateChain() -> table | nil
/// Method
/// Returns the certificate chain for the most recently committed navigation of the webview.
func webview_certificateChain(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if let certificateChain = theView.serverTrust {
        lua_newtable(L)
        for i in 0..<SecTrustGetCertificateCount(certificateChain) {
            wv_SecCertificateRef_toLua(L, SecTrustGetCertificateAtIndex(certificateChain, i))
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.webview:title() -> title
/// Method
/// Get the title of the page displayed in the webview.
func webview_title(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    skin.pushNSObject(theView.title as NSString?)
    return 1
}

/// hs.webview:navigationID() -> navigationID
/// Method
/// Get the most recent navigation identifier for the specified webview.
func webview_navigationID(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    skin.pushNSObject(theView.trackingID)
    return 1
}

/// hs.webview:loading() -> boolean
/// Method
/// Returns a boolean value indicating whether or not the webview is still loading content.
func webview_loading(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    lua_pushboolean(L, theView.isLoading ? 1 : 0)
    return 1
}

/// hs.webview:stopLoading() -> webviewObject
/// Method
/// Stop loading additional content for the webview.
func webview_stopLoading(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    if !theView.isLoading { theView.stopLoading() }
    lua_settop(L, 1)
    return 1
}

/// hs.webview:estimatedProgress() -> number
/// Method
/// Returns the estimated percentage of expected content that has been loaded.
func webview_estimatedProgress(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    lua_pushnumber(L, theView.estimatedProgress)
    return 1
}

/// hs.webview:isOnlySecureContent() -> bool
/// Method
/// Returns a boolean value indicating if all content current displayed in the webview was loaded over securely encrypted connections.
func webview_isOnlySecureContent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    lua_pushboolean(L, theView.hasOnlySecureContent ? 1 : 0)
    return 1
}

/// hs.webview:goForward() -> webviewObject
/// Method
/// Move to the next page in the webview's history, if possible.
func webview_goForward(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    theView.goForward()
    lua_settop(L, 1)
    return 1
}

/// hs.webview:goBack() -> webviewObject
/// Method
/// Move to the previous page in the webview's history, if possible.
func webview_goBack(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    theView.goBack()
    lua_settop(L, 1)
    return 1
}

/// hs.webview:reload([validate]) -> webviewObject, navigationIdentifier
/// Method
/// Reload the page in the webview, optionally performing end-to-end revalidation using cache-validating conditionals if possible.
func webview_reload(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    let validate = (lua_type(L, 2) == LUA_TBOOLEAN) ? (lua_toboolean(L, 2) != 0) : false

    wv_delayUntilViewStopsLoading(theView) {
        let navID = validate ? theView.reloadFromOrigin() : theView.reload()
        theView.trackingID = navID
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:transparent([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview background is transparent.
func webview_transparent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, !theWindow.isOpaque ? 1 : 0)
    } else {
        let transparent = lua_toboolean(L, 2) != 0
        theWindow.isOpaque = !transparent
        (theWindow.contentView as? HSWebViewView)?.setValue(NSNumber(value: transparent), forKey: "drawsTransparentBackground")
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:allowMagnificationGestures([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview will respond to magnification gestures from a trackpad or magic mouse.
func webview_allowMagnificationGestures(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theView.allowsMagnification ? 1 : 0)
    } else {
        theView.allowsMagnification = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:allowNewWindows([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview allows new windows to be opened from it by any method.
func webview_allowNewWindows(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theView.allowNewWindows ? 1 : 0)
    } else {
        theView.allowNewWindows = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:examineInvalidCertificates([flag]) -> webviewObject | current value
/// Method
/// Get or set whether or not invalid SSL server certificates that are approved by the ssl callback function are accepted as valid for browsing with the webview.
func webview_examineInvalidCertificates(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theView.examineInvalidCertificates ? 1 : 0)
    } else {
        theView.examineInvalidCertificates = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:allowNavigationGestures([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview will respond to the navigation gestures from a trackpad or magic mouse.
func webview_allowNavigationGestures(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theView.allowsBackForwardNavigationGestures ? 1 : 0)
    } else {
        theView.allowsBackForwardNavigationGestures = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:magnification([value]) -> webviewObject | current value
/// Method
/// Get or set the webviews current magnification level.
func webview_magnification(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushnumber(L, lua_Number(theView.magnification))
    } else {
        luaL_checktype(L, 2, LUA_TNUMBER)
        theView.setMagnification(CGFloat(lua_tonumber(L, 2)), centeredAt: .zero)
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:html(html,[baseURL]) -> webviewObject, navigationIdentifier
/// Method
/// Render the given HTML in the webview with an optional base URL for relative links.
func webview_html(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    luaL_tolstring(L, 2, nil)
    let theHTML = skin.toNSObject(atIndex: -1) as? String ?? ""
    lua_pop(L, 1)
    let theBaseURL = (lua_type(L, 3) == LUA_TSTRING) ? skin.toNSObject(atIndex: 3) as? String : nil

    wv_delayUntilViewStopsLoading(theView) {
        let navID = theView.loadHTMLString(theHTML, baseURL: theBaseURL != nil ? URL(string: theBaseURL!) : nil)
        theView.trackingID = navID
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:navigationCallback(fn) -> webviewObject
/// Method
/// Sets a callback for tracking a webview's navigation process.
func webview_navigationCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.navigationCallback = skin.luaUnref(wv_refTable, ref: theView.navigationCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theView.navigationCallback = skin.luaRef(wv_refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:policyCallback(fn) -> webviewObject
/// Method
/// Sets a callback to approve or deny web navigation activity.
func webview_policyCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.policyCallback = skin.luaUnref(wv_refTable, ref: theView.policyCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theView.policyCallback = skin.luaRef(wv_refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:sslCallback(fn) -> webviewObject
/// Method
/// Sets a callback to examine an invalid SSL certificate and determine if an exception should be granted.
func webview_sslCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.sslCallback = skin.luaUnref(wv_refTable, ref: theView.sslCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theView.sslCallback = skin.luaRef(wv_refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:historyList() -> historyTable
/// Method
/// Returns the URL history for the current webview as an array.
func webview_historyList(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    skin.pushNSObject(theView.backForwardList)
    return 1
}

/// hs.webview:evaluateJavaScript(script, [callback]) -> webviewObject
/// Method
/// Execute JavaScript within the context of the current webview and optionally receive its result or error in a callback function.
func webview_evaluateJavaScript(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TSTRING, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    let javascript = skin.toNSObject(atIndex: 2) as! String
    var callbackRef: Int32 = LUA_NOREF
    if lua_type(L, 3) == LUA_TFUNCTION {
        lua_pushvalue(L, 3)
        callbackRef = skin.luaRef(wv_refTable)
    }

    let lsCanary = skin.createGCCanary()
    theView.evaluateJavaScript(javascript) { obj, error in
        if callbackRef != LUA_NOREF {
            DispatchQueue.main.async {
                let blockSkin = LuaSkin.skin(with: nil)
                if !blockSkin.check(lsCanary) { return }
                blockSkin.pushLuaRef(wv_refTable, ref: callbackRef)
                blockSkin.pushNSObject(obj as? NSObject)
                wv_NSError_toLua(blockSkin.l, error as NSError?)
                blockSkin.protectedCallAndError("hs.webview:evaluateJavaScript callback", nargs: 2, nresults: 0)
                blockSkin.luaUnref(wv_refTable, ref: callbackRef)
                var mutableCanary = lsCanary
                blockSkin.destroy(&mutableCanary)
            }
        }
    }

    lua_settop(L, 1)
    return 1
}

// MARK: - Window Related Methods

/// hs.webview:topLeft([point]) -> webviewObject | currentValue
/// Method
/// Get or set the top-left coordinate of the webview window
func webview_topLeft(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let oldFrame = wv_RectWithFlippedYCoordinate(theWindow.frame)

    if lua_gettop(L) == 1 {
        skin.pushNSPoint(oldFrame.origin)
    } else {
        let newCoord = skin.tableToPoint(at: 2)
        let newFrame = wv_RectWithFlippedYCoordinate(NSMakeRect(newCoord.x, newCoord.y, oldFrame.size.width, oldFrame.size.height))
        theWindow.setFrame(newFrame, display: true, animate: false)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:size([size]) -> webviewObject | currentValue
/// Method
/// Get or set the size of a webview window
func webview_size(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let oldFrame = theWindow.frame

    if lua_gettop(L) == 1 {
        skin.pushNSSize(oldFrame.size)
    } else {
        let newSize = skin.tableToSize(at: 2)
        let newFrame = NSMakeRect(oldFrame.origin.x, oldFrame.origin.y + oldFrame.size.height - newSize.height, newSize.width, newSize.height)
        theWindow.setFrame(newFrame, display: true, animate: false)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview.new(rect, [preferencesTable], [userContentController]) -> webviewObject
/// Constructor
/// Create a webviewObject and optionally modify its preferences.
func webview_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let windowRect = skin.tableToRect(at: 1)

    let theWindow = HSWebViewWindow(contentRect: windowRect, styleMask: .borderless, backing: .buffered, defer: true)

    theWindow.lsCanary = skin.createGCCanary()

    if wv_ProcessPool == nil { wv_ProcessPool = WKProcessPool() }

    let config = WKWebViewConfiguration()
    config.processPool = wv_ProcessPool!

    if lua_type(L, 2) == LUA_TTABLE {
        let myPreferences = WKPreferences()

        if lua_getfield(L, 2, "javaScriptEnabled") == LUA_TBOOLEAN {
            myPreferences.javaScriptEnabled = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "javaScriptCanOpenWindowsAutomatically") == LUA_TBOOLEAN {
            myPreferences.javaScriptCanOpenWindowsAutomatically = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "minimumFontSize") == LUA_TNUMBER {
            myPreferences.minimumFontSize = CGFloat(lua_tonumber(L, -1))
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "datastore") == LUA_TUSERDATA && luaL_testudata(L, -1, USERDATA_DS_TAG) != nil {
            config.websiteDataStore = skin.toNSObject(atIndex: -1) as! WKWebsiteDataStore
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "privateBrowsing") == LUA_TBOOLEAN && lua_toboolean(L, -1) != 0 {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "applicationName") == LUA_TSTRING {
            config.applicationNameForUserAgent = skin.toNSObject(atIndex: -1) as? String
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "allowsAirPlay") == LUA_TBOOLEAN {
            config.allowsAirPlayForMediaPlayback = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "developerExtrasEnabled") == LUA_TBOOLEAN {
            myPreferences.setValue(NSNumber(value: lua_toboolean(L, -1) != 0), forKey: "developerExtrasEnabled")
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "suppressesIncrementalRendering") == LUA_TBOOLEAN {
            config.suppressesIncrementalRendering = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        config.preferences = myPreferences
        if lua_type(L, 3) != LUA_TNONE {
            let uccPtr = luaL_checkudata(L, 3, USERDATA_UCC_TAG)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            config.userContentController = Unmanaged<WKUserContentController>.fromOpaque(uccPtr.pointee!).takeUnretainedValue()
        }
    } else {
        if lua_type(L, 2) != LUA_TNONE {
            let uccPtr = luaL_checkudata(L, 2, USERDATA_UCC_TAG)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            config.userContentController = Unmanaged<WKUserContentController>.fromOpaque(uccPtr.pointee!).takeUnretainedValue()
        }
    }

    let theView = HSWebViewView(frame: (theWindow.contentView! as NSView).bounds, configuration: config)
    theWindow.contentView = theView
    skin.pushNSObject(theWindow)
    return 1
}

/// hs.webview:show([fadeInTime]) -> webviewObject
/// Method
/// Displays the webview object
func webview_show(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let fadeTime: TimeInterval = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0

    if fadeTime > 0 { theWindow.fadeIn(fadeTime) } else { theWindow.makeKeyAndOrderFront(nil) }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:hide([fadeOutTime]) -> webviewObject
/// Method
/// Hides the webview object
func webview_hide(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let fadeTime: TimeInterval = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0

    if fadeTime > 0 { theWindow.fadeOut(fadeTime, andDelete: false, withState: L) } else { theWindow.orderOut(nil) }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:allowTextEntry([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview can accept keyboard for web form entry.
func webview_allowTextEntry(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theWindow.allowKeyboardEntry ? 1 : 0)
    } else {
        theWindow.allowKeyboardEntry = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:deleteOnClose([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview should delete itself when its window is closed.
func webview_deleteOnClose(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theWindow.deleteOnClose ? 1 : 0)
    } else {
        theWindow.deleteOnClose = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:darkMode([state]) -> bool
/// Method
/// Set or display whether or not the `hs.webview` window should display in dark mode.
func webview_darkMode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theWindow.darkMode ? 1 : 0)
    } else {
        theWindow.darkMode = lua_toboolean(L, 2) != 0
        theWindow.appearance = NSAppearance(named: theWindow.darkMode ? .vibrantDark : .vibrantLight)
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:closeOnEscape([flag]) -> webviewObject | current value
/// Method
/// If the webview is closable, this will get or set whether or not the Escape key is allowed to close the webview window.
func webview_closeOnEscape(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theWindow.closeOnEscape ? 1 : 0)
    } else {
        theWindow.closeOnEscape = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:hswindow() -> hs.window object
/// Method
/// Returns an hs.window object for the webview so that you can use hs.window methods on it.
func webview_hswindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    let windowID = CGWindowID(theWindow.windowNumber)
    skin.requireModule("hs.window")
    lua_getfield(L, -1, "windowForID")
    lua_pushinteger(L, lua_Integer(windowID))
    lua_call(L, 1, 1)
    return 1
}

/// hs.webview:isVisible() -> boolean
/// Method
/// Checks to see if a webview window is visible or not.
func webview_isVisible(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    lua_pushboolean(L, theWindow.isVisible ? 1 : 0)
    return 1
}

/// hs.webview:windowTitle([title]) -> webviewObject
/// Method
/// Sets the title for the webview window.
func webview_windowTitle(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_isnoneornil(L, 2) {
        theWindow.titleFollow = true
        let windowTitle = (theWindow.contentView as? HSWebViewView)?.title ?? "<no title>"
        theWindow.title = windowTitle
    } else {
        luaL_checktype(L, 2, LUA_TSTRING)
        theWindow.titleFollow = false
        theWindow.title = skin.toNSObject(atIndex: 2) as! String
    }
    lua_settop(L, 1)
    return 1
}

/// hs.webview:titleVisibility([state]) -> webviewObject | string
/// Function
/// Get or set whether or not the title text appears in the webview window.
func webview_titleVisibility(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    let mapping: [String: NSWindow.TitleVisibility] = [
        "visible": .visible,
        "hidden": .hidden,
    ]

    if lua_gettop(L) == 1 {
        let current = theWindow.titleVisibility
        let value = mapping.first(where: { $0.value == current })?.key
        if let value = value {
            skin.pushNSObject(value as NSString)
        } else {
            lua_pushnil(L)
        }
    } else {
        let key = skin.toNSObject(atIndex: 2) as? String ?? ""
        if let value = mapping[key] {
            theWindow.titleVisibility = value
            lua_pushvalue(L, 1)
        } else {
            let keys = mapping.keys.joined(separator: "', '")
            return luaL_argerror(L, 2, "must be one of '\(keys)'")
        }
    }
    return 1
}

// NOTE: wrapped in init.lua
func webview_windowStyle(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        lua_pushinteger(L, lua_Integer(theWindow.styleMask.rawValue))
    } else {
        let theTitle = theWindow.title
        theWindow.styleMask = []
        theWindow.styleMask = NSWindow.StyleMask(rawValue: UInt(luaL_checkinteger(L, 2)))
        theWindow.title = theTitle
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:level([theLevel]) -> drawingObject | currentValue
/// Method
/// Get or set the window level
func webview_level(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(theWindow.level.rawValue))
    } else {
        let targetLevel = lua_tointeger(L, 2)
        let minLevel = CGWindowLevelForKey(.minimumWindow)
        let maxLevel = CGWindowLevelForKey(.maximumWindow)
        if targetLevel >= Int(minLevel) && targetLevel <= Int(maxLevel) {
            theWindow.level = NSWindow.Level(rawValue: Int(targetLevel))
        } else {
            return luaL_error(L, "window level must be between \(minLevel) and \(maxLevel) inclusive")
        }
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:bringToFront([aboveEverything]) -> webviewObject
/// Method
/// Places the drawing object on top of normal windows
func webview_bringToFront(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    theWindow.level = lua_toboolean(L, 2) != 0 ? .screenSaver : .floating
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:sendToBack() -> webviewObject
/// Method
/// Places the webview object behind normal windows, between the desktop wallpaper and desktop icons
func webview_sendToBack(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)
    theWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:alpha([alpha]) -> webviewObject | currentValue
/// Method
/// Get or set the alpha level of the window containing the hs.webview object.
func webview_alpha(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_gettop(L) == 1 {
        lua_pushnumber(L, lua_Number(theWindow.alphaValue))
    } else {
        let newLevel = CGFloat(luaL_checknumber(L, 2))
        theWindow.alphaValue = min(max(newLevel, 0.0), 1.0)
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:shadow([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview window has shadows.
func webview_shadow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theWindow.hasShadow ? 1 : 0)
    } else {
        theWindow.hasShadow = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

func webview_orderHelper(_ L: UnsafeMutablePointer<lua_State>!, mode: NSWindow.OrderingMode) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK | LS_TVARARG)
    let theWindow = skin.luaObject(at: 1, toClass: "HSWebViewWindow") as! HSWebViewWindow
    var relativeTo: Int = 0

    if lua_gettop(L) > 1 {
        skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TUSERDATA, wv_USERDATA_TAG, LS_TBREAK)
        relativeTo = (skin.luaObject(at: 2, toClass: "HSWebViewWindow") as! HSWebViewWindow).windowNumber
    }

    theWindow.order(mode, relativeTo: relativeTo)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:orderAbove([webview2]) -> webviewObject
/// Method
/// Moves webview object above webview2, or all webview objects in the same presentation level, if webview2 is not given.
func webview_orderAbove(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return webview_orderHelper(L, mode: .above)
}

/// hs.webview:orderBelow([webview2]) -> webviewObject
/// Method
/// Moves webview object below webview2, or all webview objects in the same presentation level, if webview2 is not given.
func webview_orderBelow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return webview_orderHelper(L, mode: .below)
}

// NOTE: wrapped in init.lua
func webview_delete(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = skin.luaObject(at: 1, toClass: "HSWebViewWindow") as! HSWebViewWindow

    if lua_gettop(L) == 1 || !theWindow.isVisible {
        theWindow.close()
        lua_pushcfunction(L, wv_userdata_gc)
        lua_pushvalue(L, 1)
        if lua_pcall(L, 1, 0, 0) != LUA_OK {
            skin.logBreadcrumb(String(format: "%s:error invoking _gc for delete method:%s", wv_USERDATA_TAG, lua_tostring(L, -1)!))
            lua_pop(L, 1)
        }
    } else {
        theWindow.fadeOut(lua_tonumber(L, 2), andDelete: true, withState: L)
    }

    lua_pushnil(L)
    return 1
}

/// hs.webview:behavior([behavior]) -> webviewObject | currentValue
/// Method
/// Get or set the window behavior settings for the webview object.
func webview_behavior(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = skin.luaObject(at: 1, toClass: "HSWebViewWindow") as! HSWebViewWindow

    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(theWindow.collectionBehavior.rawValue))
    } else {
        skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
        let newLevel = lua_tointeger(L, 2)
        theWindow.collectionBehavior = NSWindow.CollectionBehavior(rawValue: UInt(newLevel))
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:windowCallback(fn) -> webviewObject
/// Method
/// Set or clear a callback for updates to the webview window
func webview_windowCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, wv_USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = wv_getWindowFromUD(L, 1)

    theWindow.windowCallback = skin.luaUnref(wv_refTable, ref: theWindow.windowCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theWindow.windowCallback = skin.luaRef(wv_refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Module Constants

/// hs.webview.windowMasks[]
/// Constant
/// A table containing valid masks for the webview window.
func wv_windowMasksTable(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.borderless.rawValue));          lua_setfield(L, -2, "borderless")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.titled.rawValue));              lua_setfield(L, -2, "titled")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.closable.rawValue));            lua_setfield(L, -2, "closable")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.miniaturizable.rawValue));      lua_setfield(L, -2, "miniaturizable")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.resizable.rawValue));           lua_setfield(L, -2, "resizable")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.texturedBackground.rawValue));  lua_setfield(L, -2, "texturedBackground")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.fullSizeContentView.rawValue)); lua_setfield(L, -2, "fullSizeContentView")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.utilityWindow.rawValue));       lua_setfield(L, -2, "utility")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.nonactivatingPanel.rawValue));  lua_setfield(L, -2, "nonactivating")
    lua_pushinteger(L, lua_Integer(NSWindow.StyleMask.hudWindow.rawValue));           lua_setfield(L, -2, "HUD")
    return 1
}

/// hs.webview.certificateOIDs[]
/// Constant
/// A table of common OID values found in SSL certificates.
func wv_pushCertificateOIDs(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    let oids: [(CFString, String)] = [
        (kSecOIDADC_CERT_POLICY, "ADC_CERT_POLICY"),
        (kSecOIDAPPLE_CERT_POLICY, "APPLE_CERT_POLICY"),
        (kSecOIDAPPLE_EKU_CODE_SIGNING, "APPLE_EKU_CODE_SIGNING"),
        (kSecOIDAPPLE_EKU_CODE_SIGNING_DEV, "APPLE_EKU_CODE_SIGNING_DEV"),
        (kSecOIDAPPLE_EKU_ICHAT_ENCRYPTION, "APPLE_EKU_ICHAT_ENCRYPTION"),
        (kSecOIDAPPLE_EKU_ICHAT_SIGNING, "APPLE_EKU_ICHAT_SIGNING"),
        (kSecOIDAPPLE_EKU_RESOURCE_SIGNING, "APPLE_EKU_RESOURCE_SIGNING"),
        (kSecOIDAPPLE_EKU_SYSTEM_IDENTITY, "APPLE_EKU_SYSTEM_IDENTITY"),
        (kSecOIDAPPLE_EXTENSION, "APPLE_EXTENSION"),
        (kSecOIDAPPLE_EXTENSION_ADC_APPLE_SIGNING, "APPLE_EXTENSION_ADC_APPLE_SIGNING"),
        (kSecOIDAPPLE_EXTENSION_ADC_DEV_SIGNING, "APPLE_EXTENSION_ADC_DEV_SIGNING"),
        (kSecOIDAPPLE_EXTENSION_APPLE_SIGNING, "APPLE_EXTENSION_APPLE_SIGNING"),
        (kSecOIDAPPLE_EXTENSION_CODE_SIGNING, "APPLE_EXTENSION_CODE_SIGNING"),
        (kSecOIDAuthorityInfoAccess, "authorityInfoAccess"),
        (kSecOIDAuthorityKeyIdentifier, "authorityKeyIdentifier"),
        (kSecOIDBasicConstraints, "basicConstraints"),
        (kSecOIDBiometricInfo, "biometricInfo"),
        (kSecOIDCSSMKeyStruct, "CSSMKeyStruct"),
        (kSecOIDCertIssuer, "certIssuer"),
        (kSecOIDCertificatePolicies, "certificatePolicies"),
        (kSecOIDClientAuth, "clientAuth"),
        (kSecOIDCollectiveStateProvinceName, "collectiveStateProvinceName"),
        (kSecOIDCollectiveStreetAddress, "collectiveStreetAddress"),
        (kSecOIDCommonName, "commonName"),
        (kSecOIDCountryName, "countryName"),
        (kSecOIDCrlDistributionPoints, "crlDistributionPoints"),
        (kSecOIDCrlNumber, "crlNumber"),
        (kSecOIDCrlReason, "crlReason"),
        (kSecOIDDOTMAC_CERT_EMAIL_ENCRYPT, "DOTMAC_CERT_EMAIL_ENCRYPT"),
        (kSecOIDDOTMAC_CERT_EMAIL_SIGN, "DOTMAC_CERT_EMAIL_SIGN"),
        (kSecOIDDOTMAC_CERT_EXTENSION, "DOTMAC_CERT_EXTENSION"),
        (kSecOIDDOTMAC_CERT_IDENTITY, "DOTMAC_CERT_IDENTITY"),
        (kSecOIDDOTMAC_CERT_POLICY, "DOTMAC_CERT_POLICY"),
        (kSecOIDDeltaCrlIndicator, "deltaCrlIndicator"),
        (kSecOIDDescription, "description"),
        (kSecOIDEKU_IPSec, "EKU_IPSec"),
        (kSecOIDEmailAddress, "emailAddress"),
        (kSecOIDEmailProtection, "emailProtection"),
        (kSecOIDExtendedKeyUsage, "extendedKeyUsage"),
        (kSecOIDExtendedKeyUsageAny, "extendedKeyUsageAny"),
        (kSecOIDExtendedUseCodeSigning, "extendedUseCodeSigning"),
        (kSecOIDGivenName, "givenName"),
        (kSecOIDHoldInstructionCode, "holdInstructionCode"),
        (kSecOIDInvalidityDate, "invalidityDate"),
        (kSecOIDIssuerAltName, "issuerAltName"),
        (kSecOIDIssuingDistributionPoint, "issuingDistributionPoint"),
        (kSecOIDIssuingDistributionPoints, "issuingDistributionPoints"),
        (kSecOIDKERBv5_PKINIT_KP_CLIENT_AUTH, "KERBv5_PKINIT_KP_CLIENT_AUTH"),
        (kSecOIDKERBv5_PKINIT_KP_KDC, "KERBv5_PKINIT_KP_KDC"),
        (kSecOIDKeyUsage, "keyUsage"),
        (kSecOIDLocalityName, "localityName"),
        (kSecOIDMS_NTPrincipalName, "MS_NTPrincipalName"),
        (kSecOIDMicrosoftSGC, "microsoftSGC"),
        (kSecOIDNameConstraints, "nameConstraints"),
        (kSecOIDNetscapeCertSequence, "netscapeCertSequence"),
        (kSecOIDNetscapeCertType, "netscapeCertType"),
        (kSecOIDNetscapeSGC, "netscapeSGC"),
        (kSecOIDOCSPSigning, "OCSPSigning"),
        (kSecOIDOrganizationName, "organizationName"),
        (kSecOIDOrganizationalUnitName, "organizationalUnitName"),
        (kSecOIDPolicyConstraints, "policyConstraints"),
        (kSecOIDPolicyMappings, "policyMappings"),
        (kSecOIDPrivateKeyUsagePeriod, "privateKeyUsagePeriod"),
        (kSecOIDQC_Statements, "QC_Statements"),
        (kSecOIDSerialNumber, "serialNumber"),
        (kSecOIDServerAuth, "serverAuth"),
        (kSecOIDStateProvinceName, "stateProvinceName"),
        (kSecOIDStreetAddress, "streetAddress"),
        (kSecOIDSubjectAltName, "subjectAltName"),
        (kSecOIDSubjectDirectoryAttributes, "subjectDirectoryAttributes"),
        (kSecOIDSubjectEmailAddress, "subjectEmailAddress"),
        (kSecOIDSubjectInfoAccess, "subjectInfoAccess"),
        (kSecOIDSubjectKeyIdentifier, "subjectKeyIdentifier"),
        (kSecOIDSubjectPicture, "subjectPicture"),
        (kSecOIDSubjectSignatureBitmap, "subjectSignatureBitmap"),
        (kSecOIDSurname, "surname"),
        (kSecOIDTimeStamping, "timeStamping"),
        (kSecOIDTitle, "title"),
        (kSecOIDUseExemptions, "useExemptions"),
        (kSecOIDX509V1CertificateIssuerUniqueId, "X509V1CertificateIssuerUniqueId"),
        (kSecOIDX509V1CertificateSubjectUniqueId, "X509V1CertificateSubjectUniqueId"),
        (kSecOIDX509V1IssuerName, "X509V1IssuerName"),
        (kSecOIDX509V1IssuerNameCStruct, "X509V1IssuerNameCStruct"),
        (kSecOIDX509V1IssuerNameLDAP, "X509V1IssuerNameLDAP"),
        (kSecOIDX509V1IssuerNameStd, "X509V1IssuerNameStd"),
        (kSecOIDX509V1SerialNumber, "X509V1SerialNumber"),
        (kSecOIDX509V1Signature, "X509V1Signature"),
        (kSecOIDX509V1SignatureAlgorithm, "X509V1SignatureAlgorithm"),
        (kSecOIDX509V1SignatureAlgorithmParameters, "X509V1SignatureAlgorithmParameters"),
        (kSecOIDX509V1SignatureAlgorithmTBS, "X509V1SignatureAlgorithmTBS"),
        (kSecOIDX509V1SignatureCStruct, "X509V1SignatureCStruct"),
        (kSecOIDX509V1SignatureStruct, "X509V1SignatureStruct"),
        (kSecOIDX509V1SubjectName, "X509V1SubjectName"),
        (kSecOIDX509V1SubjectNameCStruct, "X509V1SubjectNameCStruct"),
        (kSecOIDX509V1SubjectNameLDAP, "X509V1SubjectNameLDAP"),
        (kSecOIDX509V1SubjectNameStd, "X509V1SubjectNameStd"),
        (kSecOIDX509V1SubjectPublicKey, "X509V1SubjectPublicKey"),
        (kSecOIDX509V1SubjectPublicKeyAlgorithm, "X509V1SubjectPublicKeyAlgorithm"),
        (kSecOIDX509V1SubjectPublicKeyAlgorithmParameters, "X509V1SubjectPublicKeyAlgorithmParameters"),
        (kSecOIDX509V1SubjectPublicKeyCStruct, "X509V1SubjectPublicKeyCStruct"),
        (kSecOIDX509V1ValidityNotAfter, "X509V1ValidityNotAfter"),
        (kSecOIDX509V1ValidityNotBefore, "X509V1ValidityNotBefore"),
        (kSecOIDX509V1Version, "X509V1Version"),
        (kSecOIDX509V3Certificate, "X509V3Certificate"),
        (kSecOIDX509V3CertificateCStruct, "X509V3CertificateCStruct"),
        (kSecOIDX509V3CertificateExtensionCStruct, "X509V3CertificateExtensionCStruct"),
        (kSecOIDX509V3CertificateExtensionCritical, "X509V3CertificateExtensionCritical"),
        (kSecOIDX509V3CertificateExtensionId, "X509V3CertificateExtensionId"),
        (kSecOIDX509V3CertificateExtensionStruct, "X509V3CertificateExtensionStruct"),
        (kSecOIDX509V3CertificateExtensionType, "X509V3CertificateExtensionType"),
        (kSecOIDX509V3CertificateExtensionValue, "X509V3CertificateExtensionValue"),
        (kSecOIDX509V3CertificateExtensionsCStruct, "X509V3CertificateExtensionsCStruct"),
        (kSecOIDX509V3CertificateExtensionsStruct, "X509V3CertificateExtensionsStruct"),
        (kSecOIDX509V3CertificateNumberOfExtensions, "X509V3CertificateNumberOfExtensions"),
        (kSecOIDX509V3SignedCertificate, "X509V3SignedCertificate"),
        (kSecOIDX509V3SignedCertificateCStruct, "X509V3SignedCertificateCStruct"),
        (kSecOIDSRVName, "SRVName"),
    ]
    for (oid, name) in oids {
        skin.pushNSObject(oid as NSString)
        lua_setfield(L, -2, name)
    }
    return 1
}

// MARK: - NS<->Lua conversion tools

func wv_luaTo_HSWebViewWindow(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, wv_USERDATA_TAG) != nil {
        return wv_getWindowFromUD(L, idx)
    } else {
        skin.logError(String(format: "expected %s object, found %s", wv_USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

func wv_HSWebViewWindow_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theWindow = obj as! HSWebViewWindow

    if theWindow.udRef == LUA_NOREF {
        let windowPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        windowPtr.pointee = Unmanaged.passRetained(theWindow).toOpaque()
        luaL_getmetatable(L, wv_USERDATA_TAG)
        lua_setmetatable(L, -2)
        theWindow.udRef = skin.luaRef(wv_refTable)
    }

    skin.pushLuaRef(wv_refTable, ref: theWindow.udRef)
    return 1
}

func wv_WKNavigationAction_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let navAction = obj as! WKNavigationAction

    lua_newtable(L)
    skin.pushNSObject(navAction.request as NSObject); lua_setfield(L, -2, "request")
    skin.pushNSObject(navAction.sourceFrame);         lua_setfield(L, -2, "sourceFrame")
    skin.pushNSObject(navAction.targetFrame);         lua_setfield(L, -2, "targetFrame")
    lua_pushinteger(L, lua_Integer(navAction.buttonNumber)); lua_setfield(L, -2, "buttonNumber")

    let theFlags = navAction.modifierFlags.rawValue
    lua_newtable(L)
    if navAction.modifierFlags.contains(.capsLock) { lua_pushboolean(L, 1); lua_setfield(L, -2, "capslock") }
    if navAction.modifierFlags.contains(.shift)    { lua_pushboolean(L, 1); lua_setfield(L, -2, "shift") }
    if navAction.modifierFlags.contains(.control)  { lua_pushboolean(L, 1); lua_setfield(L, -2, "ctrl") }
    if navAction.modifierFlags.contains(.option)   { lua_pushboolean(L, 1); lua_setfield(L, -2, "alt") }
    if navAction.modifierFlags.contains(.command)  { lua_pushboolean(L, 1); lua_setfield(L, -2, "cmd") }
    if navAction.modifierFlags.contains(.function) { lua_pushboolean(L, 1); lua_setfield(L, -2, "fn") }
    lua_pushinteger(L, lua_Integer(theFlags)); lua_setfield(L, -2, "_raw")
    lua_setfield(L, -2, "modifierFlags")

    switch navAction.navigationType {
    case .linkActivated:   lua_pushstring(L, "linkActivated")
    case .formSubmitted:   lua_pushstring(L, "formSubmitted")
    case .backForward:     lua_pushstring(L, "backForward")
    case .reload:          lua_pushstring(L, "reload")
    case .formResubmitted: lua_pushstring(L, "formResubmitted")
    case .other:           lua_pushstring(L, "other")
    @unknown default:      lua_pushstring(L, "unknown")
    }
    lua_setfield(L, -2, "navigationType")
    return 1
}

func wv_WKNavigationResponse_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let navResponse = obj as! WKNavigationResponse

    lua_newtable(L)
    lua_pushboolean(L, navResponse.canShowMIMEType ? 1 : 0); lua_setfield(L, -2, "canShowMIMEType")
    lua_pushboolean(L, navResponse.isForMainFrame ? 1 : 0);  lua_setfield(L, -2, "forMainFrame")
    skin.pushNSObject(navResponse.response);                  lua_setfield(L, -2, "response")
    return 1
}

func wv_WKFrameInfo_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let frameInfo = obj as! WKFrameInfo

    lua_newtable(L)
    lua_pushboolean(L, frameInfo.isMainFrame ? 1 : 0); lua_setfield(L, -2, "mainFrame")
    skin.pushNSObject(frameInfo.request as NSObject);   lua_setfield(L, -2, "request")
    skin.pushNSObject(frameInfo.securityOrigin);        lua_setfield(L, -2, "securityOrigin")
    return 1
}

func wv_WKBackForwardListItem_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let item = obj as! WKBackForwardListItem

    lua_newtable(L)
    skin.pushNSObject(item.url as NSURL);        lua_setfield(L, -2, "URL")
    skin.pushNSObject(item.initialURL as NSURL); lua_setfield(L, -2, "initialURL")
    skin.pushNSObject(item.title as NSString?);  lua_setfield(L, -2, "title")
    return 1
}

func wv_WKBackForwardList_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theList = obj as? WKBackForwardList

    lua_newtable(L)
    if let theList = theList {
        for value in theList.backList {
            skin.pushNSObject(value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        if let currentItem = theList.currentItem {
            skin.pushNSObject(currentItem)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        lua_pushinteger(L, luaL_len(L, -1)); lua_setfield(L, -2, "current")

        for value in theList.forwardList {
            skin.pushNSObject(value)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        lua_pushinteger(L, 0); lua_setfield(L, -2, "current")
    }
    return 1
}

func wv_WKNavigation_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let navID = obj as! WKNavigation
    let str = String(describing: Unmanaged.passUnretained(navID as AnyObject).toOpaque())
    lua_pushstring(L, str)
    return 1
}

func wv_NSError_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    guard let theError = obj as? NSError else { lua_pushnil(L); return 1 }

    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(theError.code));                    lua_setfield(L, -2, "code")
    skin.pushNSObject(theError.domain as NSString);                    lua_setfield(L, -2, "domain")
    skin.pushNSObject(theError.helpAnchor as NSString?);               lua_setfield(L, -2, "helpAnchor")
    skin.pushNSObject(theError.localizedDescription as NSString);      lua_setfield(L, -2, "localizedDescription")
    skin.pushNSObject(theError.localizedRecoveryOptions as NSArray?);  lua_setfield(L, -2, "localizedRecoveryOptions")
    skin.pushNSObject(theError.localizedRecoverySuggestion as NSString?); lua_setfield(L, -2, "localizedRecoverySuggestion")
    skin.pushNSObject(theError.localizedFailureReason as NSString?);   lua_setfield(L, -2, "localizedFailureReason")
    return 1
}

func wv_WKWindowFeatures_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let features = obj as! WKWindowFeatures

    lua_newtable(L)
    if let v = features.menuBarVisibility   { lua_pushboolean(L, v.boolValue ? 1 : 0); lua_setfield(L, -2, "menuBarVisibility") }
    if let v = features.statusBarVisibility { lua_pushboolean(L, v.boolValue ? 1 : 0); lua_setfield(L, -2, "statusBarVisibility") }
    if let v = features.toolbarsVisibility  { lua_pushboolean(L, v.boolValue ? 1 : 0); lua_setfield(L, -2, "toolbarsVisibility") }
    if let v = features.allowsResizing      { lua_pushboolean(L, v.boolValue ? 1 : 0); lua_setfield(L, -2, "allowsResizing") }
    if let v = features.x      { lua_pushnumber(L, v.doubleValue); lua_setfield(L, -2, "x") }
    if let v = features.y      { lua_pushnumber(L, v.doubleValue); lua_setfield(L, -2, "y") }
    if let v = features.height { lua_pushnumber(L, v.doubleValue); lua_setfield(L, -2, "h") }
    if let v = features.width  { lua_pushnumber(L, v.doubleValue); lua_setfield(L, -2, "w") }
    return 1
}

func wv_NSURLAuthenticationChallenge_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let challenge = obj as! URLAuthenticationChallenge

    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(challenge.previousFailureCount)); lua_setfield(L, -2, "previousFailureCount")
    skin.pushNSObject(challenge.error as NSError?);                  lua_setfield(L, -2, "error")
    skin.pushNSObject(challenge.failureResponse);                    lua_setfield(L, -2, "failureResponse")
    skin.pushNSObject(challenge.proposedCredential);                 lua_setfield(L, -2, "proposedCredential")
    skin.pushNSObject(challenge.protectionSpace);                    lua_setfield(L, -2, "protectionSpace")
    return 1
}

func wv_SecCertificateRef_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ certRef: SecCertificate!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    lua_newtable(L)
    var commonName: CFString?
    SecCertificateCopyCommonName(certRef, &commonName)
    if let commonName = commonName {
        skin.pushNSObject(commonName as NSString); lua_setfield(L, -2, "commonName")
    }
    if let values = SecCertificateCopyValues(certRef, nil, nil) {
        skin.pushNSObject(values as NSDictionary, withOptions: UInt(LS_NSConversionOptions.nsDescribeUnknownTypes.rawValue))
        lua_setfield(L, -2, "values")
    }
    return 1
}

func wv_NSURLProtectionSpace_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theSpace = obj as! URLProtectionSpace

    lua_newtable(L)
    lua_pushboolean(L, theSpace.isProxy() ? 1 : 0);                   lua_setfield(L, -2, "isProxy")
    lua_pushinteger(L, lua_Integer(theSpace.port));                   lua_setfield(L, -2, "port")
    lua_pushboolean(L, theSpace.receivesCredentialSecurely ? 1 : 0);  lua_setfield(L, -2, "receivesCredentialSecurely")

    let methodMap: [String: String] = [
        NSURLAuthenticationMethodDefault: "default",
        NSURLAuthenticationMethodHTTPBasic: "HTTPBasic",
        NSURLAuthenticationMethodHTTPDigest: "HTTPDigest",
        NSURLAuthenticationMethodHTMLForm: "HTMLForm",
        NSURLAuthenticationMethodNegotiate: "negotiate",
        NSURLAuthenticationMethodNTLM: "NTLM",
        NSURLAuthenticationMethodClientCertificate: "clientCertificate",
        NSURLAuthenticationMethodServerTrust: "serverTrust",
    ]
    let method = methodMap[theSpace.authenticationMethod] ?? "unknown"
    skin.pushNSObject(method as NSString); lua_setfield(L, -2, "authenticationMethod")
    skin.pushNSObject((theSpace.host) as NSString); lua_setfield(L, -2, "host")
    skin.pushNSObject(theSpace.protocol as NSString?); lua_setfield(L, -2, "protocol")

    let proxyMap: [String: String] = [
        NSURLProtectionSpaceHTTPProxy: "http",
        NSURLProtectionSpaceHTTPSProxy: "https",
        NSURLProtectionSpaceFTPProxy: "ftp",
        NSURLProtectionSpaceSOCKSProxy: "socks",
    ]
    let proxy = proxyMap[theSpace.proxyType ?? ""] ?? "unknown"
    skin.pushNSObject(proxy as NSString); lua_setfield(L, -2, "proxyType")
    skin.pushNSObject(theSpace.realm as NSString?); lua_setfield(L, -2, "realm")

    if let serverTrust = theSpace.serverTrust {
        lua_newtable(L)
        var secResult: SecTrustResultType = .invalid
        SecTrustEvaluate(serverTrust, &secResult)
        let count = SecTrustGetCertificateCount(serverTrust)
        for idx in 0..<count {
            wv_SecCertificateRef_toLua(L, SecTrustGetCertificateAtIndex(serverTrust, idx))
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        lua_setfield(L, -2, "certificates")
    }
    return 1
}

func wv_NSURLCredential_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let credential = obj as! URLCredential

    lua_newtable(L)
    lua_pushboolean(L, credential.hasPassword ? 1 : 0); lua_setfield(L, -2, "hasPassword")
    switch credential.persistence {
    case .none:           lua_pushstring(L, "none")
    case .forSession:     lua_pushstring(L, "session")
    case .permanent:      lua_pushstring(L, "permanent")
    case .synchronizable: lua_pushstring(L, "synchronized")
    @unknown default:     lua_pushstring(L, "unknown")
    }
    lua_setfield(L, -2, "persistence")
    skin.pushNSObject(credential.user as NSString?);     lua_setfield(L, -2, "user")
    skin.pushNSObject(credential.password as NSString?);  lua_setfield(L, -2, "password")
    return 1
}

func wv_WKSecurityOrigin_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let origin = obj as! WKSecurityOrigin

    lua_newtable(L)
    skin.pushNSObject(origin.host as NSString);     lua_setfield(L, -2, "host")
    lua_pushinteger(L, lua_Integer(origin.port));    lua_setfield(L, -2, "port")
    skin.pushNSObject(origin.protocol as NSString);  lua_setfield(L, -2, "protocol")
    return 1
}

// MARK: - Lua Framework Stuff

func wv_userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as? HSWebViewView
    let title = theView?.title ?? ""
    let ptr = lua_topointer(L, 1)!
    let str = "\(wv_USERDATA_TAG): \(title.isEmpty ? "" : title) (\(ptr))"
    lua_pushstring(L, str)
    return 1
}

func wv_userdata_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let theWindow = wv_getWindowFromUD(L, 1)
    let otherWindow = wv_getWindowFromUD(L, 2)
    lua_pushboolean(L, theWindow.udRef == otherWindow.udRef ? 1 : 0)
    return 1
}

func wv_userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if luaL_testudata(L, 1, wv_USERDATA_TAG) == nil { return 0 }

    let ptr = luaL_checkudata(L, 1, wv_USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else {
        lua_pushnil(L); lua_setmetatable(L, 1)
        return 0
    }
    let theWindow = Unmanaged<HSWebViewWindow>.fromOpaque(rawPtr).takeRetainedValue()
    let theView = theWindow.contentView as? HSWebViewView
    ptr.pointee = nil

    lua_pushnil(L)
    lua_setmetatable(L, 1)

    let skin = LuaSkin.skin(with: L)
    theWindow.udRef = skin.luaUnref(wv_refTable, ref: theWindow.udRef)
    theWindow.windowCallback = skin.luaUnref(wv_refTable, ref: theWindow.windowCallback)
    if let theView = theView {
        theView.navigationCallback = skin.luaUnref(wv_refTable, ref: theView.navigationCallback)
        theView.policyCallback = skin.luaUnref(wv_refTable, ref: theView.policyCallback)
    }

    if theWindow.toolbar != nil {
        theWindow.toolbar?.isVisible = false
        theWindow.toolbar = nil
    }

    theWindow.close()

    if let parent = theWindow.parentWebView {
        parent.children.remove(theWindow)
        theWindow.parentWebView = nil
    }

    for child in theWindow.children {
        (child as? HSWebViewWindow)?.parentWebView = nil
    }

    if let theView = theView, let reloadTimer = wv_delayTimers?.object(forKey: theView) {
        reloadTimer.invalidate()
        wv_delayTimers?.removeObject(forKey: theView)
    }

    theView?.navigationDelegate = nil
    theView?.uiDelegate = nil
    theWindow.contentView = nil

    var tmpCanary = theWindow.lsCanary
    skin.destroy(&tmpCanary)
    theWindow.lsCanary = tmpCanary

    theWindow.delegate = nil

    return 0
}

func wv_meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    wv_ProcessPool = nil

    if let timers = wv_delayTimers {
        let enumerator = timers.objectEnumerator()!
        while let timer = enumerator.nextObject() as? Timer {
            timer.invalidate()
        }
        wv_delayTimers?.removeAllObjects()
    }
    wv_delayTimers = nil

    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    // Webview Related
    luaL_Reg(name: strdup("goBack"),                     func: webview_goBack),
    luaL_Reg(name: strdup("goForward"),                  func: webview_goForward),
    luaL_Reg(name: strdup("url"),                        func: webview_url),
    luaL_Reg(name: strdup("title"),                      func: webview_title),
    luaL_Reg(name: strdup("navigationID"),               func: webview_navigationID),
    luaL_Reg(name: strdup("reload"),                     func: webview_reload),
    luaL_Reg(name: strdup("transparent"),                func: webview_transparent),
    luaL_Reg(name: strdup("magnification"),              func: webview_magnification),
    luaL_Reg(name: strdup("allowMagnificationGestures"), func: webview_allowMagnificationGestures),
    luaL_Reg(name: strdup("allowNewWindows"),            func: webview_allowNewWindows),
    luaL_Reg(name: strdup("allowNavigationGestures"),    func: webview_allowNavigationGestures),
    luaL_Reg(name: strdup("isOnlySecureContent"),        func: webview_isOnlySecureContent),
    luaL_Reg(name: strdup("estimatedProgress"),          func: webview_estimatedProgress),
    luaL_Reg(name: strdup("loading"),                    func: webview_loading),
    luaL_Reg(name: strdup("stopLoading"),                func: webview_stopLoading),
    luaL_Reg(name: strdup("html"),                       func: webview_html),
    luaL_Reg(name: strdup("historyList"),                func: webview_historyList),
    luaL_Reg(name: strdup("navigationCallback"),         func: webview_navigationCallback),
    luaL_Reg(name: strdup("policyCallback"),             func: webview_policyCallback),
    luaL_Reg(name: strdup("sslCallback"),                func: webview_sslCallback),
    luaL_Reg(name: strdup("children"),                   func: webview_children),
    luaL_Reg(name: strdup("parent"),                     func: webview_parent),
    luaL_Reg(name: strdup("evaluateJavaScript"),         func: webview_evaluateJavaScript),
    luaL_Reg(name: strdup("privateBrowsing"),            func: webview_privateBrowsing),
    luaL_Reg(name: strdup("userAgent"),                  func: webview_userAgent),
    luaL_Reg(name: strdup("certificateChain"),           func: webview_certificateChain),
    luaL_Reg(name: strdup("examineInvalidCertificates"), func: webview_examineInvalidCertificates),

    // Window related
    luaL_Reg(name: strdup("darkMode"),                   func: webview_darkMode),
    luaL_Reg(name: strdup("titleVisibility"),            func: webview_titleVisibility),
    luaL_Reg(name: strdup("show"),                       func: webview_show),
    luaL_Reg(name: strdup("hide"),                       func: webview_hide),
    luaL_Reg(name: strdup("closeOnEscape"),              func: webview_closeOnEscape),
    luaL_Reg(name: strdup("allowTextEntry"),             func: webview_allowTextEntry),
    luaL_Reg(name: strdup("hswindow"),                   func: webview_hswindow),
    luaL_Reg(name: strdup("windowTitle"),                func: webview_windowTitle),
    luaL_Reg(name: strdup("deleteOnClose"),              func: webview_deleteOnClose),
    luaL_Reg(name: strdup("bringToFront"),               func: webview_bringToFront),
    luaL_Reg(name: strdup("sendToBack"),                 func: webview_sendToBack),
    luaL_Reg(name: strdup("shadow"),                     func: webview_shadow),
    luaL_Reg(name: strdup("alpha"),                      func: webview_alpha),
    luaL_Reg(name: strdup("orderAbove"),                 func: webview_orderAbove),
    luaL_Reg(name: strdup("orderBelow"),                 func: webview_orderBelow),
    luaL_Reg(name: strdup("behavior"),                   func: webview_behavior),
    luaL_Reg(name: strdup("windowCallback"),             func: webview_windowCallback),
    luaL_Reg(name: strdup("topLeft"),                    func: webview_topLeft),
    luaL_Reg(name: strdup("size"),                       func: webview_size),
    luaL_Reg(name: strdup("isVisible"),                  func: webview_isVisible),

    luaL_Reg(name: strdup("_delete"),                    func: webview_delete),
    luaL_Reg(name: strdup("_windowStyle"),               func: webview_windowStyle),
    luaL_Reg(name: strdup("level"),                      func: webview_level),

    luaL_Reg(name: strdup("__tostring"),                 func: wv_userdata_tostring),
    luaL_Reg(name: strdup("__eq"),                       func: wv_userdata_eq),
    luaL_Reg(name: strdup("__gc"),                       func: wv_userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: webview_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: wv_meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwebview")
public func luaopen_hs_libwebview(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    wv_refTable = skin.registerLibrary(withObject: wv_USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    // module userdata specific conversions
    skin.registerPushNSHelper(wv_HSWebViewWindow_toLua, forClass: "HSWebViewWindow")
    skin.registerLuaObjectHelper(wv_luaTo_HSWebViewWindow, forClass: "HSWebViewWindow",
                                 withUserdataMapping: wv_USERDATA_TAG)

    // classes used primarily by this module
    skin.registerPushNSHelper(wv_WKBackForwardListItem_toLua, forClass: "WKBackForwardListItem")
    skin.registerPushNSHelper(wv_WKBackForwardList_toLua, forClass: "WKBackForwardList")
    skin.registerPushNSHelper(wv_WKNavigationAction_toLua, forClass: "WKNavigationAction")
    skin.registerPushNSHelper(wv_WKNavigationResponse_toLua, forClass: "WKNavigationResponse")
    skin.registerPushNSHelper(wv_WKFrameInfo_toLua, forClass: "WKFrameInfo")
    skin.registerPushNSHelper(wv_WKNavigation_toLua, forClass: "WKNavigation")
    skin.registerPushNSHelper(wv_WKWindowFeatures_toLua, forClass: "WKWindowFeatures")
    skin.registerPushNSHelper(wv_WKSecurityOrigin_toLua, forClass: "WKSecurityOrigin")

    // classes that may find a better home elsewhere someday
    skin.registerPushNSHelper(wv_NSURLAuthenticationChallenge_toLua, forClass: "NSURLAuthenticationChallenge")
    skin.registerPushNSHelper(wv_NSURLProtectionSpace_toLua, forClass: "NSURLProtectionSpace")
    skin.registerPushNSHelper(wv_NSURLCredential_toLua, forClass: "NSURLCredential")

    wv_windowMasksTable(L);    lua_setfield(L, -2, "windowMasks")
    wv_pushCertificateOIDs(L); lua_setfield(L, -2, "certificateOIDs")

    return 1
}
