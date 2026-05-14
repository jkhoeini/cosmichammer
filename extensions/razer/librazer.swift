import Cocoa
import LuaSkin

// MARK: - Global variables

private let USERDATA_TAG = "hs.razer"
var razerRefTable: LSRefTable = LUA_NOREF

private var razerManager: HSRazerManager?

// MARK: - Helper

/// Extracts a typed object from Lua userdata at the given stack index.
private func getObjectFromUserdata<T: AnyObject>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: String) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!
    return Unmanaged<T>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeRawPointer.self).pointee).takeUnretainedValue()
}

// MARK: - Lua API: Module-level functions

/// hs.razer.init(fn)
/// Function
/// Initialises the Razer driver and sets a discovery callback.
///
/// Parameters:
///  * fn - A function that will be called when a Razer device is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.razer object, being the device that was connected/disconnected
///
/// Returns:
///  * None
///
/// Notes:
///  * This function must be called before any other parts of this module are used
private let razer_init: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    razerManager = HSRazerManager()
    razerManager!.discoveryCallbackRef = skin.luaRef(razerRefTable, atIndex: 1)
    razerManager!.startHIDManager()

    return 0
}

/// hs.razer.discoveryCallback(fn) -> none
/// Function
/// Sets/clears a callback for reacting to device discovery events
///
/// Parameters:
///  * fn - A function that will be called when a Razer device is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.razer object, being the device that was connected/disconnected
///
/// Returns:
///  * None
private let razer_discoveryCallback: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TFUNCTION | LS_TNIL, LS_TBREAK)

    if razerManager == nil {
        razerManager = HSRazerManager()
    }
    razerManager!.discoveryCallbackRef = skin.luaUnref(razerRefTable, ref: razerManager!.discoveryCallbackRef)

    if lua_type(skin.L, 1) == LUA_TFUNCTION {
        razerManager!.discoveryCallbackRef = skin.luaRef(razerRefTable, atIndex: 1)
    }

    return 0
}

/// hs.razer.numDevices() -> number
/// Function
/// Gets the number of Razer devices connected
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of Razer devices attached to the system
private let razer_numDevices: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)

    lua_pushinteger(skin.L, lua_Integer(razerManager?.devices.count ?? 0))
    return 1
}

/// hs.razer.getDevice(num) -> razerObject | nil
/// Function
/// Gets an hs.razer object for the specified device
///
/// Parameters:
///  * num - A number that should be within the bounds of the number of connected devices
///
/// Returns:
///  * An hs.razer object or `nil` if something goes wrong
private let razer_getDevice: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TNUMBER, LS_TBREAK)

    let deviceNumber = Int(lua_tointeger(skin.L, 1)) - 1

    guard let manager = razerManager, deviceNumber >= 0, deviceNumber < manager.devices.count else {
        lua_pushnil(L)
        return 1
    }

    if let razer = manager.devices[deviceNumber] as? HSRazerDevice {
        skin.pushNSObject(razer)
    } else {
        lua_pushnil(L)
    }

    return 1
}

// MARK: - Lua API: Instance methods

/// hs.razer:name() -> string
/// Method
/// Returns the human readable device name of the Razer device.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The device name as a string.
private let razer_name: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    skin.pushNSObject(razer.name as NSString)
    return 1
}

/// hs.razer:callback(callbackFn) -> razerObject
/// Method
/// Sets or removes a callback function for the `hs.razer` object.
///
/// Parameters:
///  * `callbackFn` - a function to set as the callback for this `hs.razer` object.  If the value provided is `nil`, any currently existing callback function is removed.
///
/// Returns:
///  * The `hs.razer` object
///
/// Notes:
///  * The callback function should expect 4 arguments and should not return anything:
///    * `razerObject` - The serial port object that triggered the callback.
///    * `buttonName` - The name of the button as a string.
///    * `buttonAction` - A string containing "pressed", "released", "up" or "down".
private let razer_callback: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)

    let device = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    device.buttonCallbackRef = skin.luaUnref(razerRefTable, ref: device.buttonCallbackRef)

    if lua_type(skin.L, 2) == LUA_TFUNCTION {
        device.buttonCallbackRef = skin.luaRef(razerRefTable, atIndex: 2)
    }

    lua_pushvalue(skin.L, 1)
    return 1
}

