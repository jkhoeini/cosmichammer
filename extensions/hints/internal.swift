import Cocoa
import Carbon
import LuaSkin

private let USERDATA_TAG = "hs.hints.hint"

// MARK: - HintView

class HintView: NSView {
    var text: String = "" {
        didSet {
            textSize = (text as NSString).size(withAttributes: HintView.hintTextAttributes)
            // Might need to resize if text is long
            let newWidth = textSize.width + HintView.hintHeight / 2 + 20
            if newWidth > 100 {
                self.frame = NSMakeRect(self.frame.origin.x, self.frame.origin.y,
                                        newWidth, HintView.hintHeight)
                if var newWinFrame = self.window?.frame {
                    newWinFrame.size.width = newWidth
                    self.window?.setFrame(newWinFrame, display: true)
                }
            }
        }
    }
    var icon: NSImage?
    private var textSize: NSSize = .zero

    private static let hintHeight: CGFloat = 75.0
    private static var hintBackgroundColor: NSColor!
    private static var hintFontColor: NSColor!
    private static var hintFont: NSFont!
    private static var iconFrame: NSRect = .zero
    private static var hintTextAttributes: [NSAttributedString.Key: Any] = [:]
    private static var hintIconAlpha: CGFloat = 0.95

    static func initCache(fontName: String?, fontSize: CGFloat, iconAlpha: CGFloat) {
        iconFrame = NSMakeRect(0, 0, hintHeight, hintHeight)
        hintBackgroundColor = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.65)
        hintFontColor = .white
        if let fontName = fontName, let font = NSFont(name: fontName, size: fontSize) {
            hintFont = font
        } else {
            hintFont = NSFont.systemFont(ofSize: fontSize > 0.0 ? fontSize : 25.0)
        }
        hintIconAlpha = iconAlpha
        hintTextAttributes = [
            .font: hintFont!,
            .foregroundColor: hintFontColor!,
        ]
    }

    init(frame: NSRect, fontName: String?, fontSize: CGFloat, iconAlpha: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        icon = nil
        HintView.initCache(fontName: fontName, fontSize: fontSize, iconAlpha: iconAlpha)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setIcon(fromBundleID appBundle: String) {
        var path = ""
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundle) {
            path = url.path
        }
        icon = NSWorkspace.shared.icon(forFile: path)
    }

    private func drawCenteredText(_ string: String, bounds rect: NSRect,
                                  attributes: [NSAttributedString.Key: Any]) {
        let origin = NSMakePoint(rect.origin.x + (HintView.hintHeight / 4) + 10,
                                 rect.origin.y + (HintView.hintHeight - textSize.height) / 2)
        (string as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = true

        if let icon = icon {
            icon.draw(in: HintView.iconFrame, from: .zero,
                      operation: .sourceOver, fraction: HintView.hintIconAlpha)
        }

        // draw the rounded rect
        HintView.hintBackgroundColor.set()
        let cornerSize: CGFloat = 10
        let path = NSBezierPath(roundedRect: CGRect(
            x: bounds.origin.x + (HintView.hintHeight / 4),
            y: bounds.origin.y + (HintView.hintHeight / 4),
            width: 20 + textSize.width,
            height: HintView.hintHeight / 2
        ), xRadius: cornerSize, yRadius: cornerSize)
        path.fill()

        // draw hint letter
        drawCenteredText(text, bounds: bounds, attributes: HintView.hintTextAttributes)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// MARK: - HintWindow

class HintWindow: NSWindow {
    convenience init(point pt: CGPoint, text txt: String, forApp bundle: String,
                     onScreen screen: NSScreen, fontName: String?, fontSize: CGFloat,
                     iconAlpha: CGFloat) {
        let height: CGFloat = 75
        let frame = NSMakeRect(pt.x - (height / 2.0),
                               screen.frame.size.height - pt.y - (height / 2.0), 100, 75)
        self.init(contentRect: frame,
                  styleMask: .borderless,
                  backing: .buffered,
                  defer: false,
                  screen: screen)
        isOpaque = false
        backgroundColor = NSColor(deviceRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        makeKeyAndOrderFront(NSApp)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        let label = HintView(frame: frame, fontName: fontName, fontSize: fontSize,
                              iconAlpha: iconAlpha)
        contentView = label
        label.setIcon(fromBundleID: bundle)
        label.text = txt
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Lua callbacks

private func hint_close(_ L: OpaquePointer!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let hint = Unmanaged<HintWindow>.fromOpaque(
        ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    ).takeUnretainedValue()
    hint.close()
    lua_pushnil(L)
    lua_setmetatable(L, -2)
    return 0
}

private func hint_eq(_ L: OpaquePointer!) -> Int32 {
    let ptrA = luaL_checkudata(L, 1, USERDATA_TAG)!
    let ptrB = luaL_checkudata(L, 2, USERDATA_TAG)!
    let hintA = Unmanaged<HintWindow>.fromOpaque(
        ptrA.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    ).takeUnretainedValue()
    let hintB = Unmanaged<HintWindow>.fromOpaque(
        ptrB.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    ).takeUnretainedValue()
    lua_pushboolean(L, hintA === hintB ? 1 : 0)
    return 1
}

private func new_hint(_ L: OpaquePointer!, _ window: HintWindow) {
    let hintPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    hintPtr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee =
        Unmanaged.passRetained(window).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
}

private func hints_test(_ L: OpaquePointer!) -> Int32 {
    let win = HintWindow(point: NSMakePoint(1000, 200), text: "J",
                          forApp: "com.kapeli.dash", onScreen: NSScreen.main!,
                          fontName: nil, fontSize: 0.0, iconAlpha: 0.0)
    new_hint(L, win)
    return 1
}

private func hints_new(_ L: OpaquePointer!) -> Int32 {
    var fontName: String? = nil
    var fontSize: CGFloat = 0.0
    let x = CGFloat(luaL_checknumber(L, 1))
    let y = CGFloat(luaL_checknumber(L, 2))
    let msg = String(cString: luaL_checkstring(L, 3))
    let app = String(cString: luaL_checkstring(L, 4))

    let screenPtr = luaL_checkudata(L, 5, "hs.screen")!
    let screen = Unmanaged<NSScreen>.fromOpaque(
        screenPtr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee
    ).takeUnretainedValue()

    if lua_isnoneornil(L, 6) == 0 && lua_isstring(L, 6) != 0 {
        fontName = String(cString: lua_tolstring(L, 6, nil))
    }
    if lua_isnoneornil(L, 7) == 0 && lua_isnumber(L, 7) != 0 {
        fontSize = CGFloat(lua_tonumber(L, 7))
    }
    let iconAlpha = CGFloat(lua_tonumber(L, 8))

    let win = HintWindow(point: NSMakePoint(x, y), text: msg, forApp: app,
                          onScreen: screen, fontName: fontName, fontSize: fontSize,
                          iconAlpha: iconAlpha)
    new_hint(L, win)
    return 1
}

private func userdata_tostring(_ L: OpaquePointer!) -> Int32 {
    let str = String(format: "%@: (%p)", USERDATA_TAG, lua_topointer(L, 1))
    lua_pushstring(L, str)
    return 1
}

// MARK: - Module registration

private var hintslib: [luaL_Reg] = [
    luaL_Reg(name: ("test" as NSString).utf8String, func: hints_test),
    luaL_Reg(name: ("new"  as NSString).utf8String, func: hints_new),
    luaL_Reg(name: nil, func: nil),
]

private var hints_metalib: [luaL_Reg] = [
    luaL_Reg(name: ("__eq"       as NSString).utf8String, func: hint_eq),
    luaL_Reg(name: ("__gc"       as NSString).utf8String, func: hint_close),
    luaL_Reg(name: ("__tostring" as NSString).utf8String, func: userdata_tostring),
    luaL_Reg(name: ("close"      as NSString).utf8String, func: hint_close),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhints")
func luaopen_hs_libhints(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.registerLibrary(withObject: USERDATA_TAG, functions: &hintslib,
                         metaFunctions: nil, objectFunctions: &hints_metalib)
    return 1
}
