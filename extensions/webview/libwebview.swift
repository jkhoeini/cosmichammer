import Foundation
import Cocoa
import WebKit
import LuaSkin

private let USERDATA_TAG = "hs.webview"
private let USERDATA_UCC_TAG = "hs.webview.usercontent"
private let USERDATA_DS_TAG = "hs.webview.datastore"
private let USERDATA_TB_TAG = "hs.webview.toolbar"

private var refTable: Int32 = 0
private var HSWebViewProcessPool: WKProcessPool?
private var delayTimers: NSMapTable<HSWebViewView, NSTimer>?

private func RectWithFlippedYCoordinate(_ theRect: NSRect) -> NSRect {
    return NSMakeRect(theRect.origin.x,
                      NSScreen.screens[0].frame.size.height - theRect.origin.y - theRect.size.height,
                      theRect.size.width,
                      theRect.size.height)
}

// forward declarations handled by Swift naturally

func delayUntilViewStopsLoading(_ theView: HSWebViewView, block: @escaping () -> Void) {
    if delayTimers == nil { delayTimers = NSMapTable<HSWebViewView, NSTimer>.strongToWeakObjects() }

    if let existingTimer = delayTimers?.object(forKey: theView) {
        existingTimer.invalidate()
        delayTimers?.removeObject(forKey: theView)
    }

    let newDelay = Timer(timeInterval: 0.001, repeats: true) { timer in
        if timer.isValid {
            if !theView.isLoading {
                theView.stopLoading()
                delayTimers?.removeObject(forKey: theView)
                timer.invalidate()
                block()
            }
        }
    }

    delayTimers?.setObject(newDelay, forKey: theView)
    newDelay.fireDate = Date(timeIntervalSinceNow: 0)
    RunLoop.current.add(newDelay, forMode: .common)
}

// MARK: - HSWebViewWindow

class HSWebViewWindow: NSPanel, NSWindowDelegate {
    var parent: HSWebViewWindow?
    var children: NSMutableArray = NSMutableArray()
    var udRef: Int32 = LUA_NOREF
    var windowCallback: Int32 = LUA_NOREF
    var allowKeyboardEntry: Bool = false
    var darkMode: Bool = false
    var titleFollow: Bool = true
    var deleteOnClose: Bool = false
    var closeOnEscape: Bool = false
    var lsCanary: LSGCCanary = (0, 0)

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        let flippedRect = RectWithFlippedYCoordinate(contentRect)
        self.setFrameOrigin(flippedRect.origin)

        self.isReleasedWhenClosed = false
        self.backgroundColor = .clear
        self.isOpaque = true
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.isRestorable = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        self.level = .normal

        self.parent = nil
        self.children = NSMutableArray()
        self.udRef = LUA_NOREF
        self.windowCallback = LUA_NOREF
        self.titleFollow = true
        self.deleteOnClose = false
        self.allowKeyboardEntry = false
        self.closeOnEscape = false
        self.darkMode = false

        self.delegate = self
    }

    var darkModeEnabled: Bool { return darkMode }

    override var canBecomeKey: Bool { return allowKeyboardEntry }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return (self.styleMask.contains(.closable))
    }

    func windowWillClose(_ notification: Notification) {
        let skin = LuaSkin.shared(withState: nil)!
        let L = skin.L!

        if !skin.checkGCCanary(lsCanary) { return }
        _lua_stackguard_entry(L)

        if windowCallback != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: windowCallback)
            skin.pushNSObject("closing" as NSString)
            skin.pushNSObject(self)
            skin.protectedCallAndError("hs.webview:windowCallback:closing", nargs: 2, nresults: 0)
        }
        if deleteOnClose {
            lua_pushcfunction(L, userdata_gc)
            skin.pushNSObject(self)
            if lua_pcall(L, 1, 0, 0) != LUA_OK {
                skin.logError(String(format: "%s:error invoking _gc for deleteOnClose:%s", USERDATA_TAG, lua_tostring(L, -1)!))
                lua_pop(L, 1)
            }
        }
        _lua_stackguard_exit(L)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.shared(withState: nil)!
                _lua_stackguard_entry(skin.L)
                skin.pushLuaRef(refTable, ref: self.windowCallback)
                skin.pushNSObject("focusChange" as NSString)
                skin.pushNSObject(self)
                lua_pushboolean(skin.L, 1)
                skin.protectedCallAndError("hs.webview:windowCallback:focusChange", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.L)
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.shared(withState: nil)!
                _lua_stackguard_entry(skin.L)
                skin.pushLuaRef(refTable, ref: self.windowCallback)
                skin.pushNSObject("focusChange" as NSString)
                skin.pushNSObject(self)
                lua_pushboolean(skin.L, 0)
                skin.protectedCallAndError("hs.webview:windowCallback:focusChange", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.L)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.shared(withState: nil)!
                _lua_stackguard_entry(skin.L)
                skin.pushLuaRef(refTable, ref: self.windowCallback)
                skin.pushNSObject("frameChange" as NSString)
                skin.pushNSObject(self)
                skin.pushNSRect(RectWithFlippedYCoordinate(self.frame))
                skin.protectedCallAndError("hs.webview:windowCallback:frameChange:resize", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.L)
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.shared(withState: nil)!
                _lua_stackguard_entry(skin.L)
                skin.pushLuaRef(refTable, ref: self.windowCallback)
                skin.pushNSObject("frameChange" as NSString)
                skin.pushNSObject(self)
                skin.pushNSRect(RectWithFlippedYCoordinate(self.frame))
                skin.protectedCallAndError("hs.webview:windowCallback:frameChange:move", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.L)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if closeOnEscape { super.cancelOperation(sender) }
    }

    func fadeIn(_ fadeTime: TimeInterval) {
        self.alphaValue = 0.0
        self.makeKeyAndOrderFront(nil)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = fadeTime
        self.animator().alphaValue = 1.0
        NSAnimationContext.endGrouping()
    }

    func fadeOut(_ fadeTime: TimeInterval, andDelete deleteWindow: Bool, withState L: OpaquePointer!) {
        NSAnimationContext.beginGrouping()
        weak var bself = self

        let outerSkin = LuaSkin.shared(withState: L)!
        let lsCanary = outerSkin.createGCCanary()
        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            let skin = LuaSkin.shared(withState: nil)!
            if !skin.checkGCCanary(lsCanary) { return }
            if let mySelf = bself {
                if deleteWindow {
                    mySelf.close()
                    lua_pushcfunction(L, userdata_gc)
                    skin.pushLuaRef(refTable, ref: mySelf.udRef)
                    if lua_pcall(L, 1, 0, 0) != LUA_OK {
                        skin.logBreadcrumb(String(format: "%s:error invoking _gc for delete (with fade) method:%s", USERDATA_TAG, lua_tostring(L, -1)!))
                        lua_pop(L, 1)
                    }
                } else {
                    mySelf.orderOut(nil)
                    mySelf.alphaValue = 1.0
                }
            }
            var mutableCanary = lsCanary
            skin.destroyGCCanary(&mutableCanary)
        }
        self.animator().alphaValue = 0.0
        NSAnimationContext.endGrouping()
    }
}

