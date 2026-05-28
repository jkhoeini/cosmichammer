import Cocoa
import Carbon
import IOKit.graphics
import LuaSkin
import os.log

private let USERDATA_TAG = "hs.screen"

// MARK: - Helper: get NSScreen from Lua userdata

private func get_screen_arg(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSScreen {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<NSScreen>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee).takeUnretainedValue()
}

// MARK: - Dynamic load for CGDisplayCreateImageForRect

// CGDisplayCreateImageForRect is marked obsoleted in macOS 15 SDK but still works at runtime.
// We load it dynamically to bypass the SDK's availability annotation until ScreenCaptureKit migration.
private typealias CGDisplayCreateImageForRectFunc = @convention(c) (CGDirectDisplayID, CGRect) -> Unmanaged<CGImage>?
private let hs_CGDisplayCreateImageForRect: CGDisplayCreateImageForRectFunc? = {
    guard let sym = dlsym(nil, "CGDisplayCreateImageForRect") else { return nil }
    return unsafeBitCast(sym, to: CGDisplayCreateImageForRectFunc.self)
}()

// MARK: - Private API declarations

@_silgen_name("CoreDisplay_Display_SetUserBrightness")
private func CoreDisplay_Display_SetUserBrightness(_ display: CGDirectDisplayID, _ brightness: Double)

@_silgen_name("CoreDisplay_Display_GetUserBrightness")
private func CoreDisplay_Display_GetUserBrightness(_ display: CGDirectDisplayID) -> Double

@_silgen_name("DisplayServicesGetBrightness")
private func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
private func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

// MARK: - CoreGraphics private display mode APIs

private struct CGSDisplayMode {
    var modeNumber: UInt32 = 0
    var flags: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var depth: UInt32 = 0
    var unknown: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // 170 bytes
    var freq: UInt16 = 0
    var more_unknown: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) // 16 bytes
    var density: Float = 0
}

@_silgen_name("CGSGetCurrentDisplayMode")
private func CGSGetCurrentDisplayMode(_ display: CGDirectDisplayID, _ modeNum: UnsafeMutablePointer<Int32>)

@_silgen_name("CGSConfigureDisplayMode")
private func CGSConfigureDisplayMode(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, _ modeNum: Int32)

@_silgen_name("CGSGetNumberOfDisplayModes")
private func CGSGetNumberOfDisplayModes(_ display: CGDirectDisplayID, _ nModes: UnsafeMutablePointer<Int32>)

@_silgen_name("CGSGetDisplayModeDescriptionOfLength")
private func CGSGetDisplayModeDescriptionOfLength(_ display: CGDirectDisplayID, _ idx: Int32, _ mode: UnsafeMutablePointer<CGSDisplayMode>, _ length: Int32)

// IOKit private constant
private let kIOFBSetTransform: UInt32 = 0x00000400

// CoreGraphics private APIs
@_silgen_name("CGDisplayUsesForceToGray")
private func CGDisplayUsesForceToGray() -> Bool

@_silgen_name("CGDisplayForceToGray")
private func CGDisplayForceToGray(_ forceToGray: Bool)

@_silgen_name("CGDisplayUsesInvertedPolarity")
private func CGDisplayUsesInvertedPolarity() -> Bool

@_silgen_name("CGDisplaySetInvertedPolarity")
private func CGDisplaySetInvertedPolarity(_ invertedPolarity: Bool)

// MARK: - Module-level state

private var originalGammas = NSMutableDictionary()
private var currentGammas = NSMutableDictionary()
private var notificationQueue: DispatchQueue!

// MARK: - Helpers

private func geom_pushrect(_ L: UnsafeMutablePointer<lua_State>!, _ rect: NSRect) {
    lua_newtable(L)
    lua_pushnumber(L, lua_Number(rect.origin.x));    lua_setfield(L, -2, "x")
    lua_pushnumber(L, lua_Number(rect.origin.y));    lua_setfield(L, -2, "y")
    lua_pushnumber(L, lua_Number(rect.size.width));  lua_setfield(L, -2, "w")
    lua_pushnumber(L, lua_Number(rect.size.height)); lua_setfield(L, -2, "h")
}

private func getScreenID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
}

// MARK: - Lua callbacks

private func screen_frame(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let screen = get_screen_arg(L, 1)
    geom_pushrect(L, screen.frame)
    return 1
}

private func screen_visibleframe(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let screen = get_screen_arg(L, 1)
    geom_pushrect(L, screen.visibleFrame)
    return 1
}

/// hs.screen:id() -> number
/// Method
/// Returns a screen's unique ID
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the ID of the screen
private func screen_id(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    lua_pushinteger(L, lua_Integer(getScreenID(screen)))
    return 1
}

/// hs.screen:name() -> string or nil
/// Method
/// Returns the preferred name for the screen set by the manufacturer
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the name of the screen, or nil if an error occurred
private func screen_name(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    lua_pushany(L, screen.localizedName as NSString)
    return 1
}

