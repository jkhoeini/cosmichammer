import Foundation
import CLua
import Lua
import Cocoa
import WebKit
import os.log

let wv_USERDATA_TAG = "hs.webview"
private let kMaxWebviewRecursionDepth = 50
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
    precondition(Thread.isMainThread, "wv_delayUntilViewStopsLoading must be called on main thread")
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
func webview_privateBrowsing(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = Unmanaged<HSWebViewWindow>.fromOpaque(
        luaL_checkudata(L, 1, wv_USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee!
    ).takeUnretainedValue()
    let theView = theWindow.contentView as! HSWebViewView
    let theConfiguration = theView.configuration
    L.push(!theConfiguration.websiteDataStore.isPersistent)
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
func webview_children(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    lua_newtable(L)
    for child in theWindow.children {
        wv_pushAny(L, child as? HSWebViewWindow)
        lua_rawseti(L, -2, luaL_len(L, -2) + 1)
    }
    return 1
}

/// hs.webview:parent() -> webviewObject | nil
/// Method
/// Get the parent webview object for the calling webview object, or nil if the webview has no parent.
func webview_parent(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    wv_pushAny(L, theWindow.parentWebView)
    return 1
}

/// hs.webview:url([URL]) -> webviewObject, navigationIdentifier | url
/// Method
/// Get or set the URL to render for the webview.
func webview_url(_ L: LuaState) throws -> CInt {
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushany(L, theView.url?.absoluteString as NSString?)
        return 1
    } else {
        let theNSURL = wv_toURLRequest(L, 2)
        if let theNSURL = theNSURL {
            wv_delayUntilViewStopsLoading(theView) {
                let navID = theView.load(theNSURL)
                theView.trackingID = navID
            }
            lua_pushvalue(L, 1)
            return 1
        } else {
            throw LuaCallError("Invalid URL type.  String or table expected.")
        }
    }
}

/// hs.webview:userAgent([agent]) -> webviewObject | current value
/// Method
/// Get or set the webview's user agent string
func webview_userAgent(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushany(L, theView.customUserAgent as NSString?)
    } else {
        theView.customUserAgent = lua_tovalue(L, at: 2) as? String
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:certificateChain() -> table | nil
/// Method
/// Returns the certificate chain for the most recently committed navigation of the webview.
func webview_certificateChain(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
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
func webview_title(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    lua_pushany(L, theView.title as NSString?)
    return 1
}

/// hs.webview:navigationID() -> navigationID
/// Method
/// Get the most recent navigation identifier for the specified webview.
func webview_navigationID(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    wv_pushAny(L, theView.trackingID)
    return 1
}

/// hs.webview:loading() -> boolean
/// Method
/// Returns a boolean value indicating whether or not the webview is still loading content.
func webview_loading(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    L.push(theView.isLoading)
    return 1
}

/// hs.webview:stopLoading() -> webviewObject
/// Method
/// Stop loading additional content for the webview.
func webview_stopLoading(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    if !theView.isLoading { theView.stopLoading() }
    lua_settop(L, 1)
    return 1
}

/// hs.webview:estimatedProgress() -> number
/// Method
/// Returns the estimated percentage of expected content that has been loaded.
func webview_estimatedProgress(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    L.push(theView.estimatedProgress)
    return 1
}

/// hs.webview:isOnlySecureContent() -> bool
/// Method
/// Returns a boolean value indicating if all content current displayed in the webview was loaded over securely encrypted connections.
func webview_isOnlySecureContent(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    L.push(theView.hasOnlySecureContent)
    return 1
}

/// hs.webview:goForward() -> webviewObject
/// Method
/// Move to the next page in the webview's history, if possible.
func webview_goForward(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    theView.goForward()
    lua_settop(L, 1)
    return 1
}

/// hs.webview:goBack() -> webviewObject
/// Method
/// Move to the previous page in the webview's history, if possible.
func webview_goBack(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    theView.goBack()
    lua_settop(L, 1)
    return 1
}

/// hs.webview:reload([validate]) -> webviewObject, navigationIdentifier
/// Method
/// Reload the page in the webview, optionally performing end-to-end revalidation using cache-validating conditionals if possible.
func webview_reload(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
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
func webview_transparent(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_type(L, 2) == LUA_TNONE {
        L.push(!theWindow.isOpaque)
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
func webview_allowMagnificationGestures(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        L.push(theView.allowsMagnification)
    } else {
        theView.allowsMagnification = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:allowNewWindows([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview allows new windows to be opened from it by any method.
func webview_allowNewWindows(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        L.push(theView.allowNewWindows)
    } else {
        theView.allowNewWindows = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:examineInvalidCertificates([flag]) -> webviewObject | current value
/// Method
/// Get or set whether or not invalid SSL server certificates that are approved by the ssl callback function are accepted as valid for browsing with the webview.
func webview_examineInvalidCertificates(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        L.push(theView.examineInvalidCertificates)
    } else {
        theView.examineInvalidCertificates = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:allowNavigationGestures([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview will respond to the navigation gestures from a trackpad or magic mouse.
func webview_allowNavigationGestures(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        L.push(theView.allowsBackForwardNavigationGestures)
    } else {
        theView.allowsBackForwardNavigationGestures = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:magnification([value]) -> webviewObject | current value
/// Method
/// Get or set the webviews current magnification level.
func webview_magnification(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        L.push(lua_Number(theView.magnification))
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
func webview_html(_ L: LuaState) throws -> CInt {
    precondition(lua_gettop(L) >= 2, "webview_html requires at least 2 arguments (self + html)")
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    luaL_tolstring(L, 2, nil)
    let theHTML = lua_tovalue(L, at: -1) as? String ?? ""
    lua_pop(L, 1)
    let theBaseURL = (lua_type(L, 3) == LUA_TSTRING) ? lua_tovalue(L, at: 3) as? String : nil

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
func webview_navigationCallback(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.navigationCallback = nil
    if lua_type(L, 2) == LUA_TFUNCTION {
        theView.navigationCallback = L.ref(index: 2)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:policyCallback(fn) -> webviewObject
/// Method
/// Sets a callback to approve or deny web navigation activity.
func webview_policyCallback(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.policyCallback = nil
    if lua_type(L, 2) == LUA_TFUNCTION {
        theView.policyCallback = L.ref(index: 2)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:sslCallback(fn) -> webviewObject
/// Method
/// Sets a callback to examine an invalid SSL certificate and determine if an exception should be granted.
func webview_sslCallback(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.sslCallback = nil
    if lua_type(L, 2) == LUA_TFUNCTION {
        theView.sslCallback = L.ref(index: 2)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:historyList() -> historyTable
/// Method
/// Returns the URL history for the current webview as an array.
func webview_historyList(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    wv_pushAny(L, theView.backForwardList)
    return 1
}

/// hs.webview:evaluateJavaScript(script, [callback]) -> webviewObject
/// Method
/// Execute JavaScript within the context of the current webview and optionally receive its result or error in a callback function.
func webview_evaluateJavaScript(_ L: LuaState) throws -> CInt {
    precondition(lua_gettop(L) >= 2, "webview_evaluateJavaScript requires at least 2 arguments (self + script)")
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    let javascript = lua_tovalue(L, at: 2) as! String
    var callbackValue: LuaValue?
    if lua_type(L, 3) == LUA_TFUNCTION {
        callbackValue = L.ref(index: 3)
    }

    let lsCanary = lua_currentStateGeneration()
    theView.evaluateJavaScript(javascript) { obj, error in
        if let cb = callbackValue {
            DispatchQueue.main.async {
                if !lua_isStateGenerationValid(lsCanary) { return }
                let blockL = lua_getCurrentState()!
                cb.push(onto: blockL)
                wv_pushAny(blockL, obj as? NSObject)
                wv_NSError_toLua(blockL, error as NSError?)
                if lua_pcall(blockL, 2, 0, 0) != LUA_OK { lua_pop(blockL, 1) }
                callbackValue = nil
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
func webview_topLeft(_ L: LuaState) throws -> CInt {
    let theWindow = wv_getWindowFromUD(L, 1)
    let oldFrame = wv_RectWithFlippedYCoordinate(theWindow.frame)

    if lua_gettop(L) == 1 {
        lua_pushNSPoint(L, oldFrame.origin)
    } else {
        let newCoord = lua_tableToPoint(L, at: 2)
        let newFrame = wv_RectWithFlippedYCoordinate(NSMakeRect(newCoord.x, newCoord.y, oldFrame.size.width, oldFrame.size.height))
        theWindow.setFrame(newFrame, display: true, animate: false)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:size([size]) -> webviewObject | currentValue
/// Method
/// Get or set the size of a webview window
func webview_size(_ L: LuaState) throws -> CInt {
    let theWindow = wv_getWindowFromUD(L, 1)
    let oldFrame = theWindow.frame

    if lua_gettop(L) == 1 {
        lua_pushNSSize(L, oldFrame.size)
    } else {
        let newSize = lua_tableToSize(L, at: 2)
        let newFrame = NSMakeRect(oldFrame.origin.x, oldFrame.origin.y + oldFrame.size.height - newSize.height, newSize.width, newSize.height)
        theWindow.setFrame(newFrame, display: true, animate: false)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview.new(rect, [preferencesTable], [userContentController]) -> webviewObject
/// Constructor
/// Create a webviewObject and optionally modify its preferences.
func webview_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TTABLE)
    let windowRect = lua_tableToRect(L, at: 1)
    assert(windowRect.size.width >= 0, "webview_new: window rect width must be non-negative")
    assert(windowRect.size.height >= 0, "webview_new: window rect height must be non-negative")

    let theWindow = HSWebViewWindow(contentRect: windowRect, styleMask: .borderless, backing: .buffered, defer: true)

    theWindow.lsCanary = lua_currentStateGeneration()

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
            config.websiteDataStore = wv_toWKWebsiteDataStore(L, -1)!
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "privateBrowsing") == LUA_TBOOLEAN && lua_toboolean(L, -1) != 0 {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        lua_pop(L, 1)

        if lua_getfield(L, 2, "applicationName") == LUA_TSTRING {
            config.applicationNameForUserAgent = lua_tovalue(L, at: -1) as? String
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
    theView.generation = theWindow.lsCanary
    theWindow.contentView = theView
    wv_pushAny(L, theWindow)
    return 1
}

/// hs.webview:show([fadeInTime]) -> webviewObject
/// Method
/// Displays the webview object
func webview_show(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let fadeTime: TimeInterval = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0

    if fadeTime > 0 { theWindow.fadeIn(fadeTime) } else { theWindow.makeKeyAndOrderFront(nil) }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:hide([fadeOutTime]) -> webviewObject
/// Method
/// Hides the webview object
func webview_hide(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let fadeTime: TimeInterval = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0

    if fadeTime > 0 { theWindow.fadeOut(fadeTime, andDelete: false, withState: L) } else { theWindow.orderOut(nil) }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:allowTextEntry([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview can accept keyboard for web form entry.
func webview_allowTextEntry(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        L.push(theWindow.allowKeyboardEntry)
    } else {
        theWindow.allowKeyboardEntry = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:deleteOnClose([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview should delete itself when its window is closed.
func webview_deleteOnClose(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        L.push(theWindow.deleteOnClose)
    } else {
        theWindow.deleteOnClose = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:darkMode([state]) -> bool
/// Method
/// Set or display whether or not the `hs.webview` window should display in dark mode.
func webview_darkMode(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_type(L, 2) == LUA_TNONE {
        L.push(theWindow.darkMode)
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
func webview_closeOnEscape(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        L.push(theWindow.closeOnEscape)
    } else {
        theWindow.closeOnEscape = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:hswindow() -> hs.window object
/// Method
/// Returns an hs.window object for the webview so that you can use hs.window methods on it.
func webview_hswindow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    let windowID = CGWindowID(theWindow.windowNumber)
    lua_getglobal(L, "require")

    L.push("hs.window")

    lua_pcall(L, 1, 1, 0)
    lua_getfield(L, -1, "windowForID")
    L.push(Int(windowID))
    lua_call(L, 1, 1)
    return 1
}

/// hs.webview:isVisible() -> boolean
/// Method
/// Checks to see if a webview window is visible or not.
func webview_isVisible(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    L.push(theWindow.isVisible)
    return 1
}

/// hs.webview:windowTitle([title]) -> webviewObject
/// Method
/// Sets the title for the webview window.
func webview_windowTitle(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_isnoneornil(L, 2) {
        theWindow.titleFollow = true
        let windowTitle = (theWindow.contentView as? HSWebViewView)?.title ?? "<no title>"
        theWindow.title = windowTitle
    } else {
        luaL_checktype(L, 2, LUA_TSTRING)
        theWindow.titleFollow = false
        theWindow.title = lua_tovalue(L, at: 2) as! String
    }
    lua_settop(L, 1)
    return 1
}

/// hs.webview:titleVisibility([state]) -> webviewObject | string
/// Function
/// Get or set whether or not the title text appears in the webview window.
func webview_titleVisibility(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    let mapping: [String: NSWindow.TitleVisibility] = [
        "visible": .visible,
        "hidden": .hidden,
    ]

    if lua_gettop(L) == 1 {
        let current = theWindow.titleVisibility
        let value = mapping.first(where: { $0.value == current })?.key
        if let value = value {
            lua_pushany(L, value as NSString)
        } else {
            lua_pushnil(L)
        }
    } else {
        let key = lua_tovalue(L, at: 2) as? String ?? ""
        if let value = mapping[key] {
            theWindow.titleVisibility = value
            lua_pushvalue(L, 1)
        } else {
            let keys = mapping.keys.joined(separator: "', '")
            throw LuaCallError("bad argument #2: must be one of '\(keys)'")
        }
    }
    return 1
}

// NOTE: wrapped in init.lua
func webview_windowStyle(_ L: LuaState) throws -> CInt {
    let theWindow = wv_getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        L.push(Int(theWindow.styleMask.rawValue))
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
func webview_level(_ L: LuaState) throws -> CInt {
    precondition(lua_gettop(L) >= 1, "webview_level requires at least 1 argument (self)")
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_gettop(L) == 1 {
        L.push(Int(theWindow.level.rawValue))
    } else {
        let targetLevel = lua_tointeger(L, 2)
        let minLevel = CGWindowLevelForKey(.minimumWindow)
        let maxLevel = CGWindowLevelForKey(.maximumWindow)
        if targetLevel >= Int(minLevel) && targetLevel <= Int(maxLevel) {
            theWindow.level = NSWindow.Level(rawValue: Int(targetLevel))
        } else {
            throw LuaCallError("window level must be between \(minLevel) and \(maxLevel) inclusive")
        }
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:bringToFront([aboveEverything]) -> webviewObject
/// Method
/// Places the drawing object on top of normal windows
func webview_bringToFront(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    theWindow.level = lua_toboolean(L, 2) != 0 ? .screenSaver : .floating
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:sendToBack() -> webviewObject
/// Method
/// Places the webview object behind normal windows, between the desktop wallpaper and desktop icons
func webview_sendToBack(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    theWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:alpha([alpha]) -> webviewObject | currentValue
/// Method
/// Get or set the alpha level of the window containing the hs.webview object.
func webview_alpha(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_gettop(L) == 1 {
        L.push(lua_Number(theWindow.alphaValue))
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
func webview_shadow(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_type(L, 2) == LUA_TNONE {
        L.push(theWindow.hasShadow)
    } else {
        theWindow.hasShadow = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

func webview_orderHelper(_ L: UnsafeMutablePointer<lua_State>!, mode: NSWindow.OrderingMode) -> Int32 {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)
    var relativeTo: Int = 0

    if lua_gettop(L) > 1 {
        relativeTo = wv_getWindowFromUD(L, 2).windowNumber
    }

    theWindow.order(mode, relativeTo: relativeTo)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:orderAbove([webview2]) -> webviewObject
/// Method
/// Moves webview object above webview2, or all webview objects in the same presentation level, if webview2 is not given.
func webview_orderAbove(_ L: LuaState) throws -> CInt {
    return webview_orderHelper(L, mode: .above)
}

/// hs.webview:orderBelow([webview2]) -> webviewObject
/// Method
/// Moves webview object below webview2, or all webview objects in the same presentation level, if webview2 is not given.
func webview_orderBelow(_ L: LuaState) throws -> CInt {
    return webview_orderHelper(L, mode: .below)
}

// NOTE: wrapped in init.lua
func webview_delete(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_gettop(L) == 1 || !theWindow.isVisible {
        theWindow.close()
        L.push(wv_userdata_gc)
        lua_pushvalue(L, 1)
        if lua_pcall(L, 1, 0, 0) != LUA_OK {
            os_log(.debug, "%{public}s", String(format: "%s:error invoking _gc for delete method:%s", wv_USERDATA_TAG, lua_tostring(L, -1)!))
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
func webview_behavior(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    if lua_gettop(L) == 1 {
        L.push(Int(theWindow.collectionBehavior.rawValue))
    } else {
        let newLevel = lua_tointeger(L, 2)
        theWindow.collectionBehavior = NSWindow.CollectionBehavior(rawValue: UInt(newLevel))
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:windowCallback(fn) -> webviewObject
/// Method
/// Set or clear a callback for updates to the webview window
func webview_windowCallback(_ L: LuaState) throws -> CInt {
    luaL_checkudata(L, 1, wv_USERDATA_TAG)
    let theWindow = wv_getWindowFromUD(L, 1)

    theWindow.windowCallback = nil
    if lua_type(L, 2) == LUA_TFUNCTION {
        theWindow.windowCallback = L.ref(index: 2)
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
    L.push(Int(NSWindow.StyleMask.borderless.rawValue));          lua_setfield(L, -2, "borderless")
    L.push(Int(NSWindow.StyleMask.titled.rawValue));              lua_setfield(L, -2, "titled")
    L.push(Int(NSWindow.StyleMask.closable.rawValue));            lua_setfield(L, -2, "closable")
    L.push(Int(NSWindow.StyleMask.miniaturizable.rawValue));      lua_setfield(L, -2, "miniaturizable")
    L.push(Int(NSWindow.StyleMask.resizable.rawValue));           lua_setfield(L, -2, "resizable")
    L.push(Int(NSWindow.StyleMask.texturedBackground.rawValue));  lua_setfield(L, -2, "texturedBackground")
    L.push(Int(NSWindow.StyleMask.fullSizeContentView.rawValue)); lua_setfield(L, -2, "fullSizeContentView")
    L.push(Int(NSWindow.StyleMask.utilityWindow.rawValue));       lua_setfield(L, -2, "utility")
    L.push(Int(NSWindow.StyleMask.nonactivatingPanel.rawValue));  lua_setfield(L, -2, "nonactivating")
    L.push(Int(NSWindow.StyleMask.hudWindow.rawValue));           lua_setfield(L, -2, "HUD")
    return 1
}

/// hs.webview.certificateOIDs[]
/// Constant
/// A table of common OID values found in SSL certificates.
func wv_pushCertificateOIDs(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
        lua_pushany(L, oid as NSString)
        lua_setfield(L, -2, name)
    }
    return 1
}

// MARK: - NS<->Lua conversion tools

func wv_luaTo_HSWebViewWindow(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any! {
    if luaL_testudata(L, idx, wv_USERDATA_TAG) != nil {
        return wv_getWindowFromUD(L, idx)
    } else {
        os_log(.error, "%{public}s", String(format: "expected %s object, found %s", wv_USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

func wv_HSWebViewWindow_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    precondition(L != nil, "wv_HSWebViewWindow_toLua: Lua state must not be nil")
    precondition(obj != nil, "wv_HSWebViewWindow_toLua: obj must not be nil")
    let theWindow = obj as! HSWebViewWindow

    if theWindow.udRef == nil {
        let windowPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        windowPtr.pointee = Unmanaged.passRetained(theWindow).toOpaque()
        luaL_getmetatable(L, wv_USERDATA_TAG)
        lua_setmetatable(L, -2)
        theWindow.udRef = L.ref(index: -1)
    }

    theWindow.udRef!.push(onto: L)
    return 1
}

func wv_pushAny(_ L: UnsafeMutablePointer<lua_State>!, _ value: Any?, depth: Int = 0) {
    precondition(L != nil, "wv_pushAny: Lua state must not be nil")

    if depth >= kMaxWebviewRecursionDepth {
        os_log(.error, "wv_pushAny: recursion depth limit (%d) reached, pushing nil", kMaxWebviewRecursionDepth)
        lua_pushnil(L)
        return
    }

    guard let value = value else {
        lua_pushnil(L)
        return
    }

    switch value {
    case let window as HSWebViewWindow:
        _ = wv_HSWebViewWindow_toLua(L, window)
    case let toolbar as HSToolbar:
        _ = wv_HSToolbar_toLua(L, toolbar)
    case let item as NSToolbarItem:
        _ = wv_NSToolbarItem_toLua(L, item)
    case let dataStore as WKWebsiteDataStore:
        _ = wv_WKWebsiteDataStore_toLua(L, dataStore)
    case let record as WKWebsiteDataRecord:
        _ = wv_WKWebsiteDataRecord_toLua(L, record)
    case let message as WKScriptMessage:
        _ = wv_WKScriptMessage_toLua(L, message)
    case let script as WKUserScript:
        _ = wv_WKUserScript_toLua(L, script)
    case let navigationAction as WKNavigationAction:
        _ = wv_WKNavigationAction_toLua(L, navigationAction, depth: depth + 1)
    case let navigationResponse as WKNavigationResponse:
        _ = wv_WKNavigationResponse_toLua(L, navigationResponse, depth: depth + 1)
    case let frameInfo as WKFrameInfo:
        _ = wv_WKFrameInfo_toLua(L, frameInfo, depth: depth + 1)
    case let item as WKBackForwardListItem:
        _ = wv_WKBackForwardListItem_toLua(L, item)
    case let list as WKBackForwardList:
        _ = wv_WKBackForwardList_toLua(L, list, depth: depth + 1)
    case let navigation as WKNavigation:
        _ = wv_WKNavigation_toLua(L, navigation)
    case let features as WKWindowFeatures:
        _ = wv_WKWindowFeatures_toLua(L, features)
    case let challenge as URLAuthenticationChallenge:
        _ = wv_NSURLAuthenticationChallenge_toLua(L, challenge, depth: depth + 1)
    case let protectionSpace as URLProtectionSpace:
        _ = wv_NSURLProtectionSpace_toLua(L, protectionSpace)
    case let credential as URLCredential:
        _ = wv_NSURLCredential_toLua(L, credential)
    case let origin as WKSecurityOrigin:
        _ = wv_WKSecurityOrigin_toLua(L, origin)
    case let request as URLRequest:
        _ = wv_URLRequest_toLua(L, request)
    case let request as NSURLRequest:
        _ = wv_URLRequest_toLua(L, request as URLRequest)
    case let response as URLResponse:
        _ = wv_URLResponse_toLua(L, response)
    case let error as NSError:
        _ = wv_NSError_toLua(L, error)
    default:
        lua_pushany(L, value)
    }
}

func wv_URLRequest_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let request: URLRequest
    if let value = obj as? URLRequest {
        request = value
    } else if let value = obj as? NSURLRequest {
        request = value as URLRequest
    } else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    lua_pushany(L, request.mainDocumentURL as NSURL?);              lua_setfield(L, -2, "mainDocumentURL")
    lua_pushany(L, request.url as NSURL?);                          lua_setfield(L, -2, "URL")
    lua_pushany(L, request.allHTTPHeaderFields as NSDictionary?);   lua_setfield(L, -2, "HTTPHeaderFields")
    lua_pushany(L, request.httpBody as NSData?);                    lua_setfield(L, -2, "HTTPBody")
    lua_pushany(L, request.httpMethod as NSString?);                lua_setfield(L, -2, "HTTPMethod")

    L.push(lua_Number(request.timeoutInterval));       lua_setfield(L, -2, "timeoutInterval")
    L.push(request.httpShouldHandleCookies);  lua_setfield(L, -2, "HTTPShouldHandleCookies")
    L.push(request.httpShouldUsePipelining);  lua_setfield(L, -2, "HTTPShouldUsePipelining")

    let cachePolicyStr: String
    switch request.cachePolicy {
    case .useProtocolCachePolicy:       cachePolicyStr = "protocolCachePolicy"
    case .reloadIgnoringLocalCacheData: cachePolicyStr = "ignoreLocalCache"
    case .returnCacheDataElseLoad:      cachePolicyStr = "returnCacheOrLoad"
    case .returnCacheDataDontLoad:      cachePolicyStr = "returnCacheDontLoad"
    default:                            cachePolicyStr = "unknown"
    }
    L.push(cachePolicyStr); lua_setfield(L, -2, "cachePolicy")

    let networkServiceStr: String
    switch request.networkServiceType {
    case .default:    networkServiceStr = "default"
    case .voip:       networkServiceStr = "VoIP"
    case .video:      networkServiceStr = "video"
    case .background: networkServiceStr = "background"
    case .voice:      networkServiceStr = "voice"
    default:          networkServiceStr = "unknown"
    }
    L.push(networkServiceStr); lua_setfield(L, -2, "networkServiceType")

    return 1
}

func wv_URLResponse_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let response = obj as? URLResponse else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    L.push(Int(response.expectedContentLength)); lua_setfield(L, -2, "expectedContentLength")
    lua_pushany(L, response.suggestedFilename as NSString?);         lua_setfield(L, -2, "suggestedFilename")
    lua_pushany(L, response.mimeType as NSString?);                  lua_setfield(L, -2, "MIMEType")
    lua_pushany(L, response.textEncodingName as NSString?);          lua_setfield(L, -2, "textEncodingName")
    lua_pushany(L, response.url as NSURL?);                          lua_setfield(L, -2, "URL")

    if let httpResponse = response as? HTTPURLResponse {
        L.push(Int(httpResponse.statusCode)); lua_setfield(L, -2, "statusCode")
        lua_pushany(L, HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode) as NSString)
        lua_setfield(L, -2, "statusCodeDescription")
        lua_pushany(L, httpResponse.allHeaderFields as NSDictionary); lua_setfield(L, -2, "allHeaderFields")
    }

    return 1
}

func wv_toURLRequest(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> URLRequest? {
    precondition(L != nil, "wv_toURLRequest: Lua state must not be nil")
    let absIdx = lua_absindex(L, idx)
    assert(absIdx > 0, "wv_toURLRequest: absolute index must be positive")

    switch lua_type(L, absIdx) {
    case LUA_TTABLE:
        return wv_parseURLRequestTable(L, absIdx)
    case LUA_TSTRING:
        guard let urlString = lua_tovalue(L, at: absIdx) as? String,
              let url = URL(string: urlString) else {
            os_log(.error, "%{public}s", "invalid URL string passed as NSURLRequest")
            return nil
        }
        return URLRequest(url: url)
    default:
        os_log(.error, "%{public}s", "Unexpected type passed as a NSURLRequest: \(String(cString: lua_typename(L, lua_type(L, absIdx))))")
        return nil
    }
}

private func wv_parseURLRequestTable(_ L: UnsafeMutablePointer<lua_State>!, _ absIdx: Int32) -> URLRequest? {
    guard lua_getfield(L, absIdx, "URL") == LUA_TSTRING,
          let urlString = lua_tovalue(L, at: -1) as? String,
          let url = URL(string: urlString) else {
        lua_pop(L, 1)
        os_log(.error, "%{public}s", "URL field missing in NSURLRequest table")
        return nil
    }
    lua_pop(L, 1)

    var request = URLRequest(url: url)
    wv_applyRequestStringField(L, absIdx, field: "mainDocumentURL") { request.mainDocumentURL = URL(string: $0) }
    wv_applyRequestHTTPBody(L, absIdx, request: &request)
    wv_applyRequestStringField(L, absIdx, field: "HTTPMethod") { request.httpMethod = $0 }

    if lua_getfield(L, absIdx, "timeoutInterval") == LUA_TNUMBER {
        request.timeoutInterval = lua_tonumber(L, -1)
    }
    lua_pop(L, 1)

    wv_applyRequestBoolField(L, absIdx, field: "HTTPShouldHandleCookies") { request.httpShouldHandleCookies = $0 }
    wv_applyRequestBoolField(L, absIdx, field: "HTTPShouldUsePipelining") { request.httpShouldUsePipelining = $0 }
    wv_applyRequestCachePolicy(L, absIdx, request: &request)
    wv_applyRequestNetworkServiceType(L, absIdx, request: &request)
    wv_applyRequestHeaderFields(L, absIdx, request: &request)

    return request
}

private func wv_applyRequestStringField(_ L: UnsafeMutablePointer<lua_State>!, _ absIdx: Int32, field: String, apply: (String) -> Void) {
    if lua_getfield(L, absIdx, field) == LUA_TSTRING,
       let value = lua_tovalue(L, at: -1) as? String {
        apply(value)
    }
    lua_pop(L, 1)
}

private func wv_applyRequestBoolField(_ L: UnsafeMutablePointer<lua_State>!, _ absIdx: Int32, field: String, apply: (Bool) -> Void) {
    if lua_getfield(L, absIdx, field) == LUA_TBOOLEAN {
        apply(lua_toboolean(L, -1) != 0)
    }
    lua_pop(L, 1)
}

private func wv_applyRequestHTTPBody(_ L: UnsafeMutablePointer<lua_State>!, _ absIdx: Int32, request: inout URLRequest) {
    if lua_getfield(L, absIdx, "HTTPBody") == LUA_TSTRING {
        var size: Int = 0
        if let block = lua_tolstring(L, -1, &size) {
            request.httpBody = Data(bytes: block, count: size)
        }
    }
    lua_pop(L, 1)
}

private func wv_applyRequestCachePolicy(_ L: UnsafeMutablePointer<lua_State>!, _ absIdx: Int32, request: inout URLRequest) {
    if lua_getfield(L, absIdx, "cachePolicy") == LUA_TSTRING,
       let cp = lua_tovalue(L, at: -1) as? String {
        switch cp {
        case "protocolCachePolicy": request.cachePolicy = .useProtocolCachePolicy
        case "ignoreLocalCache":    request.cachePolicy = .reloadIgnoringLocalCacheData
        case "returnCacheOrLoad":   request.cachePolicy = .returnCacheDataElseLoad
        case "returnCacheDontLoad": request.cachePolicy = .returnCacheDataDontLoad
        default: break
        }
    }
    lua_pop(L, 1)
}

private func wv_applyRequestNetworkServiceType(_ L: UnsafeMutablePointer<lua_State>!, _ absIdx: Int32, request: inout URLRequest) {
    if lua_getfield(L, absIdx, "networkServiceType") == LUA_TSTRING,
       let nst = lua_tovalue(L, at: -1) as? String {
        switch nst {
        case "default":    request.networkServiceType = .default
        case "VoIP":       request.networkServiceType = .voip
        case "video":      request.networkServiceType = .video
        case "background": request.networkServiceType = .background
        case "voice":      request.networkServiceType = .voice
        default: break
        }
    }
    lua_pop(L, 1)
}

private func wv_applyRequestHeaderFields(_ L: UnsafeMutablePointer<lua_State>!, _ absIdx: Int32, request: inout URLRequest) {
    if lua_getfield(L, absIdx, "HTTPHeaderFields") == LUA_TTABLE,
       var fields = lua_tovalue(L, at: -1) as? [String: Any] {
        let reservedHeaders = ["Authorization", "Connection", "Host", "WWW-Authenticate", "Content-Length"]
        var toRemove: [String] = []

        for (key, value) in fields {
            if let numberValue = value as? NSNumber {
                fields[key] = numberValue.stringValue
            }
            guard fields[key] is String else {
                toRemove.append(key)
                continue
            }
            if reservedHeaders.contains(where: { key.caseInsensitiveCompare($0) == .orderedSame }) {
                toRemove.append(key)
            }
        }

        for item in toRemove { fields.removeValue(forKey: item) }
        request.allHTTPHeaderFields = fields as? [String: String]
    }
    lua_pop(L, 1)
}

func wv_WKNavigationAction_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!, depth: Int = 0) -> Int32 {
    let navAction = obj as! WKNavigationAction

    lua_newtable(L)
    wv_pushAny(L, navAction.request, depth: depth);      lua_setfield(L, -2, "request")
    wv_pushAny(L, navAction.sourceFrame, depth: depth);  lua_setfield(L, -2, "sourceFrame")
    wv_pushAny(L, navAction.targetFrame, depth: depth);  lua_setfield(L, -2, "targetFrame")
    L.push(Int(navAction.buttonNumber)); lua_setfield(L, -2, "buttonNumber")

    let theFlags = navAction.modifierFlags.rawValue
    lua_newtable(L)
    if navAction.modifierFlags.contains(.capsLock) { L.push(true); lua_setfield(L, -2, "capslock") }
    if navAction.modifierFlags.contains(.shift)    { L.push(true); lua_setfield(L, -2, "shift") }
    if navAction.modifierFlags.contains(.control)  { L.push(true); lua_setfield(L, -2, "ctrl") }
    if navAction.modifierFlags.contains(.option)   { L.push(true); lua_setfield(L, -2, "alt") }
    if navAction.modifierFlags.contains(.command)  { L.push(true); lua_setfield(L, -2, "cmd") }
    if navAction.modifierFlags.contains(.function) { L.push(true); lua_setfield(L, -2, "fn") }
    L.push(Int(theFlags)); lua_setfield(L, -2, "_raw")
    lua_setfield(L, -2, "modifierFlags")

    switch navAction.navigationType {
    case .linkActivated:   L.push("linkActivated")
    case .formSubmitted:   L.push("formSubmitted")
    case .backForward:     L.push("backForward")
    case .reload:          L.push("reload")
    case .formResubmitted: L.push("formResubmitted")
    case .other:           L.push("other")
    @unknown default:      L.push("unknown")
    }
    lua_setfield(L, -2, "navigationType")
    return 1
}

func wv_WKNavigationResponse_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!, depth: Int = 0) -> Int32 {
    let navResponse = obj as! WKNavigationResponse

    lua_newtable(L)
    L.push(navResponse.canShowMIMEType); lua_setfield(L, -2, "canShowMIMEType")
    L.push(navResponse.isForMainFrame);  lua_setfield(L, -2, "forMainFrame")
    wv_pushAny(L, navResponse.response, depth: depth);                     lua_setfield(L, -2, "response")
    return 1
}

func wv_WKFrameInfo_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!, depth: Int = 0) -> Int32 {
    let frameInfo = obj as! WKFrameInfo

    lua_newtable(L)
    L.push(frameInfo.isMainFrame); lua_setfield(L, -2, "mainFrame")
    wv_pushAny(L, frameInfo.request, depth: depth);                 lua_setfield(L, -2, "request")
    wv_pushAny(L, frameInfo.securityOrigin, depth: depth);          lua_setfield(L, -2, "securityOrigin")
    return 1
}

func wv_WKBackForwardListItem_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let item = obj as! WKBackForwardListItem

    lua_newtable(L)
    lua_pushany(L, item.url as NSURL);        lua_setfield(L, -2, "URL")
    lua_pushany(L, item.initialURL as NSURL); lua_setfield(L, -2, "initialURL")
    lua_pushany(L, item.title as NSString?);  lua_setfield(L, -2, "title")
    return 1
}

func wv_WKBackForwardList_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!, depth: Int = 0) -> Int32 {
    let theList = obj as? WKBackForwardList

    lua_newtable(L)
    if let theList = theList {
        for value in theList.backList {
            wv_pushAny(L, value, depth: depth)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        if let currentItem = theList.currentItem {
            wv_pushAny(L, currentItem, depth: depth)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        L.push(Int(luaL_len(L, -1))); lua_setfield(L, -2, "current")

        for value in theList.forwardList {
            wv_pushAny(L, value, depth: depth)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
    } else {
        L.push(0); lua_setfield(L, -2, "current")
    }
    return 1
}

func wv_WKNavigation_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let navID = obj as! WKNavigation
    let str = String(describing: Unmanaged.passUnretained(navID as AnyObject).toOpaque())
    L.push(str)
    return 1
}

func wv_NSError_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    guard let theError = obj as? NSError else { lua_pushnil(L); return 1 }

    lua_newtable(L)
    L.push(Int(theError.code));                    lua_setfield(L, -2, "code")
    lua_pushany(L, theError.domain as NSString);                    lua_setfield(L, -2, "domain")
    lua_pushany(L, theError.helpAnchor as NSString?);               lua_setfield(L, -2, "helpAnchor")
    lua_pushany(L, theError.localizedDescription as NSString);      lua_setfield(L, -2, "localizedDescription")
    lua_pushany(L, theError.localizedRecoveryOptions as NSArray?);  lua_setfield(L, -2, "localizedRecoveryOptions")
    lua_pushany(L, theError.localizedRecoverySuggestion as NSString?); lua_setfield(L, -2, "localizedRecoverySuggestion")
    lua_pushany(L, theError.localizedFailureReason as NSString?);   lua_setfield(L, -2, "localizedFailureReason")
    return 1
}

func wv_WKWindowFeatures_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let features = obj as! WKWindowFeatures

    lua_newtable(L)
    if let v = features.menuBarVisibility   { L.push(v.boolValue); lua_setfield(L, -2, "menuBarVisibility") }
    if let v = features.statusBarVisibility { L.push(v.boolValue); lua_setfield(L, -2, "statusBarVisibility") }
    if let v = features.toolbarsVisibility  { L.push(v.boolValue); lua_setfield(L, -2, "toolbarsVisibility") }
    if let v = features.allowsResizing      { L.push(v.boolValue); lua_setfield(L, -2, "allowsResizing") }
    if let v = features.x      { L.push(v.doubleValue); lua_setfield(L, -2, "x") }
    if let v = features.y      { L.push(v.doubleValue); lua_setfield(L, -2, "y") }
    if let v = features.height { L.push(v.doubleValue); lua_setfield(L, -2, "h") }
    if let v = features.width  { L.push(v.doubleValue); lua_setfield(L, -2, "w") }
    return 1
}

func wv_NSURLAuthenticationChallenge_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!, depth: Int = 0) -> Int32 {
    let challenge = obj as! URLAuthenticationChallenge

    lua_newtable(L)
    L.push(Int(challenge.previousFailureCount)); lua_setfield(L, -2, "previousFailureCount")
    wv_pushAny(L, challenge.error as NSError?, depth: depth);                     lua_setfield(L, -2, "error")
    wv_pushAny(L, challenge.failureResponse, depth: depth);                       lua_setfield(L, -2, "failureResponse")
    wv_pushAny(L, challenge.proposedCredential, depth: depth);                    lua_setfield(L, -2, "proposedCredential")
    wv_pushAny(L, challenge.protectionSpace, depth: depth);                       lua_setfield(L, -2, "protectionSpace")
    return 1
}

func wv_SecCertificateRef_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ certRef: SecCertificate!) -> Int32 {
    lua_newtable(L)
    var commonName: CFString?
    SecCertificateCopyCommonName(certRef, &commonName)
    if let commonName = commonName {
        lua_pushany(L, commonName as NSString); lua_setfield(L, -2, "commonName")
    }
    if let values = SecCertificateCopyValues(certRef, nil, nil) {
        lua_pushany(L, values as NSDictionary)
        lua_setfield(L, -2, "values")
    }
    return 1
}

func wv_NSURLProtectionSpace_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let theSpace = obj as! URLProtectionSpace

    lua_newtable(L)
    L.push(theSpace.isProxy());                   lua_setfield(L, -2, "isProxy")
    L.push(Int(theSpace.port));                   lua_setfield(L, -2, "port")
    L.push(theSpace.receivesCredentialSecurely);  lua_setfield(L, -2, "receivesCredentialSecurely")

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
    lua_pushany(L, method as NSString); lua_setfield(L, -2, "authenticationMethod")
    lua_pushany(L, (theSpace.host) as NSString); lua_setfield(L, -2, "host")
    lua_pushany(L, theSpace.protocol as NSString?); lua_setfield(L, -2, "protocol")

    let proxyMap: [String: String] = [
        NSURLProtectionSpaceHTTPProxy: "http",
        NSURLProtectionSpaceHTTPSProxy: "https",
        NSURLProtectionSpaceFTPProxy: "ftp",
        NSURLProtectionSpaceSOCKSProxy: "socks",
    ]
    let proxy = proxyMap[theSpace.proxyType ?? ""] ?? "unknown"
    lua_pushany(L, proxy as NSString); lua_setfield(L, -2, "proxyType")
    lua_pushany(L, theSpace.realm as NSString?); lua_setfield(L, -2, "realm")

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
    let credential = obj as! URLCredential

    lua_newtable(L)
    L.push(credential.hasPassword); lua_setfield(L, -2, "hasPassword")
    switch credential.persistence {
    case .none:           L.push("none")
    case .forSession:     L.push("session")
    case .permanent:      L.push("permanent")
    case .synchronizable: L.push("synchronized")
    @unknown default:     L.push("unknown")
    }
    lua_setfield(L, -2, "persistence")
    lua_pushany(L, credential.user as NSString?);     lua_setfield(L, -2, "user")
    lua_pushany(L, credential.password as NSString?);  lua_setfield(L, -2, "password")
    return 1
}

func wv_WKSecurityOrigin_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any!) -> Int32 {
    let origin = obj as! WKSecurityOrigin

    lua_newtable(L)
    lua_pushany(L, origin.host as NSString);     lua_setfield(L, -2, "host")
    L.push(Int(origin.port));    lua_setfield(L, -2, "port")
    lua_pushany(L, origin.protocol as NSString);  lua_setfield(L, -2, "protocol")
    return 1
}

// MARK: - Lua Framework Stuff

func wv_userdata_tostring(_ L: LuaState) throws -> CInt {
    let theWindow = wv_getWindowFromUD(L, 1)
    let theView = theWindow.contentView as? HSWebViewView
    let title = theView?.title ?? ""
    let ptr = lua_topointer(L, 1)!
    let str = "\(wv_USERDATA_TAG): \(title.isEmpty ? "" : title) (\(ptr))"
    L.push(str)
    return 1
}

func wv_userdata_eq(_ L: LuaState) throws -> CInt {
    let theWindow = wv_getWindowFromUD(L, 1)
    let otherWindow = wv_getWindowFromUD(L, 2)
    L.push(theWindow === otherWindow)
    return 1
}

func wv_userdata_gc(_ L: LuaState) throws -> CInt {
    precondition(lua_gettop(L) >= 1, "wv_userdata_gc requires at least 1 argument")
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

    theWindow.udRef = nil
    theWindow.windowCallback = nil
    if let theView = theView {
        theView.navigationCallback = nil
        theView.policyCallback = nil
        theView.sslCallback = nil
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
    theWindow.lsCanary = tmpCanary

    theWindow.delegate = nil

    return 0
}

func wv_meta_gc(_ L: LuaState) throws -> CInt {
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

@_cdecl("luaopen_hs_libwebview")
public func luaopen_hs_libwebview(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "luaopen_hs_libwebview: Lua state must not be nil")
    return runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        wv_refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        luaL_newmetatable(L, wv_USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")

        // Webview Related
        L.push(webview_goBack);                     lua_setfield(L, -2, "goBack")
        L.push(webview_goForward);                  lua_setfield(L, -2, "goForward")
        L.push(webview_url);                        lua_setfield(L, -2, "url")
        L.push(webview_title);                      lua_setfield(L, -2, "title")
        L.push(webview_navigationID);               lua_setfield(L, -2, "navigationID")
        L.push(webview_reload);                     lua_setfield(L, -2, "reload")
        L.push(webview_transparent);                lua_setfield(L, -2, "transparent")
        L.push(webview_magnification);              lua_setfield(L, -2, "magnification")
        L.push(webview_allowMagnificationGestures); lua_setfield(L, -2, "allowMagnificationGestures")
        L.push(webview_allowNewWindows);            lua_setfield(L, -2, "allowNewWindows")
        L.push(webview_allowNavigationGestures);    lua_setfield(L, -2, "allowNavigationGestures")
        L.push(webview_isOnlySecureContent);        lua_setfield(L, -2, "isOnlySecureContent")
        L.push(webview_estimatedProgress);          lua_setfield(L, -2, "estimatedProgress")
        L.push(webview_loading);                    lua_setfield(L, -2, "loading")
        L.push(webview_stopLoading);                lua_setfield(L, -2, "stopLoading")
        L.push(webview_html);                       lua_setfield(L, -2, "html")
        L.push(webview_historyList);                lua_setfield(L, -2, "historyList")
        L.push(webview_navigationCallback);         lua_setfield(L, -2, "navigationCallback")
        L.push(webview_policyCallback);             lua_setfield(L, -2, "policyCallback")
        L.push(webview_sslCallback);                lua_setfield(L, -2, "sslCallback")
        L.push(webview_children);                   lua_setfield(L, -2, "children")
        L.push(webview_parent);                     lua_setfield(L, -2, "parent")
        L.push(webview_evaluateJavaScript);         lua_setfield(L, -2, "evaluateJavaScript")
        L.push(webview_privateBrowsing);            lua_setfield(L, -2, "privateBrowsing")
        L.push(webview_userAgent);                  lua_setfield(L, -2, "userAgent")
        L.push(webview_certificateChain);           lua_setfield(L, -2, "certificateChain")
        L.push(webview_examineInvalidCertificates); lua_setfield(L, -2, "examineInvalidCertificates")

        // Window related
        L.push(webview_darkMode);                   lua_setfield(L, -2, "darkMode")
        L.push(webview_titleVisibility);            lua_setfield(L, -2, "titleVisibility")
        L.push(webview_show);                       lua_setfield(L, -2, "show")
        L.push(webview_hide);                       lua_setfield(L, -2, "hide")
        L.push(webview_closeOnEscape);              lua_setfield(L, -2, "closeOnEscape")
        L.push(webview_allowTextEntry);             lua_setfield(L, -2, "allowTextEntry")
        L.push(webview_hswindow);                   lua_setfield(L, -2, "hswindow")
        L.push(webview_windowTitle);                lua_setfield(L, -2, "windowTitle")
        L.push(webview_deleteOnClose);              lua_setfield(L, -2, "deleteOnClose")
        L.push(webview_bringToFront);               lua_setfield(L, -2, "bringToFront")
        L.push(webview_sendToBack);                 lua_setfield(L, -2, "sendToBack")
        L.push(webview_shadow);                     lua_setfield(L, -2, "shadow")
        L.push(webview_alpha);                      lua_setfield(L, -2, "alpha")
        L.push(webview_orderAbove);                 lua_setfield(L, -2, "orderAbove")
        L.push(webview_orderBelow);                 lua_setfield(L, -2, "orderBelow")
        L.push(webview_behavior);                   lua_setfield(L, -2, "behavior")
        L.push(webview_windowCallback);             lua_setfield(L, -2, "windowCallback")
        L.push(webview_topLeft);                    lua_setfield(L, -2, "topLeft")
        L.push(webview_size);                       lua_setfield(L, -2, "size")
        L.push(webview_isVisible);                  lua_setfield(L, -2, "isVisible")

        L.push(webview_delete);                     lua_setfield(L, -2, "_delete")
        L.push(webview_windowStyle);                lua_setfield(L, -2, "_windowStyle")
        L.push(webview_level);                      lua_setfield(L, -2, "level")

        L.push(wv_userdata_tostring);               lua_setfield(L, -2, "__tostring")
        L.push(wv_userdata_eq);                     lua_setfield(L, -2, "__eq")
        L.push(wv_userdata_gc);                     lua_setfield(L, -2, "__gc")

        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(webview_new); lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(wv_meta_gc); lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        wv_windowMasksTable(L);    lua_setfield(L, -2, "windowMasks")
        wv_pushCertificateOIDs(L); lua_setfield(L, -2, "certificateOIDs")
    }
}