// MARK: - HSWebViewView

class HSWebViewView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    var navigationCallback: Int32 = LUA_NOREF
    var policyCallback: Int32 = LUA_NOREF
    var sslCallback: Int32 = LUA_NOREF
    var allowNewWindows: Bool = true
    var examineInvalidCertificates: Bool = false
    var trackingID: WKNavigation?

    override init(frame frameRect: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frameRect, configuration: configuration)
        self.navigationDelegate = self
        self.uiDelegate = self
        self.navigationCallback = LUA_NOREF
        self.policyCallback = LUA_NOREF
        self.sslCallback = LUA_NOREF
        self.allowNewWindows = true
        self.examineInvalidCertificates = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var isFlipped: Bool { return true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    // MARK: -- WKNavigationDelegate

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        navigationCallbackFor("didReceiveServerRedirectForProvisionalNavigation", forView: webView, withNavigation: navigation, withError: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationCallbackFor("didStartProvisionalNavigation", forView: webView, withNavigation: navigation, withError: nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationCallbackFor("didCommitNavigation", forView: webView, withNavigation: navigation, withError: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let windowTitle = webView.title ?? "<no title>"
        if (webView.window as? HSWebViewWindow)?.titleFollow == true { webView.window?.title = windowTitle }
        navigationCallbackFor("didFinishNavigation", forView: webView, withNavigation: navigation, withError: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigationCallbackFor("didFailNavigation", forView: webView, withNavigation: navigation, withError: error as NSError) {
            handleNavigationFailure(error as NSError, forView: webView)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if navigationCallbackFor("didFailProvisionalNavigation", forView: webView, withNavigation: navigation, withError: nsError) {
            if nsError.code == NSURLErrorUnsupportedURL {
                if let destinationURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                    if NSWorkspace.shared.open(destinationURL) { return }
                } else {
                    LuaSkin.logWarn(String(format: "%s:didFailProvisionalNavigation missing NSURLErrorFailingURLErrorKey", USERDATA_TAG))
                }
            }
            handleNavigationFailure(nsError, forView: webView)
        }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let hostName = webView.url?.host ?? ""
        let authenticationMethod = challenge.protectionSpace.authenticationMethod

        if authenticationMethod == NSURLAuthenticationMethodDefault
            || authenticationMethod == NSURLAuthenticationMethodHTTPBasic
            || authenticationMethod == NSURLAuthenticationMethodHTTPDigest {

            let previousCredential = challenge.proposedCredential

            if self.policyCallback != LUA_NOREF && challenge.previousFailureCount < 3 {
                let skin = LuaSkin.shared(withState: nil)!
                _lua_stackguard_entry(skin.L)
                skin.pushLuaRef(refTable, ref: self.policyCallback)
                lua_pushstring(skin.L, "authenticationChallenge")
                skin.pushNSObject(webView.window as? HSWebViewWindow)
                skin.pushNSObject(challenge)

                if !skin.protectedCallAndTraceback(3, nresults: 1) {
                    let errorMsg = String(cString: lua_tostring(skin.L, -1))
                    skin.logError("hs.webview:policyCallback() authenticationChallenge callback error: \(errorMsg)")
                } else {
                    if lua_type(skin.L, -1) == LUA_TTABLE {
                        lua_getfield(skin.L, -1, "user")
                        let userName = (lua_type(skin.L, -1) == LUA_TSTRING) ? (skin.toNSObject(atIndex: -1) as? String ?? "") : ""
                        lua_pop(skin.L, 1)

                        lua_getfield(skin.L, -1, "password")
                        let password = (lua_type(skin.L, -1) == LUA_TSTRING) ? (skin.toNSObject(atIndex: -1) as? String ?? "") : ""
                        lua_pop(skin.L, 1)

                        let credential = URLCredential(user: userName, password: password, persistence: .forSession)
                        completionHandler(.useCredential, credential)
                        lua_pop(skin.L, 1)
                        _lua_stackguard_exit(skin.L)
                        return
                    } else if !lua_toboolean(skin.L, -1).boolValue {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        lua_pop(skin.L, 1)
                        _lua_stackguard_exit(skin.L)
                        return
                    }
                }
                lua_pop(skin.L, 1)
                _lua_stackguard_exit(skin.L)
            }

            if let targetWindow = self.window {
                var title = "Authentication Challenge"
                if previousCredential != nil && challenge.previousFailureCount > 0 {
                    title = "\(title), attempt \(challenge.previousFailureCount + 1)"
                }
                let alert1 = NSAlert()
                alert1.addButton(withTitle: "OK")
                alert1.addButton(withTitle: "Cancel")
                alert1.messageText = title
                alert1.informativeText = "Username for \(hostName)"
                let user = NSTextField(frame: NSMakeRect(0, 0, 200, 24))
                if let prevCred = previousCredential {
                    user.stringValue = prevCred.user ?? ""
                }
                user.isEditable = true
                alert1.accessoryView = user

                alert1.beginSheetModal(for: targetWindow) { returnCode in
                    if returnCode == .alertFirstButtonReturn {
                        let alert2 = NSAlert()
                        alert2.addButton(withTitle: "OK")
                        alert2.addButton(withTitle: "Cancel")
                        alert2.messageText = title
                        alert2.informativeText = "password for \(hostName)"
                        let pass = NSSecureTextField(frame: NSMakeRect(0, 36, 200, 24))
                        pass.isEditable = true
                        alert2.accessoryView = pass
                        alert2.beginSheetModal(for: targetWindow) { returnCode2 in
                            if returnCode2 == .alertFirstButtonReturn {
                                let credential = URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession)
                                completionHandler(.useCredential, credential)
                            } else {
                                completionHandler(.cancelAuthenticationChallenge, nil)
                            }
                        }
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
            } else {
                LuaSkin.logWarn(String(format: "%s:didReceiveAuthenticationChallenge no target window", USERDATA_TAG))
                completionHandler(.performDefaultHandling, nil)
            }

        } else if authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let serverTrust = challenge.protectionSpace.serverTrust!
            var status: SecTrustResultType = .invalid
            SecTrustEvaluate(serverTrust, &status)

            if status == .recoverableTrustFailure && self.sslCallback != LUA_NOREF {
                let skin = LuaSkin.shared(withState: nil)!
                _lua_stackguard_entry(skin.L)
                skin.pushLuaRef(refTable, ref: self.sslCallback)
                skin.pushNSObject(webView.window as? HSWebViewWindow)
                skin.pushNSObject(challenge.protectionSpace)

                if !skin.protectedCallAndTraceback(2, nresults: 1) {
                    let errorMsg = String(cString: lua_tostring(skin.L, -1))
                    skin.logError("hs.webview:sslCallback callback error: \(errorMsg)")
                    completionHandler(.performDefaultHandling, nil)
                } else {
                    if lua_type(skin.L, -1) == LUA_TBOOLEAN && lua_toboolean(skin.L, -1) != 0 && examineInvalidCertificates {
                        let exceptions = SecTrustCopyExceptions(serverTrust)
                        SecTrustSetExceptions(serverTrust, exceptions)
                        completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    } else {
                        completionHandler(.performDefaultHandling, nil)
                    }
                }
                lua_pop(skin.L, 1)
                _lua_stackguard_exit(skin.L)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            LuaSkin.logWarn(String(format: "%s:didReceiveAuthenticationChallenge unhandled challenge type:%@", USERDATA_TAG, challenge.protectionSpace.authenticationMethod as NSString))
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if self.policyCallback != LUA_NOREF {
            let skin = LuaSkin.shared(withState: nil)!
            _lua_stackguard_entry(skin.L)
            skin.pushLuaRef(refTable, ref: self.policyCallback)
            lua_pushstring(skin.L, "navigationAction")
            skin.pushNSObject(webView.window as? HSWebViewWindow)
            skin.pushNSObject(navigationAction)

            if !skin.protectedCallAndTraceback(3, nresults: 1) {
                let errorMsg = String(cString: lua_tostring(skin.L, -1))
                skin.logError("hs.webview:policyCallback() navigationAction callback error: \(errorMsg)")
                decisionHandler(.cancel)
            } else {
                decisionHandler(lua_toboolean(skin.L, -1) != 0 ? .allow : .cancel)
            }
            lua_pop(skin.L, 1)
            _lua_stackguard_exit(skin.L)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if self.policyCallback != LUA_NOREF {
            let skin = LuaSkin.shared(withState: nil)!
            _lua_stackguard_entry(skin.L)
            skin.pushLuaRef(refTable, ref: self.policyCallback)
            lua_pushstring(skin.L, "navigationResponse")
            skin.pushNSObject(webView.window as? HSWebViewWindow)
            skin.pushNSObject(navigationResponse)

            if !skin.protectedCallAndTraceback(3, nresults: 1) {
                let errorMsg = String(cString: lua_tostring(skin.L, -1))
                skin.logError("hs.webview:policyCallback() navigationResponse callback error: \(errorMsg)")
                decisionHandler(.cancel)
            } else {
                decisionHandler(lua_toboolean(skin.L, -1) != 0 ? .allow : .cancel)
            }
            lua_pop(skin.L, 1)
            _lua_stackguard_exit(skin.L)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: -- WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard (webView as? HSWebViewView)?.allowNewWindows == true else { return nil }

        let skin = LuaSkin.shared(withState: nil)!
        _lua_stackguard_entry(skin.L)

        let parent = webView.window as! HSWebViewWindow
        var theRect = parent.contentRect(forFrameRect: parent.frame)
        theRect = RectWithFlippedYCoordinate(theRect)
        theRect.origin.x += 20
        theRect.origin.y += 20

        let newWindow = HSWebViewWindow(contentRect: theRect, styleMask: parent.styleMask, backing: .buffered, defer: true)
        newWindow.level = parent.level
        newWindow.allowKeyboardEntry = parent.allowKeyboardEntry
        newWindow.titleFollow = parent.titleFollow
        newWindow.parent = parent
        newWindow.deleteOnClose = true
        newWindow.isOpaque = parent.isOpaque
        newWindow.lsCanary = skin.createGCCanary()

        if parent.windowCallback != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: parent.windowCallback)
            newWindow.windowCallback = skin.luaRef(refTable)
        }

        let newView = HSWebViewView(frame: (newWindow.contentView! as NSView).bounds, configuration: configuration)
        newWindow.contentView = newView

        newView.allowNewWindows = (webView as! HSWebViewView).allowNewWindows
        newView.allowsMagnification = webView.allowsMagnification
        newView.allowsBackForwardNavigationGestures = webView.allowsBackForwardNavigationGestures
        newView.setValue(NSNumber(value: newWindow.isOpaque), forKey: "drawsTransparentBackground")

        if (webView as! HSWebViewView).navigationCallback != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: (webView as! HSWebViewView).navigationCallback)
            newView.navigationCallback = skin.luaRef(refTable)
        }
        if (webView as! HSWebViewView).policyCallback != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: (webView as! HSWebViewView).policyCallback)
            newView.policyCallback = skin.luaRef(refTable)
        }

        if self.policyCallback != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: self.policyCallback)
            lua_pushstring(skin.L, "newWindow")
            skin.pushNSObject(newWindow)
            skin.pushNSObject(navigationAction)
            skin.pushNSObject(windowFeatures)

            if !skin.protectedCallAndTraceback(4, nresults: 1) {
                let errorMsg = String(cString: lua_tostring(skin.L, -1))
                lua_pop(skin.L, 1)
                skin.logError("hs.webview:policyCallback() newWindow callback error: \(errorMsg)")

                lua_pushcfunction(skin.L, userdata_gc)
                skin.pushNSObject(newWindow)
                skin.protectedCallAndError("hs.webview:policyCallback() newWindow removal", nargs: 1, nresults: 0)
                _lua_stackguard_exit(skin.L)
                return nil
            } else {
                if !lua_toboolean(skin.L, -1).boolValue {
                    lua_pop(skin.L, 1)
                    lua_pushcfunction(skin.L, userdata_gc)
                    skin.pushNSObject(newWindow)
                    skin.protectedCallAndError("hs.webview:policyCallback() newWindow removal rejection", nargs: 1, nresults: 0)
                    _lua_stackguard_exit(skin.L)
                    return nil
                }
            }
            lua_pop(skin.L, 1)
        }

        parent.children.add(newWindow)
        newWindow.makeKeyAndOrderFront(nil)

        _lua_stackguard_exit(skin.L)
        return newView
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alertPanel = NSAlert()
        alertPanel.addButton(withTitle: "OK")
        alertPanel.messageText = "JavaScript Alert for \(frame.request.url?.host ?? "")"
        alertPanel.informativeText = message

        if let targetWindow = webView.window {
            alertPanel.beginSheetModal(for: targetWindow) { _ in completionHandler() }
        } else {
            LuaSkin.logWarn(String(format: "%s:runJavaScriptAlertPanelWithMessage no target window", USERDATA_TAG))
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let confirmPanel = NSAlert()
        confirmPanel.addButton(withTitle: "OK")
        confirmPanel.addButton(withTitle: "Cancel")
        confirmPanel.messageText = "JavaScript Confirm for \(frame.request.url?.host ?? "")"
        confirmPanel.informativeText = message

        if let targetWindow = webView.window {
            confirmPanel.beginSheetModal(for: targetWindow) { returnCode in
                completionHandler(returnCode == .alertFirstButtonReturn)
            }
        } else {
            LuaSkin.logWarn(String(format: "%s:runJavaScriptConfirmPanelWithMessage no target window", USERDATA_TAG))
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let inputPanel = NSAlert()
        inputPanel.addButton(withTitle: "OK")
        inputPanel.addButton(withTitle: "Cancel")
        inputPanel.messageText = "JavaScript Input for \(frame.request.url?.host ?? "")"
        inputPanel.informativeText = prompt
        let input = NSTextField(frame: NSMakeRect(0, 0, 200, 24))
        input.stringValue = defaultText ?? ""
        input.isEditable = true
        inputPanel.accessoryView = input

        if let targetWindow = webView.window {
            inputPanel.beginSheetModal(for: targetWindow) { returnCode in
                completionHandler(returnCode == .alertFirstButtonReturn ? input.stringValue : nil)
            }
        } else {
            LuaSkin.logWarn(String(format: "%s:runJavaScriptTextInputPanelWithPrompt no target window", USERDATA_TAG))
        }
    }

    // MARK: -- Helper methods

    func handleNavigationFailure(_ error: NSError, forView theView: WKWebView) {
        var theErrorPage = "<html><head><title>Webview Error \(error.code)</title></head><body>"
        theErrorPage += "<b>An Error code: \(error.code) in \(error.domain) occurred during navigation:</b><br><hr>"
        if let desc = error.localizedDescription as String? { theErrorPage += "<i>Description:</i> \(desc)<br>" }
        if let reason = error.localizedFailureReason { theErrorPage += "<i>Reason:</i> \(reason)<br>" }
        theErrorPage += "</body></html>"
        theView.loadHTMLString(theErrorPage, baseURL: nil)
    }

    @discardableResult
    func navigationCallbackFor(_ action: String, forView theView: WKWebView,
                               withNavigation navigation: WKNavigation?,
                               withError error: NSError?) -> Bool {
        (theView as? HSWebViewView)?.trackingID = navigation

        var actionRequiredAfterReturn = true

        if self.navigationCallback != LUA_NOREF {
            let skin = LuaSkin.shared(withState: nil)!
            _lua_stackguard_entry(skin.L)
            var numberOfArguments: Int32 = 3
            skin.pushLuaRef(refTable, ref: self.navigationCallback)
            lua_pushstring(skin.L, action)
            skin.pushNSObject(theView.window as? HSWebViewWindow)
            let navStr = String(format: "0x%p", navigation as AnyObject)
            lua_pushstring(skin.L, navStr)

            if let error = error {
                numberOfArguments += 1
                NSError_toLua(skin.L, error)
            }

            if !skin.protectedCallAndTraceback(numberOfArguments, nresults: 1) {
                let errorMsg = String(cString: lua_tostring(skin.L, -1))
                skin.logError("hs.webview:navigationCallback() \(action) callback error: \(errorMsg)")
            } else {
                if error != nil {
                    if lua_type(skin.L, -1) == LUA_TSTRING {
                        luaL_tolstring(skin.L, -1, nil)
                        let theHTML = skin.toNSObject(atIndex: -1) as? String ?? ""
                        lua_pop(skin.L, 1)
                        theView.loadHTMLString(theHTML, baseURL: nil)
                        actionRequiredAfterReturn = false
                    } else if lua_type(skin.L, -1) == LUA_TBOOLEAN && lua_toboolean(skin.L, -1) != 0 {
                        actionRequiredAfterReturn = false
                    }
                }
            }
            lua_pop(skin.L, 1)
            _lua_stackguard_exit(skin.L)
        }

        return actionRequiredAfterReturn
    }
}

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
private func webview_privateBrowsing(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = Unmanaged<HSWebViewWindow>.fromOpaque(
        luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee!
    ).takeUnretainedValue()
    let theView = theWindow.contentView as! HSWebViewView
    let theConfiguration = theView.configuration
    lua_pushboolean(L, !theConfiguration.websiteDataStore.isPersistent ? 1 : 0)
    return 1
}

// Helper to get HSWebViewWindow from userdata at stack index
private func getWindowFromUD(_ L: OpaquePointer!, _ idx: Int32) -> HSWebViewWindow {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    return Unmanaged<HSWebViewWindow>.fromOpaque(ptr.pointee!).takeUnretainedValue()
}

/// hs.webview:children() -> array
/// Method
/// Returns an array of webview objects which have been opened as children of this webview.
private func webview_children(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

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
private func webview_parent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    if let parent = theWindow.parent { skin.pushNSObject(parent) } else { lua_pushnil(L) }
    return 1
}

/// hs.webview:url([URL]) -> webviewObject, navigationIdentifier | url
/// Method
/// Get or set the URL to render for the webview.
private func webview_url(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if lua_type(L, 2) == LUA_TNONE {
        skin.pushNSObject(theView.url?.absoluteString as NSString?)
        return 1
    } else {
        let theNSURL = skin.luaObject(atIndex: 2, toClass: "NSURLRequest") as? URLRequest
        if let theNSURL = theNSURL {
            delayUntilViewStopsLoading(theView) {
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
private func webview_userAgent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_certificateChain(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    if let certificateChain = theView.serverTrust {
        lua_newtable(L)
        for i in 0..<SecTrustGetCertificateCount(certificateChain) {
            SecCertificateRef_toLua(L, SecTrustGetCertificateAtIndex(certificateChain, i))
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
private func webview_title(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    skin.pushNSObject(theView.title as NSString?)
    return 1
}

/// hs.webview:navigationID() -> navigationID
/// Method
/// Get the most recent navigation identifier for the specified webview.
private func webview_navigationID(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    skin.pushNSObject(theView.trackingID)
    return 1
}

/// hs.webview:loading() -> boolean
/// Method
/// Returns a boolean value indicating whether or not the webview is still loading content.
private func webview_loading(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    lua_pushboolean(L, theView.isLoading ? 1 : 0)
    return 1
}

/// hs.webview:stopLoading() -> webviewObject
/// Method
/// Stop loading additional content for the webview.
private func webview_stopLoading(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    if !theView.isLoading { theView.stopLoading() }
    lua_settop(L, 1)
    return 1
}

/// hs.webview:estimatedProgress() -> number
/// Method
/// Returns the estimated percentage of expected content that has been loaded.
private func webview_estimatedProgress(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    lua_pushnumber(L, theView.estimatedProgress)
    return 1
}

/// hs.webview:isOnlySecureContent() -> bool
/// Method
/// Returns a boolean value indicating if all content current displayed in the webview was loaded over securely encrypted connections.
private func webview_isOnlySecureContent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    lua_pushboolean(L, theView.hasOnlySecureContent ? 1 : 0)
    return 1
}

/// hs.webview:goForward() -> webviewObject
/// Method
/// Move to the next page in the webview's history, if possible.
private func webview_goForward(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    theView.goForward()
    lua_settop(L, 1)
    return 1
}

/// hs.webview:goBack() -> webviewObject
/// Method
/// Move to the previous page in the webview's history, if possible.
private func webview_goBack(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    theView.goBack()
    lua_settop(L, 1)
    return 1
}

/// hs.webview:reload([validate]) -> webviewObject, navigationIdentifier
/// Method
/// Reload the page in the webview, optionally performing end-to-end revalidation using cache-validating conditionals if possible.
private func webview_reload(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    let validate = (lua_type(L, 2) == LUA_TBOOLEAN) ? (lua_toboolean(L, 2) != 0) : false

    delayUntilViewStopsLoading(theView) {
        let navID = validate ? theView.reloadFromOrigin() : theView.reload()
        theView.trackingID = navID
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:transparent([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview background is transparent.
private func webview_transparent(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

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
private func webview_allowMagnificationGestures(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_allowNewWindows(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_examineInvalidCertificates(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_allowNavigationGestures(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_magnification(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_html(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    luaL_tolstring(L, 2, nil)
    let theHTML = skin.toNSObject(atIndex: -1) as? String ?? ""
    lua_pop(L, 1)
    let theBaseURL = (lua_type(L, 3) == LUA_TSTRING) ? skin.toNSObject(atIndex: 3) as? String : nil

    delayUntilViewStopsLoading(theView) {
        let navID = theView.loadHTMLString(theHTML, baseURL: theBaseURL != nil ? URL(string: theBaseURL!) : nil)
        theView.trackingID = navID
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:navigationCallback(fn) -> webviewObject
/// Method
/// Sets a callback for tracking a webview's navigation process.
private func webview_navigationCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.navigationCallback = skin.luaUnref(refTable, ref: theView.navigationCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theView.navigationCallback = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:policyCallback(fn) -> webviewObject
/// Method
/// Sets a callback to approve or deny web navigation activity.
private func webview_policyCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.policyCallback = skin.luaUnref(refTable, ref: theView.policyCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theView.policyCallback = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:sslCallback(fn) -> webviewObject
/// Method
/// Sets a callback to examine an invalid SSL certificate and determine if an exception should be granted.
private func webview_sslCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    theView.sslCallback = skin.luaUnref(refTable, ref: theView.sslCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theView.sslCallback = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:historyList() -> historyTable
/// Method
/// Returns the URL history for the current webview as an array.
private func webview_historyList(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView
    skin.pushNSObject(theView.backForwardList)
    return 1
}

/// hs.webview:evaluateJavaScript(script, [callback]) -> webviewObject
/// Method
/// Execute JavaScript within the context of the current webview and optionally receive its result or error in a callback function.
private func webview_evaluateJavaScript(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TFUNCTION | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as! HSWebViewView

    let javascript = skin.toNSObject(atIndex: 2) as! String
    var callbackRef: Int32 = LUA_NOREF
    if lua_type(L, 3) == LUA_TFUNCTION {
        lua_pushvalue(L, 3)
        callbackRef = skin.luaRef(refTable)
    }

    let lsCanary = skin.createGCCanary()
    theView.evaluateJavaScript(javascript) { obj, error in
        if callbackRef != LUA_NOREF {
            DispatchQueue.main.async {
                let blockSkin = LuaSkin.shared(withState: nil)!
                if !blockSkin.checkGCCanary(lsCanary) { return }
                blockSkin.pushLuaRef(refTable, ref: callbackRef)
                blockSkin.pushNSObject(obj as? NSObject)
                NSError_toLua(blockSkin.L, error as NSError?)
                blockSkin.protectedCallAndError("hs.webview:evaluateJavaScript callback", nargs: 2, nresults: 0)
                blockSkin.luaUnref(refTable, ref: callbackRef)
                var mutableCanary = lsCanary
                blockSkin.destroyGCCanary(&mutableCanary)
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
private func webview_topLeft(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let oldFrame = RectWithFlippedYCoordinate(theWindow.frame)

    if lua_gettop(L) == 1 {
        skin.pushNSPoint(oldFrame.origin)
    } else {
        let newCoord = skin.tableToPoint(atIndex: 2)
        let newFrame = RectWithFlippedYCoordinate(NSMakeRect(newCoord.x, newCoord.y, oldFrame.size.width, oldFrame.size.height))
        theWindow.setFrame(newFrame, display: true, animate: false)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:size([size]) -> webviewObject | currentValue
/// Method
/// Get or set the size of a webview window
private func webview_size(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let oldFrame = theWindow.frame

    if lua_gettop(L) == 1 {
        skin.pushNSSize(oldFrame.size)
    } else {
        let newSize = skin.tableToSize(atIndex: 2)
        let newFrame = NSMakeRect(oldFrame.origin.x, oldFrame.origin.y + oldFrame.size.height - newSize.height, newSize.width, newSize.height)
        theWindow.setFrame(newFrame, display: true, animate: false)
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview.new(rect, [preferencesTable], [userContentController]) -> webviewObject
/// Constructor
/// Create a webviewObject and optionally modify its preferences.
private func webview_new(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let windowRect = skin.tableToRect(atIndex: 1)

    let theWindow = HSWebViewWindow(contentRect: windowRect, styleMask: .borderless, backing: .buffered, defer: true)

    theWindow.lsCanary = skin.createGCCanary()

    if HSWebViewProcessPool == nil { HSWebViewProcessPool = WKProcessPool() }

    let config = WKWebViewConfiguration()
    config.processPool = HSWebViewProcessPool!

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
private func webview_show(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let fadeTime: TimeInterval = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0

    if fadeTime > 0 { theWindow.fadeIn(fadeTime) } else { theWindow.makeKeyAndOrderFront(nil) }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:hide([fadeOutTime]) -> webviewObject
/// Method
/// Hides the webview object
private func webview_hide(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    let fadeTime: TimeInterval = (lua_gettop(L) == 2) ? lua_tonumber(L, 2) : 0.0

    if fadeTime > 0 { theWindow.fadeOut(fadeTime, andDelete: false, withState: L) } else { theWindow.orderOut(nil) }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:allowTextEntry([value]) -> webviewObject | current value
/// Method
/// Get or set whether or not the webview can accept keyboard for web form entry.
private func webview_allowTextEntry(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_deleteOnClose(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_darkMode(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

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
private func webview_closeOnEscape(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_hswindow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
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
private func webview_isVisible(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    lua_pushboolean(L, theWindow.isVisible ? 1 : 0)
    return 1
}

/// hs.webview:windowTitle([title]) -> webviewObject
/// Method
/// Sets the title for the webview window.
private func webview_windowTitle(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

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
private func webview_titleVisibility(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

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
private func webview_windowStyle(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    if lua_type(L, 2) == LUA_TNONE {
        lua_pushinteger(L, lua_Integer(theWindow.styleMask.rawValue))
    } else {
        let theTitle = theWindow.title
        theWindow.styleMask = []
        theWindow.styleMask = NSWindow.StyleMask(rawValue: UInt(luaL_checkinteger(L, 2)))
        if let theTitle = theTitle { theWindow.title = theTitle }
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:level([theLevel]) -> drawingObject | currentValue
/// Method
/// Get or set the window level
private func webview_level(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(theWindow.level.rawValue))
    } else {
        let targetLevel = lua_tointeger(L, 2)
        let minLevel = CGWindowLevelForKey(.minimumWindow)
        let maxLevel = CGWindowLevelForKey(.maximumWindow)
        if targetLevel >= Int(minLevel) && targetLevel <= Int(maxLevel) {
            theWindow.level = NSWindow.Level(rawValue: Int(targetLevel))
        } else {
            return luaL_error(L, "window level must be between %d and %d inclusive", minLevel, maxLevel)
        }
        lua_settop(L, 1)
    }
    return 1
}

/// hs.webview:bringToFront([aboveEverything]) -> webviewObject
/// Method
/// Places the drawing object on top of normal windows
private func webview_bringToFront(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    theWindow.level = lua_toboolean(L, 2) != 0 ? .screenSaver : .floating
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:sendToBack() -> webviewObject
/// Method
/// Places the webview object behind normal windows, between the desktop wallpaper and desktop icons
private func webview_sendToBack(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)
    theWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:alpha([alpha]) -> webviewObject | currentValue
/// Method
/// Get or set the alpha level of the window containing the hs.webview object.
private func webview_alpha(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

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
private func webview_shadow(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

    if lua_type(L, 2) == LUA_TNONE {
        lua_pushboolean(L, theWindow.hasShadow ? 1 : 0)
    } else {
        theWindow.hasShadow = lua_toboolean(L, 2) != 0
        lua_settop(L, 1)
    }
    return 1
}

private func webview_orderHelper(_ L: OpaquePointer!, mode: NSWindow.OrderingMode) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK | LS_TVARARG)
    let theWindow = skin.luaObject(atIndex: 1, toClass: "HSWebViewWindow") as! HSWebViewWindow
    var relativeTo: Int = 0

    if lua_gettop(L) > 1 {
        skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
        relativeTo = (skin.luaObject(atIndex: 2, toClass: "HSWebViewWindow") as! HSWebViewWindow).windowNumber
    }

    theWindow.order(mode, relativeTo: relativeTo)
    lua_pushvalue(L, 1)
    return 1
}

/// hs.webview:orderAbove([webview2]) -> webviewObject
/// Method
/// Moves webview object above webview2, or all webview objects in the same presentation level, if webview2 is not given.
private func webview_orderAbove(_ L: OpaquePointer!) -> Int32 {
    return webview_orderHelper(L, mode: .above)
}

/// hs.webview:orderBelow([webview2]) -> webviewObject
/// Method
/// Moves webview object below webview2, or all webview objects in the same presentation level, if webview2 is not given.
private func webview_orderBelow(_ L: OpaquePointer!) -> Int32 {
    return webview_orderHelper(L, mode: .below)
}

// NOTE: wrapped in init.lua
private func webview_delete(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = skin.luaObject(atIndex: 1, toClass: "HSWebViewWindow") as! HSWebViewWindow

    if lua_gettop(L) == 1 || !theWindow.isVisible {
        theWindow.close()
        lua_pushcfunction(L, userdata_gc)
        lua_pushvalue(L, 1)
        if lua_pcall(L, 1, 0, 0) != LUA_OK {
            skin.logBreadcrumb(String(format: "%s:error invoking _gc for delete method:%s", USERDATA_TAG, lua_tostring(L, -1)!))
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
private func webview_behavior(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let theWindow = skin.luaObject(atIndex: 1, toClass: "HSWebViewWindow") as! HSWebViewWindow

    if lua_gettop(L) == 1 {
        lua_pushinteger(L, lua_Integer(theWindow.collectionBehavior.rawValue))
    } else {
        skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER, LS_TBREAK)
        let newLevel = lua_tointeger(L, 2)
        theWindow.collectionBehavior = NSWindow.CollectionBehavior(rawValue: UInt(newLevel))
        lua_pushvalue(L, 1)
    }
    return 1
}

/// hs.webview:windowCallback(fn) -> webviewObject
/// Method
/// Set or clear a callback for updates to the webview window
private func webview_windowCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let theWindow = getWindowFromUD(L, 1)

    theWindow.windowCallback = skin.luaUnref(refTable, ref: theWindow.windowCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        theWindow.windowCallback = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - Module Constants

/// hs.webview.windowMasks[]
/// Constant
/// A table containing valid masks for the webview window.
private func webview_windowMasksTable(_ L: OpaquePointer!) -> Int32 {
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
private func webview_pushCertificateOIDs(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
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

private func luaTo_HSWebViewWindow(_ L: OpaquePointer!, _ idx: Int32) -> Any! {
    let skin = LuaSkin.shared(withState: L)!
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return getWindowFromUD(L, idx)
    } else {
        skin.logError(String(format: "expected %s object, found %s", USERDATA_TAG, String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

private func HSWebViewWindow_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let theWindow = obj as! HSWebViewWindow

    if theWindow.udRef == LUA_NOREF {
        let windowPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        windowPtr.pointee = Unmanaged.passRetained(theWindow).toOpaque()
        luaL_getmetatable(L, USERDATA_TAG)
        lua_setmetatable(L, -2)
        theWindow.udRef = skin.luaRef(refTable)
    }

    skin.pushLuaRef(refTable, ref: theWindow.udRef)
    return 1
}

private func WKNavigationAction_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
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

private func WKNavigationResponse_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let navResponse = obj as! WKNavigationResponse

    lua_newtable(L)
    lua_pushboolean(L, navResponse.canShowMIMEType ? 1 : 0); lua_setfield(L, -2, "canShowMIMEType")
    lua_pushboolean(L, navResponse.isForMainFrame ? 1 : 0);  lua_setfield(L, -2, "forMainFrame")
    skin.pushNSObject(navResponse.response);                  lua_setfield(L, -2, "response")
    return 1
}

private func WKFrameInfo_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let frameInfo = obj as! WKFrameInfo

    lua_newtable(L)
    lua_pushboolean(L, frameInfo.isMainFrame ? 1 : 0); lua_setfield(L, -2, "mainFrame")
    skin.pushNSObject(frameInfo.request as NSObject);   lua_setfield(L, -2, "request")
    skin.pushNSObject(frameInfo.securityOrigin);        lua_setfield(L, -2, "securityOrigin")
    return 1
}

private func WKBackForwardListItem_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let item = obj as! WKBackForwardListItem

    lua_newtable(L)
    skin.pushNSObject(item.url as NSURL);        lua_setfield(L, -2, "URL")
    skin.pushNSObject(item.initialURL as NSURL); lua_setfield(L, -2, "initialURL")
    skin.pushNSObject(item.title as NSString?);  lua_setfield(L, -2, "title")
    return 1
}

private func WKBackForwardList_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
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

private func WKNavigation_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let navID = obj as! WKNavigation
    let str = String(format: "0x%p", navID as AnyObject)
    lua_pushstring(L, str)
    return 1
}

private func NSError_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
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

private func WKWindowFeatures_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
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

private func NSURLAuthenticationChallenge_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let challenge = obj as! URLAuthenticationChallenge

    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(challenge.previousFailureCount)); lua_setfield(L, -2, "previousFailureCount")
    skin.pushNSObject(challenge.error as NSError?);                  lua_setfield(L, -2, "error")
    skin.pushNSObject(challenge.failureResponse);                    lua_setfield(L, -2, "failureResponse")
    skin.pushNSObject(challenge.proposedCredential);                 lua_setfield(L, -2, "proposedCredential")
    skin.pushNSObject(challenge.protectionSpace);                    lua_setfield(L, -2, "protectionSpace")
    return 1
}

private func SecCertificateRef_toLua(_ L: OpaquePointer!, _ certRef: SecCertificate!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    lua_newtable(L)
    var commonName: CFString?
    SecCertificateCopyCommonName(certRef, &commonName)
    if let commonName = commonName {
        skin.pushNSObject(commonName as NSString); lua_setfield(L, -2, "commonName")
    }
    if let values = SecCertificateCopyValues(certRef, nil, nil) {
        skin.pushNSObject(values as NSDictionary, withOptions: LS_NSDescribeUnknownTypes)
        lua_setfield(L, -2, "values")
    }
    return 1
}

private func NSURLProtectionSpace_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let theSpace = obj as! URLProtectionSpace

    lua_newtable(L)
    lua_pushboolean(L, theSpace.isProxy ? 1 : 0);                    lua_setfield(L, -2, "isProxy")
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
            SecCertificateRef_toLua(L, SecTrustGetCertificateAtIndex(serverTrust, idx))
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        lua_setfield(L, -2, "certificates")
    }
    return 1
}

private func NSURLCredential_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
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

private func WKSecurityOrigin_toLua(_ L: OpaquePointer!, _ obj: Any!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let origin = obj as! WKSecurityOrigin

    lua_newtable(L)
    skin.pushNSObject(origin.host as NSString);     lua_setfield(L, -2, "host")
    lua_pushinteger(L, lua_Integer(origin.port));    lua_setfield(L, -2, "port")
    skin.pushNSObject(origin.protocol as NSString);  lua_setfield(L, -2, "protocol")
    return 1
}

// MARK: - Lua Framework Stuff

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let theWindow = getWindowFromUD(L, 1)
    let theView = theWindow.contentView as? HSWebViewView
    let title = theView?.title ?? ""
    let str = String(format: "%s: %@ (%p)", USERDATA_TAG, (title.isEmpty ? "" : title) as NSString, lua_topointer(L, 1)!)
    lua_pushstring(L, str)
    return 1
}

private func userdata_eq(_ L: OpaquePointer!) -> Int32 {
    let theWindow = getWindowFromUD(L, 1)
    let otherWindow = getWindowFromUD(L, 2)
    lua_pushboolean(L, theWindow.udRef == otherWindow.udRef ? 1 : 0)
    return 1
}

private func userdata_gc(_ L: OpaquePointer!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) == nil { return 0 }

    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
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

    let skin = LuaSkin.shared(withState: L)!
    theWindow.udRef = skin.luaUnref(refTable, ref: theWindow.udRef)
    theWindow.windowCallback = skin.luaUnref(refTable, ref: theWindow.windowCallback)
    if let theView = theView {
        theView.navigationCallback = skin.luaUnref(refTable, ref: theView.navigationCallback)
        theView.policyCallback = skin.luaUnref(refTable, ref: theView.policyCallback)
    }

    if theWindow.toolbar != nil {
        theWindow.toolbar?.isVisible = false
        theWindow.toolbar = nil
    }

    theWindow.close()

    if let parent = theWindow.parent {
        parent.children.remove(theWindow)
        theWindow.parent = nil
    }

    for child in theWindow.children {
        (child as? HSWebViewWindow)?.parent = nil
    }

    if let theView = theView, let reloadTimer = delayTimers?.object(forKey: theView) {
        reloadTimer.invalidate()
        delayTimers?.removeObject(forKey: theView)
    }

    theView?.navigationDelegate = nil
    theView?.uiDelegate = nil
    theWindow.contentView = nil

    var tmpCanary = theWindow.lsCanary
    skin.destroyGCCanary(&tmpCanary)
    theWindow.lsCanary = tmpCanary

    theWindow.delegate = nil

    return 0
}

private func meta_gc(_ L: OpaquePointer!) -> Int32 {
    HSWebViewProcessPool = nil

    if let timers = delayTimers {
        let enumerator = timers.objectEnumerator()!
        while let timer = enumerator.nextObject() as? Timer {
            timer.invalidate()
        }
        delayTimers?.removeAllObjects()
    }
    delayTimers = nil

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

    luaL_Reg(name: strdup("__tostring"),                 func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),                       func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),                       func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: webview_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for module
private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwebview")
public func luaopen_hs_libwebview(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!

    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: &module_metaLib,
                                    objectFunctions: &userdata_metaLib)

    // module userdata specific conversions
    skin.registerPushNSHelper(HSWebViewWindow_toLua, forClass: "HSWebViewWindow")
    skin.registerLuaObjectHelper(luaTo_HSWebViewWindow, forClass: "HSWebViewWindow",
                                 withUserdataMapping: USERDATA_TAG)

    // classes used primarily by this module
    skin.registerPushNSHelper(WKBackForwardListItem_toLua, forClass: "WKBackForwardListItem")
    skin.registerPushNSHelper(WKBackForwardList_toLua, forClass: "WKBackForwardList")
    skin.registerPushNSHelper(WKNavigationAction_toLua, forClass: "WKNavigationAction")
    skin.registerPushNSHelper(WKNavigationResponse_toLua, forClass: "WKNavigationResponse")
    skin.registerPushNSHelper(WKFrameInfo_toLua, forClass: "WKFrameInfo")
    skin.registerPushNSHelper(WKNavigation_toLua, forClass: "WKNavigation")
    skin.registerPushNSHelper(WKWindowFeatures_toLua, forClass: "WKWindowFeatures")
    skin.registerPushNSHelper(WKSecurityOrigin_toLua, forClass: "WKSecurityOrigin")

    // classes that may find a better home elsewhere someday
    skin.registerPushNSHelper(NSURLAuthenticationChallenge_toLua, forClass: "NSURLAuthenticationChallenge")
    skin.registerPushNSHelper(NSURLProtectionSpace_toLua, forClass: "NSURLProtectionSpace")
    skin.registerPushNSHelper(NSURLCredential_toLua, forClass: "NSURLCredential")

    webview_windowMasksTable(L);    lua_setfield(L, -2, "windowMasks")
    webview_pushCertificateOIDs(L); lua_setfield(L, -2, "certificateOIDs")

    return 1
}
