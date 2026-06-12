import Foundation
import CLua
import Lua
import Cocoa
import WebKit
import os.log

// MARK: - HSWebViewWindow

class HSWebViewWindow: NSPanel, NSWindowDelegate {
    var parentWebView: HSWebViewWindow?
    var children: NSMutableArray = NSMutableArray()
    var udRef: LuaValue?
    var windowCallback: LuaValue?
    var allowKeyboardEntry: Bool = false
    var darkMode: Bool = false
    var titleFollow: Bool = true
    var deleteOnClose: Bool = false
    var closeOnEscape: Bool = false
    var lsCanary: UInt64 = UInt64()

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        let flippedRect = wv_RectWithFlippedYCoordinate(contentRect)
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

        self.parentWebView = nil
        self.children = NSMutableArray()
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
        let L = lua_getCurrentState()!

        if !lua_isStateGenerationValid(lsCanary) { return }

        if windowCallback != nil {
            windowCallback!.push(onto: L)
            lua_pushany(L, "closing" as NSString)
            wv_pushAny(L, self)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
        if deleteOnClose {
            L.push(wv_userdata_gc)
            wv_pushAny(L, self)
            if lua_pcall(L, 1, 0, 0) != LUA_OK {
                os_log(.error, "%{public}s", String(format: "%s:error invoking _gc for deleteOnClose:%s", wv_USERDATA_TAG, lua_tostring(L, -1)!))
                lua_pop(L, 1)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != nil {
                let L = lua_getCurrentState()!
                self.windowCallback!.push(onto: L)
                lua_pushany(L, "focusChange" as NSString)
                wv_pushAny(L, self)
                lua_pushboolean(L, 1)
                if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != nil {
                let L = lua_getCurrentState()!
                self.windowCallback!.push(onto: L)
                lua_pushany(L, "focusChange" as NSString)
                wv_pushAny(L, self)
                lua_pushboolean(L, 0)
                if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != nil {
                let L = lua_getCurrentState()!
                self.windowCallback!.push(onto: L)
                lua_pushany(L, "frameChange" as NSString)
                wv_pushAny(L, self)
                lua_pushNSRect(L, wv_RectWithFlippedYCoordinate(self.frame))
                if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != nil {
                let L = lua_getCurrentState()!
                self.windowCallback!.push(onto: L)
                lua_pushany(L, "frameChange" as NSString)
                wv_pushAny(L, self)
                lua_pushNSRect(L, wv_RectWithFlippedYCoordinate(self.frame))
                if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
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

    func fadeOut(_ fadeTime: TimeInterval, andDelete deleteWindow: Bool, withState L: UnsafeMutablePointer<lua_State>!) {
        NSAnimationContext.beginGrouping()
        weak var bself = self

        let lsCanary = lua_currentStateGeneration()
        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            let L = lua_getCurrentState()!
            if !lua_isStateGenerationValid(lsCanary) { return }
            if let mySelf = bself {
                if deleteWindow {
                    mySelf.close()
                    L.push(wv_userdata_gc)
                    if let udRef = mySelf.udRef {
                        udRef.push(onto: L)
                    } else {
                        lua_pushnil(L)
                    }
                    if lua_pcall(L, 1, 0, 0) != LUA_OK {
                        os_log(.debug, "%{public}s", String(format: "%s:error invoking _gc for delete (with fade) method:%s", wv_USERDATA_TAG, lua_tostring(L, -1)!))
                        lua_pop(L, 1)
                    }
                } else {
                    mySelf.orderOut(nil)
                    mySelf.alphaValue = 1.0
                }
            }
        }
        self.animator().alphaValue = 0.0
        NSAnimationContext.endGrouping()
    }
}
