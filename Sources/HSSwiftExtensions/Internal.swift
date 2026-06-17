import Cocoa
import CLua
import Lua
import Carbon

private let USERDATA_TAG = "hs.hints.hint"

// MARK: - Helper: extract NSScreen from hs.screen userdata (ID-based)

private func get_screen_arg(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSScreen {
    let ptr = luaL_checkudata(L, idx, "hs.screen")!
    let screenID = ptr.assumingMemoryBound(to: ScreenUserData.self).pointee.screenID
    // Look up the NSScreen by its CGDirectDisplayID
    return NSScreen.screens.first { screen in
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        return id == screenID
    } ?? NSScreen.main!
}

// MARK: - Helper: extract HintWindow from userdata
// Now uses LuaSwift's checkArgument for class-based userdata.

// MARK: - HintView

private class HintView: NSView {
    private static let hintHeight: CGFloat = 75.0

    private static var hintBackgroundColor: NSColor?
    private static var hintFontColor: NSColor?
    private static var hintFont: NSFont?
    private static var iconFrame: NSRect = .zero
    private static var hintTextAttributes: [NSAttributedString.Key: Any] = [:]
    private static var hintIconAlpha: CGFloat = 0.95

    var text: String = "" {
        didSet {
            textSize = (text as NSString).size(withAttributes: HintView.hintTextAttributes)
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

    static func initCache(fontName: String?, fontSize: CGFloat, iconAlpha: CGFloat) {
        iconFrame = NSMakeRect(0, 0, hintHeight, hintHeight)
        hintBackgroundColor = NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.65)
        hintFontColor = NSColor.white
        if let fontName = fontName {
            hintFont = NSFont(name: fontName, size: fontSize)
        } else {
            hintFont = NSFont.systemFont(ofSize: fontSize > 0.0 ? fontSize : 25.0)
        }
        hintIconAlpha = iconAlpha
        hintTextAttributes = [
            .font: hintFont as Any,
            .foregroundColor: hintFontColor as Any,
        ]
    }

    init(frame: NSRect, fontName: String?, fontSize: CGFloat, iconAlpha: CGFloat) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.icon = nil
        HintView.initCache(fontName: fontName, fontSize: fontSize, iconAlpha: iconAlpha)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    func setIconFromBundleID(_ appBundle: String) {
        var path = ""
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundle) {
            path = url.path
        }
        self.icon = NSWorkspace.shared.icon(forFile: path)
    }

    private func drawCenteredText(_ string: String, bounds rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
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
        HintView.hintBackgroundColor?.set()
        let cornerSize: CGFloat = 10
        let path = NSBezierPath(roundedRect: CGRect(
            x: self.bounds.origin.x + (HintView.hintHeight / 4),
            y: self.bounds.origin.y + (HintView.hintHeight / 4),
            width: 20 + textSize.width,
            height: HintView.hintHeight / 2
        ), xRadius: cornerSize, yRadius: cornerSize)
        path.fill()

        // draw hint letter
        drawCenteredText(text, bounds: self.bounds, attributes: HintView.hintTextAttributes)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

// MARK: - HintWindow

private class HintWindow: NSWindow, LuaTeardownable {
    private var tornDown = false

    convenience init(point pt: CGPoint, text txt: String,
                     forApp bundle: String, onScreen screen: NSScreen,
                     fontName: String?, fontSize: CGFloat, iconAlpha: CGFloat) {
        let height: CGFloat = 75
        let frame = NSMakeRect(pt.x - (height / 2.0),
                               screen.frame.size.height - pt.y - (height / 2.0),
                               100, 75)
        self.init(contentRect: frame,
                  styleMask: .borderless,
                  backing: .buffered,
                  defer: false,
                  screen: screen)
        self.isOpaque = false
        self.backgroundColor = NSColor(deviceRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        self.makeKeyAndOrderFront(NSApp)
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) - 1)
        let label = HintView(frame: frame, fontName: fontName, fontSize: fontSize, iconAlpha: iconAlpha)
        self.contentView = label
        label.setIconFromBundleID(bundle)
        label.text = txt
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        close()
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Module functions

private func hints_test(_ L: LuaState) throws -> CInt {
    let win = HintWindow(point: NSMakePoint(1000, 200), text: "J",
                         forApp: "com.kapeli.dash",
                         onScreen: NSScreen.main!,
                         fontName: nil, fontSize: 0.0, iconAlpha: 0.0)
    L.push(userdata: win)
    return 1
}

private func hints_new(_ L: LuaState) throws -> CInt {
    var fontName: String? = nil
    var fontSize: CGFloat = 0.0

    let x = CGFloat(luaL_checknumber(L, 1))
    let y = CGFloat(luaL_checknumber(L, 2))
    let msg = String(cString: luaL_checkstring(L, 3))
    let app = String(cString: luaL_checkstring(L, 4))
    let screen = get_screen_arg(L, 5)

    if !lua_isnoneornil(L, 6) && lua_isstring(L, 6) != 0 {
        fontName = String(cString: lua_tolstring(L, 6, nil))
    }
    if !lua_isnoneornil(L, 7) && lua_isnumber(L, 7) != 0 {
        fontSize = CGFloat(lua_tonumber(L, 7))
    }
    let iconAlpha = CGFloat(lua_tonumber(L, 8))

    let win = HintWindow(point: NSMakePoint(x, y), text: msg,
                         forApp: app, onScreen: screen,
                         fontName: fontName, fontSize: fontSize, iconAlpha: iconAlpha)
    L.push(userdata: win)
    return 1
}

// MARK: - Entry point

@_cdecl("luaopen_hs_libhints")
public func luaopen_hs_libhints(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register idiomatic Metatable<HintWindow> with LuaSwift.
        L.register(Metatable<HintWindow>(
            fields: [
                "close": .closure { L in
                    let hint: HintWindow = try L.checkArgument(1)
                    hint.teardown()
                    return 0
                },
            ],
            eq: .closure { L in
                let a: HintWindow = try L.checkArgument(1)
                let b: HintWindow = try L.checkArgument(2)
                L.push(a === b)
                return 1
            },
            tostring: .closure { L in
                let _: HintWindow = try L.checkArgument(1)
                let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
                L.push(desc)
                return 1
            }
        ))

        installMetatableBoilerplate(L, for: HintWindow.self, tag: USERDATA_TAG)

        lua_createtable(L, 0, 2)
        L.push(hints_test)
        lua_setfield(L, -2, "test")
        L.push(hints_new)
        lua_setfield(L, -2, "new")
    }
}