/// hs.screen:currentMode() -> table
/// Method
/// Returns a table describing the current screen mode
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the current screen mode. The keys of the table are:
///   * w - A number containing the width of the screen mode in points
///   * h - A number containing the height of the screen mode in points
///   * scale - A number containing the scaling factor of the screen mode (typically `1` for a native mode, `2` for a HiDPI mode)
///   * freq - A number containing the vertical refresh rate in Hz
///   * depth - A number containing the bit depth
///   * desc - A string containing a representation of the mode as used in `hs.screen:availableModes()` - e.g. "1920x1080@2x 60Hz 4bpp"
private func screen_currentMode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)

    var currentModeNumber: Int32 = 0
    CGSGetCurrentDisplayMode(screen_id, &currentModeNumber)

    var mode = CGSDisplayMode()
    CGSGetDisplayModeDescriptionOfLength(screen_id, currentModeNumber, &mode, Int32(MemoryLayout<CGSDisplayMode>.size))

    lua_newtable(L)

    lua_pushinteger(L, lua_Integer(mode.width))
    lua_setfield(L, -2, "w")

    lua_pushinteger(L, lua_Integer(mode.height))
    lua_setfield(L, -2, "h")

    lua_pushnumber(L, lua_Number(mode.density))
    lua_setfield(L, -2, "scale")

    lua_pushnumber(L, lua_Number(mode.freq))
    lua_setfield(L, -2, "freq")

    lua_pushnumber(L, lua_Number(mode.depth))
    lua_setfield(L, -2, "depth")

    let desc = String(format: "%ux%u@%.0fx %huHz %ubpp", mode.width, mode.height, Double(mode.density), mode.freq, mode.depth)
    lua_pushstring(L, desc)
    lua_setfield(L, -2, "desc")

    return 1
}

/// hs.screen:availableModes() -> table
/// Method
/// Returns a table containing the screen modes supported by the screen. A screen mode is a combination of resolution, scaling factor and colour depth
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the supported screen modes. The keys of the table take the form of "1440x900@2x" (for a HiDPI mode) or "1680x1050@1x" (for a native DPI mode). The values are tables which contain the keys:
///   * w - A number containing the width of the screen mode in points
///   * h - A number containing the height of the screen mode in points
///   * scale - A number containing the scaling factor of the screen mode (typically `1` for a native mode, `2` for a HiDPI mode)
///   * freq - A number containing the vertical refresh rate in Hz
///   * depth - A number containing the bit depth of the display mode
///
/// Notes:
///  * Prior to 0.9.83, only 32-bit colour modes would be returned, but now all colour depths are returned. This has necessitated changing the naming of the modes in the returned table.
///  * "points" are not necessarily the same as pixels, because they take the scale factor into account (e.g. "1440x900@2x" is a 2880x1800 screen resolution, with a scaling factor of 2, i.e. with HiDPI pixel-doubled rendering enabled), however, they are far more useful to work with than native pixel modes, when a Retina screen is involved. For non-retina screens, points and pixels are equivalent.
private func screen_availableModes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)

    var numberOfDisplayModes: Int32 = 0
    CGSGetNumberOfDisplayModes(screen_id, &numberOfDisplayModes)

    lua_newtable(L)

    for i in 0..<numberOfDisplayModes {
        var mode = CGSDisplayMode()
        CGSGetDisplayModeDescriptionOfLength(screen_id, i, &mode, Int32(MemoryLayout<CGSDisplayMode>.size))

        lua_newtable(L)

        lua_pushinteger(L, lua_Integer(mode.width))
        lua_setfield(L, -2, "w")

        lua_pushinteger(L, lua_Integer(mode.height))
        lua_setfield(L, -2, "h")

        lua_pushnumber(L, lua_Number(mode.density))
        lua_setfield(L, -2, "scale")

        lua_pushnumber(L, lua_Number(mode.freq))
        lua_setfield(L, -2, "freq")

        lua_pushnumber(L, lua_Number(mode.depth))
        lua_setfield(L, -2, "depth")

        let key = String(format: "%ux%u@%.0fx %huHz %ubpp", mode.width, mode.height, Double(mode.density), mode.freq, mode.depth)
        lua_setfield(L, -2, key)
    }

    return 1
}