// hs.razer:_remapping() -> table
// Method
// Returns a table of the remapping data.
//
// Parameters:
//  * None
//
// Returns:
//  * A table of remapping data used by the `:keyboardDisableDefaults()` and `:keyboardEnableDefaults()` methods.
private let razer_remapping: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    skin.pushNSObject(razer.remapping)
    return 1
}

// hs.razer:_productID() -> number
// Method
// Returns the product ID of a `hs.razer` object.
//
// Parameters:
//  * None
//
// Returns:
//  * The product ID as a number.
private let razer_productID: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    skin.pushNSObject(NSNumber(value: razer.productID))
    return 1
}

// MARK: - Brightness

/// hs.razer:brightness(value) -> razerObject, number | nil, string | nil
/// Method
/// Gets or sets the brightness of a Razer keyboard.
///
/// Parameters:
///  * value - The brightness value - a number between 0 (off) and 100 (brightest).
///
/// Returns:
///  * The `hs.razer` object.
///  * The brightness as a number or `nil` if something goes wrong.
///  * A plain text error message if not successful.
private let razer_brightness: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice

    if lua_gettop(L) == 1 {
        // Getter:
        let result = razer.getBrightness()
        if result.success {
            lua_pushvalue(L, 1)
            skin.pushNSObject(result.brightness)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    } else {
        // Setter:
        let brightness = skin.toNSObject(atIndex: 2) as! NSNumber

        if brightness.intValue < 0 || brightness.intValue > 100 {
            lua_pushvalue(L, 1)
            lua_pushboolean(L, 0)
            skin.pushNSObject("The brightness must be between 0 and 100." as NSString)
            return 3
        }

        let result = razer.setBrightness(brightness)
        if result.success {
            lua_pushvalue(L, 1)
            skin.pushNSObject(result.brightness)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    }
    return 3
}

// MARK: - Status Lights

/// hs.razer:orangeStatusLight(value) -> razerObject, boolean | nil, string | nil
/// Method
/// Gets or sets the orange status light.
///
/// Parameters:
///  * value - `true` for on, `false` for off`
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` for on, `false` for off`, or `nil` if something has gone wrong
///  * A plain text error message if not successful.
private let razer_orangeStatusLight: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice

    if lua_gettop(L) == 1 {
        let result = razer.getOrangeStatusLight()
        if result.success {
            lua_pushvalue(L, 1)
            lua_pushboolean(L, result.orangeStatusLight ? 1 : 0)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    } else {
        let active = lua_toboolean(L, 2) != 0
        let result = razer.setOrangeStatusLight(active)
        if result.success {
            lua_pushvalue(L, 1)
            lua_pushboolean(L, active ? 1 : 0)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    }
    return 3
}

/// hs.razer:greenStatusLight(value) -> razerObject, boolean | nil, string | nil
/// Method
/// Gets or sets the green status light.
///
/// Parameters:
///  * value - `true` for on, `false` for off`
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` for on, `false` for off`, or `nil` if something has gone wrong
///  * A plain text error message if not successful.
private let razer_greenStatusLight: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice

    if lua_gettop(L) == 1 {
        let result = razer.getGreenStatusLight()
        if result.success {
            lua_pushvalue(L, 1)
            lua_pushboolean(L, result.greenStatusLight ? 1 : 0)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    } else {
        let active = lua_toboolean(L, 2) != 0
        let result = razer.setGreenStatusLight(active)
        if result.success {
            lua_pushvalue(L, 1)
            lua_pushboolean(L, active ? 1 : 0)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    }
    return 3
}

/// hs.razer:blueStatusLight(value) -> razerObject, boolean | nil, string | nil
/// Method
/// Gets or sets the blue status light.
///
/// Parameters:
///  * value - `true` for on, `false` for off`
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` for on, `false` for off`, or `nil` if something has gone wrong
///  * A plain text error message if not successful.
private let razer_blueStatusLight: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice

    if lua_gettop(L) == 1 {
        let result = razer.getBlueStatusLight()
        if result.success {
            lua_pushvalue(L, 1)
            lua_pushboolean(L, result.blueStatusLight ? 1 : 0)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    } else {
        let active = lua_toboolean(L, 2) != 0
        let result = razer.setBlueStatusLight(active)
        if result.success {
            lua_pushvalue(L, 1)
            lua_pushboolean(L, active ? 1 : 0)
            lua_pushnil(L)
        } else {
            lua_pushvalue(L, 1)
            lua_pushnil(L)
            skin.pushNSObject(result.errorMessage)
        }
    }
    return 3
}

// MARK: - Backlights

/// hs.razer:backlightsStatic(color) -> razerObject, boolean, string | nil
/// Method
/// Changes the keyboard backlights to a single static color.
///
/// Parameters:
///  * color - A `hs.drawing.color` object.
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`.
///  * A plain text error message if not successful.
private let razer_backlightsStatic: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    let color = skin.luaObjectAtIndex(2, toClass: "NSColor") as! NSColor

    let result = razer.setBacklightToStaticColor(color)

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

/// hs.razer:backlightsOff() -> razerObject, boolean, string | nil
/// Method
/// Turns all the keyboard backlights off.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`.
///  * A plain text error message if not successful.
private let razer_backlightsOff: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    let result = razer.setBacklightToOff()

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

/// hs.razer:backlightsWave(speed, direction) -> razerObject, boolean, string | nil
/// Method
/// Changes the keyboard backlights to the wave mode.
///
/// Parameters:
///  * speed - A number between 1 (fast) and 255 (slow)
///  * direction - "left" or "right" as a string
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`
///  * A plain text error message if not successful.
private let razer_backlightsWave: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TSTRING, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    let speed = skin.toNSObject(atIndex: 2) as! NSNumber
    let direction = skin.toNSObject(atIndex: 3) as! NSString

    if speed.intValue < 1 || speed.intValue > 255 {
        lua_pushvalue(L, 1)
        lua_pushboolean(L, 0)
        skin.pushNSObject("The speed must be between 1 and 255." as NSString)
        return 3
    }

    if direction != "left" && direction != "right" {
        lua_pushvalue(L, 1)
        lua_pushboolean(L, 0)
        skin.pushNSObject("The direction must be 'left' or 'right'." as NSString)
        return 3
    }

    let result = razer.setBacklightToWave(speed: speed, direction: direction as String)

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

/// hs.razer:backlightsSpectrum() -> razerObject, boolean, string | nil
/// Method
/// Changes the keyboard backlights to the spectrum mode.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`
///  * A plain text error message if not successful.
private let razer_backlightsSpectrum: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    let result = razer.setBacklightToSpectrum()

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

/// hs.razer:backlightsReactive(speed, color) -> razerObject, boolean, string | nil
/// Method
/// Changes the keyboard backlights to the reactive mode.
///
/// Parameters:
///  * speed - A number between 1 (fast) and 4 (slow)
///  * color - A `hs.drawing.color` object
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`
///  * A plain text error message if not successful.
private let razer_backlightsReactive: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TTABLE, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    let speed = skin.toNSObject(atIndex: 2) as! NSNumber
    let color = skin.luaObjectAtIndex(3, toClass: "NSColor") as! NSColor

    if speed.intValue < 1 || speed.intValue > 4 {
        lua_pushvalue(L, 1)
        lua_pushboolean(L, 0)
        skin.pushNSObject("The speed must be between 1 and 4." as NSString)
        return 3
    }

    let result = razer.setBacklightToReactive(color: color, speed: speed)

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

/// hs.razer:backlightsStarlight(speed, [color], [secondaryColor]) -> razerObject, boolean, string | nil
/// Method
/// Changes the keyboard backlights to the Starlight mode.
///
/// Parameters:
///  * speed - A number between 1 (fast) and 3 (slow)
///  * [color] - An optional `hs.drawing.color` value
///  * [secondaryColor] - An optional secondary `hs.drawing.color`
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`
///  * A plain text error message if not successful.
///
/// Notes:
///  * If neither `color` nor `secondaryColor` is provided, then random colors will be used.
private let razer_backlightsStarlight: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TTABLE | LS_TOPTIONAL | LS_TNIL, LS_TTABLE | LS_TOPTIONAL | LS_TNIL, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    let speed = skin.toNSObject(atIndex: 2) as! NSNumber

    if speed.intValue < 1 || speed.intValue > 3 {
        lua_pushvalue(L, 1)
        lua_pushboolean(L, 0)
        skin.pushNSObject("The speed must be between 1 and 3." as NSString)
        return 3
    }

    var color: NSColor? = nil
    var secondaryColor: NSColor? = nil

    if lua_type(L, 3) == LUA_TTABLE {
        color = skin.luaObjectAtIndex(3, toClass: "NSColor") as? NSColor
    }

    if lua_type(L, 4) == LUA_TTABLE {
        secondaryColor = skin.luaObjectAtIndex(4, toClass: "NSColor") as? NSColor
    }

    let result = razer.setBacklightToStarlight(color: color, secondaryColor: secondaryColor, speed: speed)

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

/// hs.razer:backlightsBreathing([color], [secondaryColor]) -> razerObject, boolean, string | nil
/// Method
/// Changes the keyboard backlights to the breath mode.
///
/// Parameters:
///  * [color] - An optional `hs.drawing.color` value
///  * [secondaryColor] - An optional secondary `hs.drawing.color`
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`
///  * A plain text error message if not successful.
///
/// Notes:
///  * If neither `color` nor `secondaryColor` is provided, then random colors will be used.
private let razer_backlightsBreathing: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE | LS_TOPTIONAL | LS_TNIL, LS_TTABLE | LS_TOPTIONAL | LS_TNIL, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice

    var color: NSColor? = nil
    var secondaryColor: NSColor? = nil

    if lua_type(L, 2) == LUA_TTABLE {
        color = skin.luaObjectAtIndex(2, toClass: "NSColor") as? NSColor
    }

    if lua_type(L, 3) == LUA_TTABLE {
        secondaryColor = skin.luaObjectAtIndex(3, toClass: "NSColor") as? NSColor
    }

    let result = razer.setBacklightToBreathing(color: color, secondaryColor: secondaryColor)

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

/// hs.razer:backlightsCustom(colors) -> razerObject, boolean, string | nil
/// Method
/// Changes the keyboard backlights to custom colours.
///
/// Parameters:
///  * colors - A table of `hs.drawing.color` objects for each individual button on your device (i.e. if there's 20 buttons, you should have twenty colors in the table).
///
/// Returns:
///  * The `hs.razer` object.
///  * `true` if successful otherwise `false`
///  * A plain text error message if not successful.
///
/// Notes:
///  * The order is top to bottom, left to right. You can use `nil` for any buttons you don't want to light up.
///  * Example usage: ```lua
///   hs.razer.new(0):backlightsCustom({hs.drawing.color.red, nil, hs.drawing.color.green, hs.drawing.color.blue})
///   ```
private let razer_backlightsCustom: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)

    let razer = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice

    let customColors = NSMutableDictionary()

    lua_pushnil(L) // first key
    while lua_next(L, 2) != 0 {
        let key = NSNumber(value: lua_tonumber(L, -2))
        let color = skin.luaObjectAtIndex(-1, toClass: "NSColor") as? NSColor
        if let color = color {
            customColors[key] = color
        }
        lua_pop(L, 1) // pop value but leave key on stack for lua_next
    }

    let result = razer.setBacklightToCustom(colors: customColors)

    lua_pushvalue(L, 1)
    lua_pushboolean(L, result.success ? 1 : 0)
    skin.pushNSObject(result.errorMessage)
    return 3
}

// MARK: - Lua<->NSObject Conversion Functions
// These must not throw a lua error to ensure LuaSkin can safely be used from Objective-C
// delegates and blocks.

private let pushHSRazerDevice: @convention(block) (OpaquePointer?, AnyObject) -> Int32 = { Lptr, obj in
    guard let L = Lptr else { return 0 }
    let device = obj as! HSRazerDevice
    device.selfRefCount += 1

    let ptr = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    let opaquePtr = Unmanaged.passRetained(device).toOpaque()
    ptr.storeBytes(of: opaquePtr, as: UnsafeRawPointer.self)

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private let toHSRazerDeviceFromLua: @convention(block) (OpaquePointer?, Int32) -> AnyObject? = { Lptr, idx in
    guard let L = Lptr else { return nil }
    let skin = LuaSkin.shared(withState: L)

    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        let opaquePtr = ptr.load(as: UnsafeRawPointer.self)
        return Unmanaged<HSRazerDevice>.fromOpaque(opaquePtr).takeUnretainedValue()
    } else {
        skin.logError(String(format: "expected %@ object, found %@",
                             USERDATA_TAG,
                             String(cString: lua_typename(L, lua_type(L, idx)))))
        return nil
    }
}

// MARK: - Hammerspoon/Lua Infrastructure

private let razer_object_tostring: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)
    let obj = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
    let title = obj.name
    skin.pushNSObject(String(format: "%@: %@ (%p)", USERDATA_TAG, title, lua_topointer(L, 1)!) as NSString)
    return 1
}

