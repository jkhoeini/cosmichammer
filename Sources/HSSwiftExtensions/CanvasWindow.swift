import Cocoa
import LuaSkin
import os.log

// MARK: - HSCanvasWindow

@objc class HSCanvasWindow: NSPanel, NSWindowDelegate {
    @objc var subroleOverride: String?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        guard contentRect.origin.x.isFinite && contentRect.origin.y.isFinite &&
              contentRect.size.height.isFinite && contentRect.size.width.isFinite else {
            os_log(.error, "%{public}s:coordinates must be finite numbers", canvas_USERDATA_TAG)
            // Cannot return nil from a non-failable init in Swift; the ObjC version returned nil.
            // We initialize with zero rect and the caller checks for validity.
            super.init(contentRect: .zero, styleMask: style, backing: backingStoreType, defer: flag)
            return
        }

        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        self.delegate = self

        self.setFrameOrigin(canvas_RectWithFlippedYCoordinate(contentRect).origin)

        // Configure the window
        self.isReleasedWhenClosed = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.isRestorable = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        subroleOverride = nil
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        let defaultSubrole = super.accessibilitySubrole()
        let defaultStr = defaultSubrole?.rawValue ?? ""
        let customSubrole = NSAccessibility.Subrole(rawValue: defaultStr + ".Cosmic Hammer")

        if let override = subroleOverride {
            if override.isEmpty {
                return canvas_defaultCustomSubRole ? defaultSubrole : customSubrole
            } else {
                return NSAccessibility.Subrole(rawValue: override)
            }
        } else {
            return canvas_defaultCustomSubRole ? customSubrole : defaultSubrole
        }
    }

    override var canBecomeKey: Bool {
        var allowKey = false
        if let canvasView = self.contentView as? HSCanvasView {
            for element in canvasView.elementList {
                if let dict = element as? NSDictionary,
                   let canvas = dict["canvas"] as? NSView,
                   canvas.canBecomeKeyView {
                    allowKey = true
                    break
                }
            }
        }
        return allowKey
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return false
    }

    // MARK: Window Animation Methods

    func fadeIn(_ fadeTime: TimeInterval) {
        let alphaSetting = self.alphaValue
        self.alphaValue = 0.0
        self.makeKeyAndOrderFront(nil)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = fadeTime
        self.animator().alphaValue = alphaSetting
        NSAnimationContext.endGrouping()
    }

    func fadeOut(_ fadeTime: TimeInterval, andDelete deleteCanvas: Bool, withState L: UnsafeMutablePointer<lua_State>!) {
        guard let theView = self.contentView as? HSCanvasView else { return }
        if theView.selfRef != LUA_NOREF { return } // already in a fade

        // Push the canvas view userdata and create a reference to prevent GC during fade
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(canvas_refTable))
        // We need the view on the stack - push via its userdata
        lua_pushany(L, theView)
        theView.selfRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        let alphaSetting = self.alphaValue
        NSAnimationContext.beginGrouping()
        weak var bself = self
        let generation = lua_currentStateGeneration()

        NSAnimationContext.current.duration = fadeTime
        NSAnimationContext.current.completionHandler = {
            DispatchQueue.main.async {
                guard let mySelf = bself,
                      let myView = mySelf.contentView as? HSCanvasView,
                      myView.selfRef != LUA_NOREF else { return }

                if lua_isStateGenerationValid(generation) {
                    luaL_unref(LuaSkin.skin(with: nil).l!, LUA_REGISTRYINDEX_VALUE, myView.selfRef)
                    myView.selfRef = LUA_NOREF
                }

                mySelf.orderOut(nil)
                mySelf.alphaValue = alphaSetting
            }
        }
        self.animator().alphaValue = 0.0
        NSAnimationContext.endGrouping()
    }
}