private func handleDisplayUpdate(_ L: UnsafeMutablePointer<lua_State>!, _ config: CGDisplayConfigRef, _ name: String) -> Int32 {
    let anError = CGCompleteDisplayConfiguration(config, .permanently)
    if anError == .success {
        lua_pushboolean(L, 1)
    } else {
        os_log(.debug, "%{public}s", "\(name) failed: \(anError.rawValue)")
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.screen:setMode(width, height, scale, frequency, depth) -> boolean
/// Method
/// Sets the screen to a new mode
///
/// Parameters:
///  * width - A number containing the width in points of the new mode
///  * height - A number containing the height in points of the new mode
///  * scale - A number containing the scaling factor of the new mode (typically 1 for native pixel resolutions, 2 for HiDPI/Retina resolutions)
///  * frequency - A number containing the vertical refresh rate, in Hertz of the new mode
///  * depth - A number containing the bit depth of the new mode
///
/// Returns:
///  * A boolean, true if the requested mode was set, otherwise false
///
/// Notes:
///  * The available widths/heights/scales can be seen in the output of `hs.screen:availableModes()`, however, it should be noted that the CoreGraphics subsystem seems to list more modes for a given screen than it is actually prepared to set, so you may find that seemingly valid modes still return false. It is not currently understood why this is so!
private func screen_setMode(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let screen = get_screen_arg(L, 1)
    let width = lua_tointeger(L, 2)
    let height = lua_tointeger(L, 3)
    let scale = lua_tonumber(L, 4)
    let freq = UInt16(lua_tointeger(L, 5))
    let depth = UInt32(lua_tointeger(L, 6))

    let screen_id = getScreenID(screen)

    var numberOfDisplayModes: Int32 = 0
    CGSGetNumberOfDisplayModes(screen_id, &numberOfDisplayModes)

    for i in 0..<numberOfDisplayModes {
        var mode = CGSDisplayMode()
        CGSGetDisplayModeDescriptionOfLength(screen_id, i, &mode, Int32(MemoryLayout<CGSDisplayMode>.size))

        if mode.depth == depth && mode.freq == freq && mode.width == UInt32(width) && mode.height == UInt32(height) && Int(mode.density) == Int(scale) {
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGSConfigureDisplayMode(config!, screen_id, i)
            return handleDisplayUpdate(L, config!, "CGConfigureDisplayOrigin")
        }
    }

    lua_pushboolean(L, 0)
    return 1
}

/// hs.screen.restoreGamma()
/// Function
/// Restore the gamma settings to defaults
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
///
/// Notes:
///  * This returns all displays to the gamma tables specified by the user's selected ColorSync display profiles
private func screen_gammaRestore(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    CGDisplayRestoreColorSyncSettings()
    currentGammas.removeAllObjects()

    return 0
}

/// hs.screen:getGamma() -> [whitepoint, blackpoint] or nil
/// Method
/// Gets the current whitepoint and blackpoint of the screen
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the white point and black point of the screen, or nil if an error occurred. The keys `whitepoint` and `blackpoint` each have values of a table containing the following keys, with corresponding values between 0.0 and 1.0:
///   * red
///   * green
///   * blue
private func screen_gammaGet(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)
    let gammaCapacity = CGDisplayGammaTableCapacity(screen_id)
    var sampleCount: UInt32 = 0

    let redTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(gammaCapacity))
    let greenTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(gammaCapacity))
    let blueTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(gammaCapacity))
    defer {
        redTable.deallocate()
        greenTable.deallocate()
        blueTable.deallocate()
    }

    if CGGetDisplayTransferByTable(screen_id, gammaCapacity, redTable, greenTable, blueTable, &sampleCount) != .success {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)

    lua_pushstring(L, "blackpoint")
    lua_newtable(L)
    lua_pushstring(L, "red");   lua_pushnumber(L, lua_Number(redTable[0]));   lua_settable(L, -3)
    lua_pushstring(L, "green"); lua_pushnumber(L, lua_Number(greenTable[0])); lua_settable(L, -3)
    lua_pushstring(L, "blue");  lua_pushnumber(L, lua_Number(blueTable[0]));  lua_settable(L, -3)
    lua_pushstring(L, "alpha"); lua_pushnumber(L, 1.0);                       lua_settable(L, -3)
    lua_settable(L, -3)

    lua_pushstring(L, "whitepoint")
    lua_newtable(L)
    lua_pushstring(L, "red");   lua_pushnumber(L, lua_Number(redTable[Int(sampleCount) - 1]));   lua_settable(L, -3)
    lua_pushstring(L, "green"); lua_pushnumber(L, lua_Number(greenTable[Int(sampleCount) - 1])); lua_settable(L, -3)
    lua_pushstring(L, "blue");  lua_pushnumber(L, lua_Number(blueTable[Int(sampleCount) - 1]));  lua_settable(L, -3)
    lua_settable(L, -3)

    return 1
}

func storeInitialScreenGamma(_ display: CGDirectDisplayID) {
    let capacity = CGDisplayGammaTableCapacity(display)
    var count: UInt32 = 0

    let redTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
    let greenTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
    let blueTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: Int(capacity))
    defer {
        redTable.deallocate()
        greenTable.deallocate()
        blueTable.deallocate()
    }

    let result = CGGetDisplayTransferByTable(display, capacity, redTable, greenTable, blueTable, &count)
    if result == .success {
        var red = [NSNumber]()
        var green = [NSNumber]()
        var blue = [NSNumber]()

        for i in 0..<Int(capacity) {
            red.append(NSNumber(value: redTable[i]))
            green.append(NSNumber(value: greenTable[i]))
            blue.append(NSNumber(value: blueTable[i]))
        }

        let gammas: NSDictionary = ["red": red, "green": green, "blue": blue]
        originalGammas[NSNumber(value: display)] = gammas
    } else {
        LuaSkin.skin(with: nil).logBreadcrumb("storeInitialScreenGamma: ERROR \(result.rawValue) on display \(display)")
    }
}

func getAllInitialScreenGammas() {
    var numDisplays: CGDisplayCount = 0
    CGGetActiveDisplayList(0, nil, &numDisplays)

    let displays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: Int(numDisplays))
    defer { displays.deallocate() }
    CGGetActiveDisplayList(numDisplays, displays, nil)

    for i in 0..<Int(numDisplays) {
        storeInitialScreenGamma(displays[i])
    }
}

