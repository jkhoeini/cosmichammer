import Cocoa
import CLua
import Lua
import os.log
import HSDSTCore

private let USERDATA_TAG = "hs.screen"

// MARK: - Userdata: UInt32 screen ID (like Audiodevice)

struct ScreenUserData {
    var screenID: UInt32
}

private func userdataToScreen(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<ScreenUserData> {
    return luaL_checkudata(L, idx, USERDATA_TAG).assumingMemoryBound(to: ScreenUserData.self)
}

// MARK: - Module-level state

/// Original gamma tables stored at module init for gamma set/restore.
/// Keyed by display ID as NSNumber.
private var originalGammas = NSMutableDictionary()
/// Currently applied gamma tables. Keyed by display ID as NSNumber.
private var currentGammas = NSMutableDictionary()

// MARK: - Helpers

private func geom_pushrect(_ L: UnsafeMutablePointer<lua_State>!, _ rect: (x: Double, y: Double, width: Double, height: Double)) {
    precondition(L != nil, "geom_pushrect: L must not be nil")
    let previousTop = lua_gettop(L)
    lua_newtable(L)
    L.push(lua_Number(rect.x));      lua_setfield(L, -2, "x")
    L.push(lua_Number(rect.y));      lua_setfield(L, -2, "y")
    L.push(lua_Number(rect.width));  lua_setfield(L, -2, "w")
    L.push(lua_Number(rect.height)); lua_setfield(L, -2, "h")
    assert(lua_gettop(L) == previousTop + 1, "geom_pushrect: stack should grow by exactly 1 (table)")
}

// MARK: - Lua callbacks

private func screen_frame(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    guard let info = scr.screenInfo(forScreenID: ud.pointee.screenID) else {
        lua_pushnil(L)
        return 1
    }
    geom_pushrect(L, info.frame)
    return 1
}

private func screen_visibleframe(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    guard let info = scr.screenInfo(forScreenID: ud.pointee.screenID) else {
        lua_pushnil(L)
        return 1
    }
    geom_pushrect(L, info.visibleFrame)
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
private func screen_id(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    L.push(lua_Integer(ud.pointee.screenID))
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
private func screen_name(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    if let info = scr.screenInfo(forScreenID: ud.pointee.screenID) {
        lua_pushany(L, info.name as NSString)
    } else {
        lua_pushnil(L)
    }
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
private func screen_currentMode(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen

    guard let mode = scr.currentDisplayMode(forScreenID: ud.pointee.screenID) else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)

    L.push(lua_Integer(mode.width))
    lua_setfield(L, -2, "w")

    L.push(lua_Integer(mode.height))
    lua_setfield(L, -2, "h")

    L.push(lua_Number(mode.density))
    lua_setfield(L, -2, "scale")

    L.push(lua_Number(mode.frequency))
    lua_setfield(L, -2, "freq")

    L.push(lua_Number(mode.depth))
    lua_setfield(L, -2, "depth")

    let desc = String(format: "%ux%u@%.0fx %huHz %ubpp", mode.width, mode.height, Double(mode.density), mode.frequency, mode.depth)
    L.push(desc)
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
private func screen_availableModes(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    let modes = scr.availableDisplayModes(forScreenID: ud.pointee.screenID)

    lua_newtable(L)

    for mode in modes {
        lua_newtable(L)

        L.push(lua_Integer(mode.width))
        lua_setfield(L, -2, "w")

        L.push(lua_Integer(mode.height))
        lua_setfield(L, -2, "h")

        L.push(lua_Number(mode.density))
        lua_setfield(L, -2, "scale")

        L.push(lua_Number(mode.frequency))
        lua_setfield(L, -2, "freq")

        L.push(lua_Number(mode.depth))
        lua_setfield(L, -2, "depth")

        let key = String(format: "%ux%u@%.0fx %huHz %ubpp", mode.width, mode.height, Double(mode.density), mode.frequency, mode.depth)
        lua_setfield(L, -2, key)
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
private func screen_setMode(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let width = lua_tointeger(L, 2)
    let height = lua_tointeger(L, 3)
    let scale = lua_tonumber(L, 4)
    let freq = UInt16(lua_tointeger(L, 5))
    let depth = UInt32(lua_tointeger(L, 6))

    let scr = environmentGet(L).screen
    let screenID = ud.pointee.screenID
    let modes = scr.availableDisplayModes(forScreenID: screenID)

    for mode in modes {
        if mode.depth == depth && mode.frequency == freq && mode.width == UInt32(width) && mode.height == UInt32(height) && Int(mode.density) == Int(scale) {
            L.push(scr.setDisplayMode(mode.modeNumber, forScreenID: screenID))
            return 1
        }
    }

    L.push(false)
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
private func screen_gammaRestore(_ L: LuaState) throws -> CInt {

    environmentGet(L).screen.restoreGamma()
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
private func screen_gammaGet(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen

    guard let gamma = scr.getGammaTable(forScreenID: ud.pointee.screenID) else {
        lua_pushnil(L)
        return 1
    }

    guard !gamma.red.isEmpty else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)

    L.push("blackpoint")
    lua_newtable(L)
    L.push("red");   L.push(lua_Number(gamma.red[0]));   lua_settable(L, -3)
    L.push("green"); L.push(lua_Number(gamma.green[0])); lua_settable(L, -3)
    L.push("blue");  L.push(lua_Number(gamma.blue[0]));  lua_settable(L, -3)
    L.push("alpha"); L.push(1.0);                        lua_settable(L, -3)
    lua_settable(L, -3)

    L.push("whitepoint")
    lua_newtable(L)
    L.push("red");   L.push(lua_Number(gamma.red[gamma.red.count - 1]));     lua_settable(L, -3)
    L.push("green"); L.push(lua_Number(gamma.green[gamma.green.count - 1])); lua_settable(L, -3)
    L.push("blue");  L.push(lua_Number(gamma.blue[gamma.blue.count - 1]));   lua_settable(L, -3)
    lua_settable(L, -3)

    return 1
}

func storeInitialScreenGamma(_ display: UInt32, using scr: any ScreenProtocol) {
    precondition(display != 0, "storeInitialScreenGamma: display must not be kCGNullDirectDisplay")

    guard let gamma = scr.getGammaTable(forScreenID: display) else {
        os_log(.default, "%{public}s", "storeInitialScreenGamma: could not read gamma for display \(display)")
        return
    }
    guard !gamma.red.isEmpty else { return }

    let red = gamma.red.map { NSNumber(value: $0) }
    let green = gamma.green.map { NSNumber(value: $0) }
    let blue = gamma.blue.map { NSNumber(value: $0) }

    let gammas: NSDictionary = ["red": red, "green": green, "blue": blue]
    originalGammas[NSNumber(value: display)] = gammas
}

func getAllInitialScreenGammas(using scr: any ScreenProtocol) {
    let screens = scr.allScreens()
    for screen in screens {
        storeInitialScreenGamma(screen.id, using: scr)
    }
}

func screen_gammaReapply(_ display: UInt32, using scr: any ScreenProtocol) {
    guard let gammas = currentGammas[NSNumber(value: display)] as? NSDictionary else { return }

    guard let red = gammas["red"] as? [NSNumber],
          let green = gammas["green"] as? [NSNumber],
          let blue = gammas["blue"] as? [NSNumber] else { return }

    let count = red.count
    precondition(count > 0, "screen_gammaReapply: gamma table must not be empty")
    precondition(green.count == count, "screen_gammaReapply: green table length must match red")
    precondition(blue.count == count, "screen_gammaReapply: blue table length must match red")

    let table = GammaTable(
        red: red.map { $0.floatValue },
        green: green.map { $0.floatValue },
        blue: blue.map { $0.floatValue }
    )

    if !scr.setGammaTable(table, forScreenID: display) {
        os_log(.default, "%{public}s", "screen_gammaReapply: failed on display: \(display)")
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
private func screen_gammaSet(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let screenID = ud.pointee.screenID
    let scr = environmentGet(L).screen

    var whitePoint: [Float] = [0, 0, 0]
    var blackPoint: [Float] = [0, 0, 0]

    lua_getfield(L, 2, "red");   whitePoint[0] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 2, "green"); whitePoint[1] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 2, "blue");  whitePoint[2] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)

    lua_getfield(L, 3, "red");   blackPoint[0] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 3, "green"); blackPoint[1] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)
    lua_getfield(L, 3, "blue");  blackPoint[2] = Float(lua_tonumber(L, -1)); lua_pop(L, 1)

    guard let originalGamma = originalGammas[NSNumber(value: screenID)] as? NSDictionary else {
        os_log(.debug, "%{public}s", "screen_gammaSet: unable to fetch original gamma for display: \(screenID)")
        L.push(false)
        return 1
    }

    guard let redArray = originalGamma["red"] as? [NSNumber],
          let greenArray = originalGamma["green"] as? [NSNumber],
          let blueArray = originalGamma["blue"] as? [NSNumber] else {
        os_log(.debug, "%{public}s", "screen_gammaSet: unable to parse gamma arrays for display: \(screenID)")
        L.push(false)
        return 1
    }
    let count = redArray.count

    var red = [NSNumber]()
    var green = [NSNumber]()
    var blue = [NSNumber]()

    var newRedValues = [Float]()
    var newGreenValues = [Float]()
    var newBlueValues = [Float]()

    for i in 0..<count {
        let origRed = redArray[i].floatValue
        let origGreen = greenArray[i].floatValue
        let origBlue = blueArray[i].floatValue

        let newRed = blackPoint[0] + (whitePoint[0] - blackPoint[0]) * origRed
        let newGreen = blackPoint[1] + (whitePoint[1] - blackPoint[1]) * origGreen
        let newBlue = blackPoint[2] + (whitePoint[2] - blackPoint[2]) * origBlue

        newRedValues.append(newRed)
        newGreenValues.append(newGreen)
        newBlueValues.append(newBlue)

        red.append(NSNumber(value: newRed))
        green.append(NSNumber(value: newGreen))
        blue.append(NSNumber(value: newBlue))
    }

    let table = GammaTable(red: newRedValues, green: newGreenValues, blue: newBlueValues)
    let success = scr.setGammaTable(table, forScreenID: screenID)

    if success {
        let gammasDict: NSDictionary = ["red": red, "green": green, "blue": blue]
        currentGammas[NSNumber(value: screenID)] = gammasDict
    } else {
        os_log(.debug, "%{public}s", "screen_gammaSet: failed on display \(screenID)")
    }

    L.push(success)
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
private func screen_getBrightness(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen

    if let brightness = scr.getBrightness(forScreenID: ud.pointee.screenID) {
        L.push(lua_Number(brightness))
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
private func screen_setBrightness(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 2, LUA_TNUMBER)

    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    let brightness = lua_tonumber(L, 2)
    _ = scr.setBrightness(brightness, forScreenID: ud.pointee.screenID)

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
private func screen_getUUID(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen

    if let uuid = scr.getUUID(forScreenID: ud.pointee.screenID) {
        lua_pushany(L, uuid as NSString)
    } else {
        lua_pushnil(L)
    }
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
private func screen_getDisplayInfo(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen

    if let info = scr.getDisplayInfo(forScreenID: ud.pointee.screenID) {
        lua_pushany(L, info as NSDictionary)
    } else {
        lua_pushnil(L)
    }
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
private func screen_getForceToGray(_ L: LuaState) throws -> CInt {

    L.push(environmentGet(L).screen.usesForceToGray())
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
private func screen_setForceToGray(_ L: LuaState) throws -> CInt {

    environmentGet(L).screen.setForceToGray(lua_toboolean(L, 1) != 0)
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
private func screen_getInvertedPolarity(_ L: LuaState) throws -> CInt {

    L.push(environmentGet(L).screen.usesInvertedPolarity())
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
private func screen_setInvertedPolarity(_ L: LuaState) throws -> CInt {

    environmentGet(L).screen.setInvertedPolarity(lua_toboolean(L, 1) != 0)
    return 0
}

private func screen_gc(_ L: LuaState) throws -> CInt {
    // ScreenUserData is a plain struct — no ARC objects to release.
    // Zero the screen ID to guard against double-gc.
    let ud = userdataToScreen(L, 1)
    ud.pointee.screenID = 0
    return 0
}

private func screen_eq(_ L: LuaState) throws -> CInt {
    let a = userdataToScreen(L, 1)
    let b = userdataToScreen(L, 2)
    L.push(a.pointee.screenID == b.pointee.screenID)
    return 1
}

func new_screen(_ L: UnsafeMutablePointer<lua_State>!, _ screenID: UInt32) {
    precondition(L != nil, "new_screen: L must not be nil")
    precondition(screenID != 0, "new_screen: screenID must not be 0")
    let previousTop = lua_gettop(L)
    let ptr = lua_newuserdata(L, MemoryLayout<ScreenUserData>.size)!.assumingMemoryBound(to: ScreenUserData.self)
    ptr.pointee.screenID = screenID

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    assert(lua_gettop(L) == previousTop + 1, "new_screen: stack should grow by exactly 1")
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
private func screen_allScreens(_ L: LuaState) throws -> CInt {
    let scr = environmentGet(L).screen
    let screens = scr.allScreens()

    lua_newtable(L)

    for (i, screen) in screens.enumerated() {
        L.push(lua_Integer(i + 1))
        new_screen(L, screen.id)
        lua_settable(L, -3)
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
private func screen_mainScreen(_ L: LuaState) throws -> CInt {
    let scr = environmentGet(L).screen

    if let main = scr.mainScreen() {
        new_screen(L, main.id)
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
private func screen_setPrimary(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    L.push(scr.setPrimary(screenID: ud.pointee.screenID))
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
private func screen_rotate(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    let screenID = ud.pointee.screenID

    // No argument -> query
    if lua_type(L, 2) != LUA_TNUMBER {
        let rotation = scr.getRotation(forScreenID: screenID)
        L.push(lua_Integer(Int(rotation)))
        return 1
    }

    let degrees = lua_tointeger(L, 2)
    switch degrees {
    case 0, 90, 180, 270:
        L.push(scr.setRotation(Double(degrees), forScreenID: screenID))
    default:
        L.push(false)
    }
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
private func screen_setOrigin(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let x = Int32(lua_tointeger(L, 2))
    let y = Int32(lua_tointeger(L, 3))
    let scr = environmentGet(L).screen

    L.push(scr.setOrigin(screenID: ud.pointee.screenID, x: x, y: y))
    return 1
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
private func screen_mirrorOf(_ L: LuaState) throws -> CInt {
    let mirrorTarget = userdataToScreen(L, 1)
    let mirrorSource = userdataToScreen(L, 2)
    let permanent = lua_toboolean(L, 3) != 0
    let scr = environmentGet(L).screen

    L.push(scr.mirrorOf(targetScreenID: mirrorTarget.pointee.screenID,
                         sourceScreenID: mirrorSource.pointee.screenID,
                         permanent: permanent))
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
private func screen_mirrorStop(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let permanent = lua_toboolean(L, 2) != 0
    let scr = environmentGet(L).screen

    L.push(scr.mirrorStop(screenID: ud.pointee.screenID, permanent: permanent))
    return 1
}

func screenRectToNSRect(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSRect {
    precondition(L != nil, "screenRectToNSRect: L must not be nil")
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

/// hs.screen:snapshot([rect]) -> object
/// Method
/// Captures an image of the screen
///
/// Parameters:
///  * rect - An optional `rect-table` containing a portion of the screen to capture. Defaults to the whole screen
///
/// Returns:
///  * An `hs.image` object, or nil if an error occurred
private func screen_snapshot(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    let screenID = ud.pointee.screenID

    let luaRect = screenRectToNSRect(L, 2)
    let bounds = scr.displayBounds(forScreenID: screenID)

    let captureRect: (x: Double, y: Double, width: Double, height: Double)
    if NSIsEmptyRect(luaRect) {
        captureRect = bounds
    } else {
        captureRect = (bounds.x + Double(luaRect.origin.x),
                       bounds.y + Double(luaRect.origin.y),
                       Double(luaRect.size.width),
                       Double(luaRect.size.height))
    }

    if let data = scr.captureScreenRect(displayID: screenID, rect: captureRect) {
        if let nsImage = NSImage(data: data) {
            lua_pushany(L, nsImage)
        } else {
            lua_pushnil(L)
        }
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
private func screen_desktopImageURL(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    let screenID = ud.pointee.screenID

    if lua_type(L, 2) == LUA_TSTRING {
        let urlString = lua_tovalue(L, at: 2) as! String
        _ = scr.setDesktopImageURL(urlString, forScreenID: screenID)
        lua_pushvalue(L, 1)
    } else {
        let url = scr.desktopImageURL(forScreenID: screenID) ?? ""
        L.push(url)
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
private func screen_accessibilitySettings(_ L: LuaState) throws -> CInt {
    let scr = environmentGet(L).screen
    let settings = scr.accessibilityDisplaySettings()

    let nsDict = NSMutableDictionary(capacity: settings.count)
    for (key, value) in settings {
        nsDict[key] = NSNumber(value: value)
    }

    lua_pushany(L, nsDict)
    return 1
}

private func screens_gc(_ L: LuaState) throws -> CInt {
    CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, nil)
    _ = try screen_gammaRestore(L)
    return 0
}

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let ud = userdataToScreen(L, 1)
    let scr = environmentGet(L).screen
    let theName = scr.screenInfo(forScreenID: ud.pointee.screenID)?.name ?? "(unknown)"
    let ptr = lua_topointer(L, 1)!
    let str = "\(USERDATA_TAG): \(theName) (0x\(String(UInt(bitPattern: ptr), radix: 16)))"
    L.push(str)
    return 1
}

// MARK: - Display reconfiguration callback (gamma reapply)

/// This callback runs on the CG notification thread. It accesses module-level
/// gamma dictionaries (originalGammas / currentGammas) and uses the global
/// environment to call into the protocol layer for gamma reapply.
private func displayReconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    if flags.contains(.addFlag) {
        if let scr = environmentGetGlobalOrNil()?.screen {
            storeInitialScreenGamma(display, using: scr)
        }
    } else if flags.contains(.removeFlag) {
        originalGammas.removeObject(forKey: NSNumber(value: display))
        currentGammas.removeObject(forKey: NSNumber(value: display))
    } else if flags.contains(.disabledFlag) {
        currentGammas.removeObject(forKey: NSNumber(value: display))
    } else if flags.contains(.enabledFlag) || flags.contains(.beginConfigurationFlag) {
        // NOOP
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if let scr = environmentGetGlobalOrNil()?.screen {
                screen_gammaReapply(display, using: scr)
            }
        }
    }
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libscreen")
public func luaopen_hs_libscreen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    precondition(L != nil, "luaopen_hs_libscreen: L must not be nil")
    return runEntryPoint(L) { L in
        // Initialize gamma structures, populate them, and register callbacks
        originalGammas = NSMutableDictionary()
        currentGammas = NSMutableDictionary()
        getAllInitialScreenGammas(using: environmentGet(L).screen)
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(screen_frame)
        lua_setfield(L, -2, "_frame")
        L.push(screen_visibleframe)
        lua_setfield(L, -2, "_visibleframe")
        L.push(screen_id)
        lua_setfield(L, -2, "id")
        L.push(screen_name)
        lua_setfield(L, -2, "name")
        L.push(screen_availableModes)
        lua_setfield(L, -2, "availableModes")
        L.push(screen_currentMode)
        lua_setfield(L, -2, "currentMode")
        L.push(screen_setMode)
        lua_setfield(L, -2, "setMode")
        L.push(screen_snapshot)
        lua_setfield(L, -2, "snapshot")
        L.push(screen_gammaGet)
        lua_setfield(L, -2, "getGamma")
        L.push(screen_gammaSet)
        lua_setfield(L, -2, "setGamma")
        L.push(screen_getBrightness)
        lua_setfield(L, -2, "getBrightness")
        L.push(screen_setBrightness)
        lua_setfield(L, -2, "setBrightness")
        L.push(screen_getUUID)
        lua_setfield(L, -2, "getUUID")
        L.push(screen_getDisplayInfo)
        lua_setfield(L, -2, "getInfo")
        L.push(screen_rotate)
        lua_setfield(L, -2, "rotate")
        L.push(screen_setPrimary)
        lua_setfield(L, -2, "setPrimary")
        L.push(screen_desktopImageURL)
        lua_setfield(L, -2, "desktopImageURL")
        L.push(screen_setOrigin)
        lua_setfield(L, -2, "setOrigin")
        L.push(screen_mirrorOf)
        lua_setfield(L, -2, "mirrorOf")
        L.push(screen_mirrorStop)
        lua_setfield(L, -2, "mirrorStop")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        L.push(screen_gc)
        lua_setfield(L, -2, "__gc")
        L.push(screen_eq)
        lua_setfield(L, -2, "__eq")

        // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 8)
        L.push(screen_allScreens)
        lua_setfield(L, -2, "allScreens")
        L.push(screen_mainScreen)
        lua_setfield(L, -2, "mainScreen")
        L.push(screen_gammaRestore)
        lua_setfield(L, -2, "restoreGamma")
        L.push(screen_accessibilitySettings)
        lua_setfield(L, -2, "accessibilitySettings")
        L.push(screen_getForceToGray)
        lua_setfield(L, -2, "getForceToGray")
        L.push(screen_setForceToGray)
        lua_setfield(L, -2, "setForceToGray")
        L.push(screen_getInvertedPolarity)
        lua_setfield(L, -2, "getInvertedPolarity")
        L.push(screen_setInvertedPolarity)
        lua_setfield(L, -2, "setInvertedPolarity")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(screens_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