private let razer_object_eq: lua_CFunction = { L in
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)
        let obj1 = skin.luaObjectAtIndex(1, toClass: "HSRazerDevice") as! HSRazerDevice
        let obj2 = skin.luaObjectAtIndex(2, toClass: "HSRazerDevice") as! HSRazerDevice
        lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private let razer_object_gc: lua_CFunction = { L in
    let skin = LuaSkin.shared(withState: L)

    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let opaquePtr = ptr.load(as: UnsafeRawPointer.self)
    let theDevice = Unmanaged<HSRazerDevice>.fromOpaque(opaquePtr).takeRetainedValue()

    theDevice.selfRefCount -= 1
    if theDevice.selfRefCount == 0 {
        theDevice.destroyEventTap()
        theDevice.buttonCallbackRef = skin.luaUnref(razerRefTable, ref: theDevice.buttonCallbackRef)
    }

    // Remove the Metatable so future use of the variable in Lua won't think it's valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

private let razer_gc: lua_CFunction = { L in
    razerManager?.stopHIDManager()
    razerManager?.doGC()
    return 0
}

// MARK: - Lua Function Registration Tables

private var userdata_metaLib: [luaL_Reg] = [
    // Common:
    luaL_Reg(name: strdup("name"), func: razer_name),

    // Callback:
    luaL_Reg(name: strdup("callback"), func: razer_callback),

    // Brightness:
    luaL_Reg(name: strdup("brightness"), func: razer_brightness),

    // Backlights:
    luaL_Reg(name: strdup("backlightsOff"), func: razer_backlightsOff),
    luaL_Reg(name: strdup("backlightsCustom"), func: razer_backlightsCustom),
    luaL_Reg(name: strdup("backlightsWave"), func: razer_backlightsWave),
    luaL_Reg(name: strdup("backlightsSpectrum"), func: razer_backlightsSpectrum),
    luaL_Reg(name: strdup("backlightsReactive"), func: razer_backlightsReactive),
    luaL_Reg(name: strdup("backlightsStatic"), func: razer_backlightsStatic),
    luaL_Reg(name: strdup("backlightsStarlight"), func: razer_backlightsStarlight),
    luaL_Reg(name: strdup("backlightsBreathing"), func: razer_backlightsBreathing),

    // Status Lights:
    luaL_Reg(name: strdup("orangeStatusLight"), func: razer_orangeStatusLight),
    luaL_Reg(name: strdup("greenStatusLight"), func: razer_greenStatusLight),
    luaL_Reg(name: strdup("blueStatusLight"), func: razer_blueStatusLight),

    // Private Functions:
    luaL_Reg(name: strdup("_remapping"), func: razer_remapping),
    luaL_Reg(name: strdup("_productID"), func: razer_productID),

    // Helpers:
    luaL_Reg(name: strdup("__tostring"), func: razer_object_tostring),
    luaL_Reg(name: strdup("__eq"), func: razer_object_eq),
    luaL_Reg(name: strdup("__gc"), func: razer_object_gc),

    luaL_Reg(name: nil, func: nil), // Sentinel
]

private var razerlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("init"), func: razer_init),
    luaL_Reg(name: strdup("discoveryCallback"), func: razer_discoveryCallback),
    luaL_Reg(name: strdup("numDevices"), func: razer_numDevices),
    luaL_Reg(name: strdup("getDevice"), func: razer_getDevice),

    luaL_Reg(name: nil, func: nil), // Sentinel
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: razer_gc),

    luaL_Reg(name: nil, func: nil), // Sentinel
]

// MARK: - Lua Initialiser

@_cdecl("luaopen_hs_librazer")
public func luaopen_hs_librazer(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    razerRefTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                          functions: &razerlib,
                                          metaFunctions: &metalib,
                                          objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushHSRazerDevice, forClass: "HSRazerDevice")
    skin.registerLuaObjectHelper(toHSRazerDeviceFromLua, forClass: "HSRazerDevice", withTableMapping: USERDATA_TAG)

    return 1
}