func screen_gammaReapply(_ display: CGDirectDisplayID) {
    guard let gammas = currentGammas[NSNumber(value: display)] as? NSDictionary else { return }

    guard let red = gammas["red"] as? [NSNumber],
          let green = gammas["green"] as? [NSNumber],
          let blue = gammas["blue"] as? [NSNumber] else { return }

    let count = red.count

    let redTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
    let greenTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
    let blueTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
    defer {
        redTable.deallocate()
        greenTable.deallocate()
        blueTable.deallocate()
    }

    for i in 0..<count {
        redTable[i] = red[i].floatValue
        greenTable[i] = green[i].floatValue
        blueTable[i] = blue[i].floatValue
    }

    let result = CGSetDisplayTransferByTable(display, UInt32(count), redTable, greenTable, blueTable)
    if result != .success {
        LuaSkin.skin(with: nil).logBreadcrumb("screen_gammaReapply: ERROR: \(result.rawValue) on display: \(display)")
    }
}

private func displayReconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.addFlag) {
        storeInitialScreenGamma(display)
    } else if flags.contains(.removeFlag) {
        originalGammas.removeObject(forKey: NSNumber(value: display))
        currentGammas.removeObject(forKey: NSNumber(value: display))
    } else if flags.contains(.disabledFlag) {
        currentGammas.removeObject(forKey: NSNumber(value: display))
    } else if flags.contains(.enabledFlag) || flags.contains(.beginConfigurationFlag) {
        // NOOP
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            screen_gammaReapply(display)
        }
    }
}

/// hs.screen:setGamma(whitepoint, blackpoint) -> boolean
/// Method
/// Sets the current white point and black point of the screen
///
/// Parameters:
///  * whitepoint - A table containing color component values between 0.0 and 1.0 for each of the keys:
///   * red
///   * green
///   * blue
///  * blackpoint - A table containing color component values between 0.0 and 1.0 for each of the keys:
///   * red
///   * green
///   * blue
///
/// Returns:
///  * A boolean, true if the gamma settings were applied, false if an error occurred
///
/// Notes:
///  * If the whitepoint and blackpoint specified, are very similar, it will be impossible to read the screen. You should exercise caution, and may wish to bind a hotkey to `hs.screen.restoreGamma()` when experimenting
private func screen_gammaSet(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)

    var whitePoint: [Float] = [0, 0, 0]
    var blackPoint: [Float] = [0, 0, 0]

    lua_getfield(L, 2, "red");   whitePoint[0] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 2, "green"); whitePoint[1] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 2, "blue");  whitePoint[2] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)

    lua_getfield(L, 3, "red");   blackPoint[0] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 3, "green"); blackPoint[1] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 3, "blue");  blackPoint[2] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)

    guard let originalGamma = originalGammas[NSNumber(value: screen_id)] as? NSDictionary else {
        os_log(.debug, "%{public}s", "screen_gammaSet: unable to fetch original gamma for display: \(screen_id)")
        lua_pushboolean(L, 0)
        return 1
    }

    guard let redArray = originalGamma["red"] as? [NSNumber],
          let greenArray = originalGamma["green"] as? [NSNumber],
          let blueArray = originalGamma["blue"] as? [NSNumber] else {
        os_log(.debug, "%{public}s", "screen_gammaSet: unable to parse gamma arrays for display: \(screen_id)")
        lua_pushboolean(L, 0)
        return 1
    }
    let count = redArray.count

    let redTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
    let greenTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
    let blueTable = UnsafeMutablePointer<CGGammaValue>.allocate(capacity: count)
    defer {
        redTable.deallocate()
        greenTable.deallocate()
        blueTable.deallocate()
    }

    var red = [NSNumber]()
    var green = [NSNumber]()
    var blue = [NSNumber]()

    for i in 0..<count {
        let origRed = redArray[i].floatValue
        let origGreen = greenArray[i].floatValue
        let origBlue = blueArray[i].floatValue

        let newRed = blackPoint[0] + (whitePoint[0] - blackPoint[0]) * origRed
        let newGreen = blackPoint[1] + (whitePoint[1] - blackPoint[1]) * origGreen
        let newBlue = blackPoint[2] + (whitePoint[2] - blackPoint[2]) * origBlue

        redTable[i] = newRed
        greenTable[i] = newGreen
        blueTable[i] = newBlue

        red.append(NSNumber(value: redTable[i]))
        green.append(NSNumber(value: greenTable[i]))
        blue.append(NSNumber(value: blueTable[i]))

        let gammas: NSDictionary = ["red": red, "green": green, "blue": blue]
        currentGammas[NSNumber(value: screen_id)] = gammas
    }

    let result = CGSetDisplayTransferByTable(screen_id, UInt32(count), redTable, greenTable, blueTable)
    if result != .success {
        os_log(.debug, "%{public}s", "screen_gammaSet: ERROR: \(result.rawValue) on display \(screen_id)")
        lua_pushboolean(L, 0)
        return 1
    }

    lua_pushboolean(L, 1)
    return 1
}

