import Foundation
import CLua
import Lua
import Cocoa
import WebKit
import os.log

// MARK: - HSWebViewView

class HSWebViewView: WKWebView, WKNavigationDelegate, WKUIDelegate {
    var navigationCallback: LuaValue?
    var policyCallback: LuaValue?
    var sslCallback: LuaValue?
    var allowNewWindows: Bool = true
    var examineInvalidCertificates: Bool = false
    var trackingID: WKNavigation?
    var generation: UInt64 = 0

    override init(frame frameRect: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frameRect, configuration: configuration)
        self.navigationDelegate = self
        self.uiDelegate = self
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
                    os_log(.default, "%{public}s","\(wv_USERDATA_TAG):didFailProvisionalNavigation missing NSURLErrorFailingURLErrorKey")
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

            if self.policyCallback != nil && challenge.previousFailureCount < 3 && lua_isStateGenerationValid(self.generation) {
                let L = lua_getCurrentState()!
                self.policyCallback!.push(onto: L)
                L.push("authenticationChallenge")
                wv_pushAny(L, webView.window as? HSWebViewWindow)
                wv_pushAny(L, challenge)

                if lua_pcall(L, 3, 1, 0) != LUA_OK {
                    let errorMsg = lua_tostring(L, -1).map({ String(cString: $0) }) ?? "unknown error"
                    os_log(.error, "%{public}s", "hs.webview:policyCallback() authenticationChallenge callback error: \(errorMsg)")
                } else {
                    if lua_type(L, -1) == LUA_TTABLE {
                        lua_getfield(L, -1, "user")
                        let userName = (lua_type(L, -1) == LUA_TSTRING) ? (lua_tovalue(L, at: -1) as? String ?? "") : ""
                        lua_pop(L, 1)

                        lua_getfield(L, -1, "password")
                        let password = (lua_type(L, -1) == LUA_TSTRING) ? (lua_tovalue(L, at: -1) as? String ?? "") : ""
                        lua_pop(L, 1)

                        let credential = URLCredential(user: userName, password: password, persistence: .forSession)
                        completionHandler(.useCredential, credential)
                        lua_pop(L, 1)
                        return
                    } else if lua_toboolean(L, -1) == 0 {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                        lua_pop(L, 1)
                        return
                    }
                }
                lua_pop(L, 1)
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
                os_log(.default, "%{public}s","\(wv_USERDATA_TAG):didReceiveAuthenticationChallenge no target window")
                completionHandler(.performDefaultHandling, nil)
            }

        } else if authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let serverTrust = challenge.protectionSpace.serverTrust!
            var status: SecTrustResultType = .invalid
            SecTrustEvaluate(serverTrust, &status)

            if status == .recoverableTrustFailure && self.sslCallback != nil && lua_isStateGenerationValid(self.generation) {
                let L = lua_getCurrentState()!
                self.sslCallback!.push(onto: L)
                wv_pushAny(L, webView.window as? HSWebViewWindow)
                wv_pushAny(L, challenge.protectionSpace)

                if lua_pcall(L, 2, 1, 0) != LUA_OK {
                    let errorMsg = lua_tostring(L, -1).map({ String(cString: $0) }) ?? "unknown error"
                    os_log(.error, "%{public}s", "hs.webview:sslCallback callback error: \(errorMsg)")
                    completionHandler(.performDefaultHandling, nil)
                } else {
                    if lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1) != 0 && examineInvalidCertificates {
                        let exceptions = SecTrustCopyExceptions(serverTrust)
                        SecTrustSetExceptions(serverTrust, exceptions)
                        completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    } else {
                        completionHandler(.performDefaultHandling, nil)
                    }
                }
                lua_pop(L, 1)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            os_log(.default, "%{public}s","\(wv_USERDATA_TAG):didReceiveAuthenticationChallenge unhandled challenge type:\(challenge.protectionSpace.authenticationMethod)")
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if self.policyCallback != nil && lua_isStateGenerationValid(self.generation) {
            let L = lua_getCurrentState()!
            self.policyCallback!.push(onto: L)
            L.push("navigationAction")
            wv_pushAny(L, webView.window as? HSWebViewWindow)
            wv_pushAny(L, navigationAction)

            if lua_pcall(L, 3, 1, 0) != LUA_OK {
                let errorMsg = lua_tostring(L, -1).map({ String(cString: $0) }) ?? "unknown error"
                os_log(.error, "%{public}s", "hs.webview:policyCallback() navigationAction callback error: \(errorMsg)")
                decisionHandler(.cancel)
            } else {
                decisionHandler(lua_toboolean(L, -1) != 0 ? .allow : .cancel)
            }
            lua_pop(L, 1)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if self.policyCallback != nil && lua_isStateGenerationValid(self.generation) {
            let L = lua_getCurrentState()!
            self.policyCallback!.push(onto: L)
            L.push("navigationResponse")
            wv_pushAny(L, webView.window as? HSWebViewWindow)
            wv_pushAny(L, navigationResponse)

            if lua_pcall(L, 3, 1, 0) != LUA_OK {
                let errorMsg = lua_tostring(L, -1).map({ String(cString: $0) }) ?? "unknown error"
                os_log(.error, "%{public}s", "hs.webview:policyCallback() navigationResponse callback error: \(errorMsg)")
                decisionHandler(.cancel)
            } else {
                decisionHandler(lua_toboolean(L, -1) != 0 ? .allow : .cancel)
            }
            lua_pop(L, 1)
        } else {
            decisionHandler(.allow)
        }
    }

    // MARK: -- WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard (webView as? HSWebViewView)?.allowNewWindows == true else { return nil }
        guard lua_isStateGenerationValid(self.generation) else { return nil }

        let L = lua_getCurrentState()!

        let parent = webView.window as! HSWebViewWindow
        var theRect = parent.contentRect(forFrameRect: parent.frame)
        theRect = wv_RectWithFlippedYCoordinate(theRect)
        theRect.origin.x += 20
        theRect.origin.y += 20

        let newWindow = HSWebViewWindow(contentRect: theRect, styleMask: parent.styleMask, backing: .buffered, defer: true)
        newWindow.level = parent.level
        newWindow.allowKeyboardEntry = parent.allowKeyboardEntry
        newWindow.titleFollow = parent.titleFollow
        newWindow.parentWebView = parent
        newWindow.deleteOnClose = true
        newWindow.isOpaque = parent.isOpaque
        newWindow.lsCanary = lua_currentStateGeneration()

        if let parentWinCb = parent.windowCallback {
            parentWinCb.push(onto: L)
            newWindow.windowCallback = L.ref(index: -1)
        }

        let newView = HSWebViewView(frame: (newWindow.contentView! as NSView).bounds, configuration: configuration)
        newView.generation = newWindow.lsCanary
        newWindow.contentView = newView

        newView.allowNewWindows = (webView as! HSWebViewView).allowNewWindows
        newView.allowsMagnification = webView.allowsMagnification
        newView.allowsBackForwardNavigationGestures = webView.allowsBackForwardNavigationGestures
        newView.setValue(NSNumber(value: newWindow.isOpaque), forKey: "drawsTransparentBackground")

        if let parentNavCb = (webView as! HSWebViewView).navigationCallback {
            parentNavCb.push(onto: L)
            newView.navigationCallback = L.ref(index: -1)
        }
        if let parentPolicyCb = (webView as! HSWebViewView).policyCallback {
            parentPolicyCb.push(onto: L)
            newView.policyCallback = L.ref(index: -1)
        }

        if self.policyCallback != nil {
            self.policyCallback!.push(onto: L)
            L.push("newWindow")
            wv_pushAny(L, newWindow)
            wv_pushAny(L, navigationAction)
            wv_pushAny(L, windowFeatures)

            if lua_pcall(L, 4, 1, 0) != LUA_OK {
                let errorMsg = lua_tostring(L, -1).map({ String(cString: $0) }) ?? "unknown error"
                lua_pop(L, 1)
                os_log(.error, "%{public}s", "hs.webview:policyCallback() newWindow callback error: \(errorMsg)")

                L.push(wv_userdata_gc)
                wv_pushAny(L, newWindow)
                if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
                return nil
            } else {
                if lua_toboolean(L, -1) == 0 {
                    lua_pop(L, 1)
                    L.push(wv_userdata_gc)
                    wv_pushAny(L, newWindow)
                    if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
                    return nil
                }
            }
            lua_pop(L, 1)
        }

        parent.children.add(newWindow)
        newWindow.makeKeyAndOrderFront(nil)
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
            os_log(.default, "%{public}s","\(wv_USERDATA_TAG):runJavaScriptAlertPanelWithMessage no target window")
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
            os_log(.default, "%{public}s","\(wv_USERDATA_TAG):runJavaScriptConfirmPanelWithMessage no target window")
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
            os_log(.default, "%{public}s","\(wv_USERDATA_TAG):runJavaScriptTextInputPanelWithPrompt no target window")
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

        if self.navigationCallback != nil {
            guard lua_isStateGenerationValid(self.generation) else { return actionRequiredAfterReturn }
            let L = lua_getCurrentState()!
            var numberOfArguments: Int32 = 3
            self.navigationCallback!.push(onto: L)
            L.push(action)
            wv_pushAny(L, theView.window as? HSWebViewWindow)
            let navStr = String(describing: Unmanaged.passUnretained(navigation as AnyObject).toOpaque())
            L.push(navStr)

            if let error = error {
                numberOfArguments += 1
                wv_NSError_toLua(L, error)
            }

            if lua_pcall(L, numberOfArguments, 1, 0) != LUA_OK {
                let errorMsg = lua_tostring(L, -1).map({ String(cString: $0) }) ?? "unknown error"
                os_log(.error, "%{public}s", "hs.webview:navigationCallback() \(action) callback error: \(errorMsg)")
            } else {
                if error != nil {
                    if lua_type(L, -1) == LUA_TSTRING {
                        luaL_tolstring(L, -1, nil)
                        let theHTML = lua_tovalue(L, at: -1) as? String ?? ""
                        lua_pop(L, 1)
                        theView.loadHTMLString(theHTML, baseURL: nil)
                        actionRequiredAfterReturn = false
                    } else if lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1) != 0 {
                        actionRequiredAfterReturn = false
                    }
                }
            }
            lua_pop(L, 1)
        }

        return actionRequiredAfterReturn
    }
}
