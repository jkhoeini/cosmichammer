import Foundation
import Cocoa
import WebKit
import LuaSkin

// MARK: - HSWebViewWindow

class HSWebViewWindow: NSPanel, NSWindowDelegate {
    var parentWebView: HSWebViewWindow?
    var children: NSMutableArray = NSMutableArray()
    var udRef: Int32 = LUA_NOREF
    var windowCallback: Int32 = LUA_NOREF
    var allowKeyboardEntry: Bool = false
    var darkMode: Bool = false
    var titleFollow: Bool = true
    var deleteOnClose: Bool = false
    var closeOnEscape: Bool = false
    var lsCanary: LSGCCanary = LSGCCanary()

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
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!

        if !skin.check(lsCanary) { return }
        _lua_stackguard_entry(L)

        if windowCallback != LUA_NOREF {
            skin.pushLuaRef(wv_refTable, ref: windowCallback)
            skin.pushNSObject("closing" as NSString)
            skin.pushNSObject(self)
            skin.protectedCallAndError("hs.webview:windowCallback:closing", nargs: 2, nresults: 0)
        }
        if deleteOnClose {
            lua_pushcfunction(L, wv_userdata_gc)
            skin.pushNSObject(self)
            if lua_pcall(L, 1, 0, 0) != LUA_OK {
                skin.logError(String(format: "%s:error invoking _gc for deleteOnClose:%s", wv_USERDATA_TAG, lua_tostring(L, -1)!))
                lua_pop(L, 1)
            }
        }
        _lua_stackguard_exit(L)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(wv_refTable, ref: self.windowCallback)
                skin.pushNSObject("focusChange" as NSString)
                skin.pushNSObject(self)
                lua_pushboolean(skin.l, 1)
                skin.protectedCallAndError("hs.webview:windowCallback:focusChange", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(wv_refTable, ref: self.windowCallback)
                skin.pushNSObject("focusChange" as NSString)
                skin.pushNSObject(self)
                lua_pushboolean(skin.l, 0)
                skin.protectedCallAndError("hs.webview:windowCallback:focusChange", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(wv_refTable, ref: self.windowCallback)
                skin.pushNSObject("frameChange" as NSString)
                skin.pushNSObject(self)
                skin.pushNSRect(wv_RectWithFlippedYCoordinate(self.frame))
                skin.protectedCallAndError("hs.webview:windowCallback:frameChange:resize", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.l)
            }
        }
    }

    func windowDidMove(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.windowCallback != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(wv_refTable, ref: self.windowCallback)
                skin.pushNSObject("frameChange" as NSString)
                skin.pushNSObject(self)
                skin.pushNSRect(wv_RectWithFlippedYCoordinate(self.frame))
                skin.protectedCallAndError("hs.webview:windowCallback:frameChange:move", nargs: 3, nresults: 0)
                _lua_stackguard_exit(skin.l)
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

        let outerSkin = LuaSkin.skin(with: L)
        let lsCanary = outerSkin.createGCCanary()
        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            let skin = LuaSkin.skin(with: nil)
            if !skin.check(lsCanary) { return }
            if let mySelf = bself {
                if deleteWindow {
                    mySelf.close()
                    lua_pushcfunction(L, wv_userdata_gc)
                    skin.pushLuaRef(wv_refTable, ref: mySelf.udRef)
                    if lua_pcall(L, 1, 0, 0) != LUA_OK {
                        skin.logBreadcrumb(String(format: "%s:error invoking _gc for delete (with fade) method:%s", wv_USERDATA_TAG, lua_tostring(L, -1)!))
                        lua_pop(L, 1)
                    }
                } else {
                    mySelf.orderOut(nil)
                    mySelf.alphaValue = 1.0
                }
            }
            var mutableCanary = lsCanary
            skin.destroy(&mutableCanary)
        }
        self.animator().alphaValue = 0.0
        NSAnimationContext.endGrouping()
    }
}