/// hs.screen:getBrightness() -> number or nil
/// Method
/// Gets the screen's brightness
///
/// Parameters:
///  * None
///
/// Returns:
///  * A floating point number between 0 and 1, containing the current brightness level, or nil if the display does not support brightness queries
private func screen_getBrightness(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)

    var brightness: Float = 0
    let err = DisplayServicesGetBrightness(screen_id, &brightness)
    if err == 0 {
        lua_pushnumber(L, lua_Number(brightness))
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.screen:setBrightness(brightness) -> `hs.screen` object
/// Method
/// Sets the screen's brightness
///
/// Parameters:
///  * brightness - A floating point number between 0 and 1
///
/// Returns:
///  * The `hs.screen` object
private func screen_setBrightness(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)

    let brightness = Float(lua_tonumber(L, 2))
    _ = DisplayServicesSetBrightness(screen_id, brightness)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.screen:getUUID() -> string
/// Method
/// Gets the UUID of an `hs.screen` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the UUID, or nil if an error occurred.
private func screen_getUUID(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)

    guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(screen_id) else {
        lua_pushnil(L)
        return 1
    }

    let uuid = CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String? ?? ""

    lua_pushany(L, uuid as NSString)
    return 1
}

/// hs.screen:getInfo() -> table or nil
/// Method
/// Gets a table of information about an `hs.screen` object
///
/// Parameters:
///  * None
///
/// Returns:
///  *  A table containing various information, or nil if an error occurred.
private func screen_getDisplayInfo(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let screen_id = getScreenID(screen)

    var deviceInfo: NSDictionary? = nil
    var iter: io_iterator_t = 0
    let matching = IOServiceMatching("IODisplayConnect")
    if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS {
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let info = IODisplayCreateInfoDictionary(service, UInt32(kIODisplayOnlyPreferredName))?.takeRetainedValue() as NSDictionary? {
                if let vendorID = info[kDisplayVendorID] as? UInt32,
                   let productID = info[kDisplayProductID] as? UInt32,
                   vendorID == CGDisplayVendorNumber(screen_id),
                   productID == CGDisplayModelNumber(screen_id) {
                    deviceInfo = info
                    IOObjectRelease(service)
                    break
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        IOObjectRelease(iter)
    }
    lua_pushany(L, deviceInfo)
    return 1
}

/// hs.screen.getForceToGray() -> boolean
/// Method
/// Gets the screen's ForceToGray setting
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the ForceToGray mode is set, otherwise false
private func screen_getForceToGray(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    lua_pushboolean(L, CGDisplayUsesForceToGray() ? 1 : 0)
    return 1
}

/// hs.screen.setForceToGray(ForceToGray) -> None
/// Method
/// Sets the screen's ForceToGray mode
///
/// Parameters:
///  * ForceToGray - A boolean if ForceToGray mode should be enabled
///
/// Returns:
///  * None
private func screen_setForceToGray(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    CGDisplayForceToGray(lua_toboolean(L, 1) != 0)
    return 0
}

/// hs.screen.getInvertedPolarity() -> boolean
/// Method
/// Gets the screen's InvertedPolarity setting
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the InvertedPolarity mode is set, otherwise false
private func screen_getInvertedPolarity(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    lua_pushboolean(L, CGDisplayUsesInvertedPolarity() ? 1 : 0)
    return 1
}

/// hs.screen.setInvertedPolarity(InvertedPolarity) -> None
/// Method
/// Sets the screen's InvertedPolarity mode
///
/// Parameters:
///  * InvertedPolarity - A boolean if InvertedPolarity mode should be enabled
///
/// Returns:
///  * None
private func screen_setInvertedPolarity(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    CGDisplaySetInvertedPolarity(lua_toboolean(L, 1) != 0)
    return 0
}

private func screen_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    let _ = Unmanaged<NSScreen>.fromOpaque(ptr.pointee).takeRetainedValue()
    return 0
}

private func screen_eq(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let screenA = get_screen_arg(L, 1)
    let screenB = get_screen_arg(L, 2)
    lua_pushboolean(L, screenA.isEqual(screenB) ? 1 : 0)
    return 1
}

func new_screen(_ L: UnsafeMutablePointer<lua_State>!, _ screen: NSScreen) {
    let screenPtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    screenPtr.pointee = Unmanaged.passRetained(screen).toOpaque()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
}

/// hs.screen.allScreens() -> hs.screen[]
/// Constructor
/// Returns all the screens
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing one or more `hs.screen` objects
private func screen_allScreens(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    lua_newtable(L)

    var i: lua_Integer = 1
    for screen in NSScreen.screens {
        lua_pushinteger(L, i)
        new_screen(L, screen)
        lua_settable(L, -3)
        i += 1
    }

    return 1
}

/// hs.screen.mainScreen() -> screen
/// Constructor
/// Returns the 'main' screen, i.e. the one containing the currently focused window
///
/// Parameters:
///  * None
///
/// Returns:
///  * An `hs.screen` object
private func screen_mainScreen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    if let main = NSScreen.main {
        new_screen(L, main)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.screen:setPrimary() -> boolean
/// Method
/// Sets the screen to be the primary display (i.e. contain the menubar and dock)
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean, true if the operation succeeded, otherwise false
private func screen_setPrimary(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let maxDisplays: CGDisplayCount = 32
    let screen = get_screen_arg(L, 1)
    let targetDisplay = getScreenID(screen)
    let mainDisplay = CGMainDisplayID()

    if targetDisplay == mainDisplay {
        lua_pushboolean(L, 1)
        return 1
    }

    let onlineDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: Int(maxDisplays))
    defer { onlineDisplays.deallocate() }

    var displayCount: CGDisplayCount = 0
    if CGGetOnlineDisplayList(maxDisplays, onlineDisplays, &displayCount) != .success {
        lua_pushboolean(L, 0)
        return 1
    }

    let deltaX = -Int32(CGDisplayBounds(targetDisplay).minX)
    let deltaY = -Int32(CGDisplayBounds(targetDisplay).minY)

    var config: CGDisplayConfigRef?
    if CGBeginDisplayConfiguration(&config) != .success {
        lua_pushboolean(L, 0)
        return 1
    }

    for i in 0..<Int(displayCount) {
        let dID = onlineDisplays[i]
        let err = CGConfigureDisplayOrigin(config!, dID,
                                           Int32(CGDisplayBounds(dID).minX) + deltaX,
                                           Int32(CGDisplayBounds(dID).minY) + deltaY)
        if err != .success {
            CGCancelDisplayConfiguration(config!)
            lua_pushboolean(L, 0)
            return 1
        }
    }

    CGCompleteDisplayConfiguration(config!, .forSession)

    lua_pushboolean(L, 1)
    return 1
}

/// hs.screen:rotate([degrees]) -> bool or rotation angle
/// Method
/// Gets/Sets the rotation of a screen
///
/// Parameters:
///  * degrees - An optional number indicating how many degrees clockwise, to rotate. If no number is provided, the current rotation will be returned. This number must be one of:
///   * 0
///   * 90
///   * 180
///   * 270
///
/// Returns:
///  * If the rotation is being set, a boolean, true if the operation succeeded, otherwise false. If the rotation is being queried, a number will be returned
private func screen_rotate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let maxDisplays: CGDisplayCount = 32

    var rotation: Int32 = -1

    if lua_type(L, 2) == LUA_TNUMBER {
        switch Int(lua_tointeger(L, 2)) {
        case 0:   rotation = Int32(kIOScaleRotate0)
        case 90:  rotation = Int32(kIOScaleRotate90)
        case 180: rotation = Int32(kIOScaleRotate180)
        case 270: rotation = Int32(kIOScaleRotate270)
        default:
            lua_pushboolean(L, 0)
            return 1
        }
    }

    let screenID = getScreenID(screen)

    if rotation == -1 {
        let currentRotation = CGDisplayRotation(screenID)
        lua_pushinteger(L, lua_Integer(currentRotation))
        return 1
    }

    let onlineDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: Int(maxDisplays))
    defer { onlineDisplays.deallocate() }

    var displayCount: CGDisplayCount = 0
    if CGGetOnlineDisplayList(maxDisplays, onlineDisplays, &displayCount) != .success {
        lua_pushboolean(L, 0)
        return 1
    }

    for i in 0..<Int(displayCount) {
        let dID = onlineDisplays[i]
        if dID == screenID {
            var service: io_service_t = 0
            var iter: io_iterator_t = 0
            let matching = IOServiceMatching("IODisplayConnect")
            if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS {
                var s = IOIteratorNext(iter)
                while s != 0 {
                    if let info = IODisplayCreateInfoDictionary(s, UInt32(kIODisplayOnlyPreferredName))?.takeRetainedValue() as NSDictionary? {
                        if let vendorID = info[kDisplayVendorID] as? UInt32,
                           let productID = info[kDisplayProductID] as? UInt32,
                           vendorID == CGDisplayVendorNumber(dID),
                           productID == CGDisplayModelNumber(dID) {
                            service = s
                            break
                        }
                    }
                    IOObjectRelease(s)
                    s = IOIteratorNext(iter)
                }
                IOObjectRelease(iter)
            }
            guard service != 0 else {
                lua_pushboolean(L, 0)
                return 1
            }
            let options = IOOptionBits(kIOFBSetTransform | (UInt32(rotation) << 16))
            let result = IOServiceRequestProbe(service, options)
            IOObjectRelease(service)
            if result != KERN_SUCCESS {
                lua_pushboolean(L, 0)
                return 1
            }
            break
        }
    }

    lua_pushboolean(L, 1)
    return 1
}

/// hs.screen:setOrigin(x, y) -> bool
/// Method
/// Sets the origin of a screen in the global display coordinate space. The origin of the main or primary display is (0,0). The new origin is placed as close as possible to the requested location, without overlapping or leaving a gap between displays. If you use this function to change the origin of a mirrored display, the display may be removed from the mirroring set.
///
/// Parameters:
///  * x - The desired x-coordinate for the upper-left corner of the display.
///  * y - The desired y-coordinate for the upper-left corner of the display.
///
/// Returns:
///  * true if the operation succeeded, otherwise false
private func screen_setOrigin(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let screen = get_screen_arg(L, 1)
    let x = Int32(lua_tointeger(L, 2))
    let y = Int32(lua_tointeger(L, 3))

    let maxDisplays: CGDisplayCount = 32
    let screenID = getScreenID(screen)

    let onlineDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: Int(maxDisplays))
    defer { onlineDisplays.deallocate() }

    var displayCount: CGDisplayCount = 0
    if CGGetOnlineDisplayList(maxDisplays, onlineDisplays, &displayCount) != .success {
        lua_pushboolean(L, 0)
        return 1
    }

    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    for i in 0..<Int(displayCount) {
        let dID = onlineDisplays[i]
        if dID == screenID {
            CGConfigureDisplayOrigin(config!, dID, x, y)
        }
    }

    return handleDisplayUpdate(L, config!, "CGConfigureDisplayOrigin")
}

/// hs.screen:mirrorOf(aScreen[, permanent]) -> bool
/// Method
/// Make this screen mirror another
///
/// Parameters:
///  * aScreen - an hs.screen object you wish to mirror
///  * permanent - an optional bool, true if this should be configured permanently, false if it should apply just for this login session. Defaults to false.
///
/// Returns:
///  * true if the operation succeeded, otherwise false
private func screen_mirrorOf(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let mirrorTarget = get_screen_arg(L, 1)
    let mirrorSource = get_screen_arg(L, 2)
    let permanent = lua_toboolean(L, 3) != 0

    let sourceID = getScreenID(mirrorSource)
    let targetID = getScreenID(mirrorTarget)

    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    let result = CGConfigureDisplayMirrorOfDisplay(config!, targetID, sourceID)
    CGCompleteDisplayConfiguration(config!, permanent ? .permanently : .forSession)

    lua_pushboolean(L, result == .success ? 1 : 0)
    return 1
}

/// hs.screen:mirrorStop([permanent]) -> bool
/// Method
/// Stops this screen mirroring another
///
/// Parameters:
///  * permanent - an optional bool, true if this should be configured permanently, false if it should apply just for this login session. Defaults to false.
///
/// Returns:
///  * true if the operation succeeded, otherwise false
private func screen_mirrorStop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let permanent = lua_toboolean(L, 2) != 0
    let screenID = getScreenID(screen)

    var config: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&config)
    let result = CGConfigureDisplayMirrorOfDisplay(config!, screenID, kCGNullDirectDisplay)
    CGCompleteDisplayConfiguration(config!, permanent ? .permanently : .forSession)

    lua_pushboolean(L, result == .success ? 1 : 0)
    return 1
}

func screenRectToNSRect(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSRect {
    if lua_isnoneornil(L, idx) || lua_type(L, idx) != LUA_TTABLE {
        return NSZeroRect
    }

    lua_getfield(L, idx, "x")
    let x = lua_type(L, -1) == LUA_TNUMBER ? CGFloat(lua_tonumber(L, -1)) : -1

    lua_getfield(L, idx, "y")
    let y = lua_type(L, -1) == LUA_TNUMBER ? CGFloat(lua_tonumber(L, -1)) : -1

    lua_getfield(L, idx, "w")
    let w = lua_type(L, -1) == LUA_TNUMBER ? CGFloat(lua_tonumber(L, -1)) : -1

    lua_getfield(L, idx, "h")
    let h = lua_type(L, -1) == LUA_TNUMBER ? CGFloat(lua_tonumber(L, -1)) : -1

    lua_pop(L, 4)

    if Int(x) == -1 || Int(y) == -1 || Int(w) == -1 || Int(h) == -1 {
        return NSZeroRect
    }

    return NSMakeRect(x, y, w, h)
}

func screenToNSImage(_ screen: NSScreen, _ screenRect: NSRect) -> NSImage? {
    let screenID = getScreenID(screen)

    let captureRect: CGRect
    if NSIsEmptyRect(screenRect) {
        captureRect = CGDisplayBounds(screenID)
    } else {
        let displayBounds = CGDisplayBounds(screenID)
        captureRect = CGRect(x: displayBounds.origin.x + screenRect.origin.x,
                             y: displayBounds.origin.y + screenRect.origin.y,
                             width: screenRect.size.width,
                             height: screenRect.size.height)
    }

    guard let func_ = hs_CGDisplayCreateImageForRect,
          let cgImageRef = func_(screenID, captureRect) else {
        return nil
    }

    let cgImage = cgImageRef.takeRetainedValue()
    return NSImage(cgImage: cgImage, size: NSZeroSize)
}

/// hs.screen:snapshot([rect]) -> object
/// Method
/// Captures an image of the screen
///
/// Parameters:
///  * rect - An optional `rect-table` containing a portion of the screen to capture. Defaults to the whole screen
///
/// Returns:
///  * An `hs.image` object, or nil if an error occurred
private func screen_snapshot(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let screen = get_screen_arg(L, 1)
    let rect = screenRectToNSRect(L, 2)
    if let image = screenToNSImage(screen, rect) {
        lua_pushany(L, image)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.screen:desktopImageURL([imageURL])
/// Method
/// Gets/Sets the desktop background image for a screen
///
/// Parameters:
///  * imageURL - An optional file:// URL to an image file to set as the background. If omitted, the current file URL is returned
///
/// Returns:
///  * the `hs.screen` object if a new URL was set, otherwise a string containing the current URL
///
/// Notes:
///  * If the user has set a folder of pictures to be alternated as the desktop background, the path to that folder will be returned.
private func screen_desktopImageURL(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let workspace = NSWorkspace.shared
    let screen = get_screen_arg(L, 1)

    if lua_type(L, 2) == LUA_TSTRING {
        let urlString = lua_tovalue(L, at: 2) as! String
        if let realURL = URL(string: urlString) {
            do {
                try workspace.setDesktopImageURL(realURL, for: screen, options: [:])
            } catch {
                os_log(.error, "%{public}s", error.localizedDescription)
            }
        }
        lua_pushvalue(L, 1)
    } else {
        let url = workspace.desktopImageURL(for: screen)
        lua_pushstring(L, url?.absoluteString ?? "")
    }

    return 1
}

/// hs.screen.accessibilitySettings() -> table
/// Function
/// Gets the current state of the screen-related accessibility settings
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the following keys, and corresponding boolean values for whether the user has enabled these options:
///    * ReduceMotion (only available on macOS 10.12 or later)
///    * ReduceTransparency
///    * IncreaseContrast
///    * InvertColors (only available on macOS 10.12 or later)
///    * DifferentiateWithoutColor
private func screen_accessibilitySettings(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let ws = NSWorkspace.shared
    let settings = NSMutableDictionary(capacity: 5)

    settings["InvertColors"] = NSNumber(value: ws.accessibilityDisplayShouldInvertColors)
    settings["ReduceMotion"] = NSNumber(value: ws.accessibilityDisplayShouldReduceMotion)
    settings["ReduceTransparency"] = NSNumber(value: ws.accessibilityDisplayShouldReduceTransparency)
    settings["IncreaseContrast"] = NSNumber(value: ws.accessibilityDisplayShouldIncreaseContrast)
    settings["DifferentiateWithoutColor"] = NSNumber(value: ws.accessibilityDisplayShouldDifferentiateWithoutColor)

    lua_pushany(L, settings)
    return 1
}

private func screens_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, nil)
    _ = screen_gammaRestore(L)
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    let screen = get_screen_arg(L, 1)
    let theName = screen.localizedName
    let ptr = lua_topointer(L, 1)!
    let str = "\(USERDATA_TAG): \(theName) (0x\(String(UInt(bitPattern: ptr), radix: 16)))"
    lua_pushstring(L, str)
    return 1
}

// MARK: - luaL_Reg tables

private var screenlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("allScreens"), func: screen_allScreens),
    luaL_Reg(name: strdup("mainScreen"), func: screen_mainScreen),
    luaL_Reg(name: strdup("restoreGamma"), func: screen_gammaRestore),
    luaL_Reg(name: strdup("accessibilitySettings"), func: screen_accessibilitySettings),
    luaL_Reg(name: strdup("getForceToGray"), func: screen_getForceToGray),
    luaL_Reg(name: strdup("setForceToGray"), func: screen_setForceToGray),
    luaL_Reg(name: strdup("getInvertedPolarity"), func: screen_getInvertedPolarity),
    luaL_Reg(name: strdup("setInvertedPolarity"), func: screen_setInvertedPolarity),
    luaL_Reg(name: nil, func: nil),
]

private var screen_objectlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_frame"), func: screen_frame),
    luaL_Reg(name: strdup("_visibleframe"), func: screen_visibleframe),
    luaL_Reg(name: strdup("id"), func: screen_id),
    luaL_Reg(name: strdup("name"), func: screen_name),
    luaL_Reg(name: strdup("availableModes"), func: screen_availableModes),
    luaL_Reg(name: strdup("currentMode"), func: screen_currentMode),
    luaL_Reg(name: strdup("setMode"), func: screen_setMode),
    luaL_Reg(name: strdup("snapshot"), func: screen_snapshot),
    luaL_Reg(name: strdup("getGamma"), func: screen_gammaGet),
    luaL_Reg(name: strdup("setGamma"), func: screen_gammaSet),
    luaL_Reg(name: strdup("getBrightness"), func: screen_getBrightness),
    luaL_Reg(name: strdup("setBrightness"), func: screen_setBrightness),
    luaL_Reg(name: strdup("getUUID"), func: screen_getUUID),
    luaL_Reg(name: strdup("getInfo"), func: screen_getDisplayInfo),
    luaL_Reg(name: strdup("rotate"), func: screen_rotate),
    luaL_Reg(name: strdup("setPrimary"), func: screen_setPrimary),
    luaL_Reg(name: strdup("desktopImageURL"), func: screen_desktopImageURL),
    luaL_Reg(name: strdup("setOrigin"), func: screen_setOrigin),
    luaL_Reg(name: strdup("mirrorOf"), func: screen_mirrorOf),
    luaL_Reg(name: strdup("mirrorStop"), func: screen_mirrorStop),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: screen_gc),
    luaL_Reg(name: strdup("__eq"), func: screen_eq),
    luaL_Reg(name: nil, func: nil),
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: screens_gc),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libscreen")
public func luaopen_hs_libscreen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Initialize gamma structures, populate them, and register callbacks
    originalGammas = NSMutableDictionary()
    currentGammas = NSMutableDictionary()
    getAllInitialScreenGammas()
    notificationQueue = DispatchQueue(label: "org.cosmic-hammer.CosmicHammer.gammaReapplyNotificationQueue")
    CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &screen_objectlib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(screenlib.count - 1))
    luaL_setfuncs(L, &screenlib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(metalib.count - 1))
    luaL_setfuncs(L, &metalib, 0)
    lua_setmetatable(L, -2)

    return 1
}
