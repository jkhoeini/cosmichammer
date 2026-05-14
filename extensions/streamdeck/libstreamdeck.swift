//
//  libstreamdeck.swift
//  Hammerspoon
//
//  Created by Chris Jones on 06/09/2017.
//  Copyright © 2017 Hammerspoon. All rights reserved.
//

import Cocoa
import LuaSkin

// MARK: - Constants (mirroring streamdeck.h)

let USERDATA_TAG = "hs.streamdeck"

let USB_VID_ELGATO                  = 0x0fd9

let USB_PID_STREAMDECK_ORIGINAL     = 0x0060
let USB_PID_STREAMDECK_ORIGINAL_V2  = 0x006d
let USB_PID_STREAMDECK_MINI         = 0x0063
let USB_PID_STREAMDECK_MINI_V2      = 0x0090
let USB_PID_STREAMDECK_XL           = 0x006c
let USB_PID_STREAMDECK_XL_V2        = 0x008F
let USB_PID_STREAMDECK_MK2          = 0x0080
let USB_PID_STREAMDECK_PLUS         = 0x0084
let USB_PID_STREAMDECK_PEDAL        = 0x0086

// MARK: - Global variables

var streamDeckRefTable: LSRefTable = LUA_NOREF

private var deckManager: HSStreamDeckManager?

// MARK: - Helper

@inline(__always)
private func get_objectFromUserdata<T: AnyObject>(_ type: T.Type, _ L: OpaquePointer!, _ idx: Int32, _ tag: String) -> T {
    let ptr = luaL_checkudata(L, idx, tag)!
    return Unmanaged<T>.fromOpaque(ptr.load(as: UnsafeMutableRawPointer.self)).takeUnretainedValue()
}

// MARK: - Lua API

/// hs.streamdeck:__gc
private func streamdeck_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    if let manager = deckManager {
        var tmpLSUUID = manager.lsCanary
        skin.destroyGCCanary(&tmpLSUUID)
        manager.lsCanary = tmpLSUUID

        manager.stopHIDManager()
        manager.doGC()
    }
    return 0
}

/// hs.streamdeck.init(fn)
/// Function
/// Initialises the Stream Deck driver and sets a discovery callback
///
/// Parameters:
///  * fn - A function that will be called when a Stream Deck is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.streamdeck object, being the device that was connected/disconnected
///
/// Returns:
///  * None
///
/// Notes:
///  * This function must be called before any other parts of this module are used
private func streamdeck_init(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    deckManager = HSStreamDeckManager()
    deckManager!.discoveryCallbackRef = skin.luaRef(streamDeckRefTable, atIndex: 1)
    deckManager!.lsCanary = skin.createGCCanary()
    deckManager!.startHIDManager()

    return 0
}

/// hs.streamdeck.discoveryCallback(fn)
/// Function
/// Sets/clears a callback for reacting to device discovery events
///
/// Parameters:
///  * fn - A function that will be called when a Stream Deck is connected or disconnected. It should take the following arguments:
///   * A boolean, true if a device was connected, false if a device was disconnected
///   * An hs.streamdeck object, being the device that was connected/disconnected
///
/// Returns:
///  * None
private func streamdeck_discoveryCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TFUNCTION, LS_TBREAK)

    if let manager = deckManager {
        manager.discoveryCallbackRef = skin.luaUnref(streamDeckRefTable, ref: manager.discoveryCallbackRef)

        if lua_type(skin.L, 1) == LUA_TFUNCTION {
            manager.discoveryCallbackRef = skin.luaRef(streamDeckRefTable, atIndex: 1)
        }
    }

    return 0
}

/// hs.streamdeck.numDevices()
/// Function
/// Gets the number of Stream Deck devices connected
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of Stream Deck devices attached to the system
private func streamdeck_numDevices(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TBREAK)

    lua_pushinteger(skin.L, lua_Integer(deckManager?.devices.count ?? 0))
    return 1
}

/// hs.streamdeck.getDevice(num)
/// Function
/// Gets an hs.streamdeck object for the specified device
///
/// Parameters:
///  * num - A number that should be within the bounds of the number of connected devices
///
/// Returns:
///  * An hs.streamdeck object
private func streamdeck_getDevice(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TNUMBER, LS_TBREAK)

    let index = Int(lua_tointeger(skin.L, 1)) - 1
    if let manager = deckManager, index >= 0, index < manager.devices.count {
        skin.pushNSObject(manager.devices[index] as AnyObject)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.streamdeck:buttonCallback(fn)
/// Method
/// Sets/clears the button callback function for a Stream Deck device
///
/// Parameters:
///  * fn - A function to be called when a button is pressed/released on the stream deck. It should receive three arguments:
///   * The hs.streamdeck userdata object
///   * A number containing the button that was pressed/released
///   * A boolean indicating whether the button was pressed (true) or released (false)
///
/// Returns:
///  * The hs.streamdeck device
private func streamdeck_buttonCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, UInt32(LS_TFUNCTION | LS_TNIL), LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    device.buttonCallbackRef = skin.luaUnref(streamDeckRefTable, ref: device.buttonCallbackRef)

    if lua_type(skin.L, 2) == LUA_TFUNCTION {
        device.buttonCallbackRef = skin.luaRef(streamDeckRefTable, atIndex: 2)
    }

    lua_pushvalue(skin.L, 1)
    return 1
}

/// hs.streamdeck:encoderCallback(fn)
/// Method
/// Sets/clears the knob/encoder callback function for a Stream Deck Plus.
///
/// Parameters:
///  * fn - A function to be called when an encoder button is pressed/released/rotated on a Stream Deck Plus. It should receive five arguments:
///   * The hs.streamdeck userdata object
///   * A number containing the button that was pressed/released/rotated
///   * A boolean indicating whether the button was pressed (true) or released (false)
///   * A boolean indicating that the button was turned left
///   * A boolean indicating that the button was turned right
///
/// Returns:
///  * The hs.streamdeck device
private func streamdeck_encoderCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, UInt32(LS_TFUNCTION | LS_TNIL), LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    device.encoderCallbackRef = skin.luaUnref(streamDeckRefTable, ref: device.encoderCallbackRef)

    if lua_type(skin.L, 2) == LUA_TFUNCTION {
        device.encoderCallbackRef = skin.luaRef(streamDeckRefTable, atIndex: 2)
    }

    lua_pushvalue(skin.L, 1)
    return 1
}

/// hs.streamdeck:screenCallback(fn)
/// Method
/// Sets/clears the screen callback function for a Stream Deck Plus's touch screen (above the encoder knobs).
///
/// Parameters:
///  * fn - A function to be called when a screen is pressed/released/swiped on a Stream Deck Plus. It should receive six arguments:
///   * The hs.streamdeck userdata object
///   * A string either containing "shortPress", "longPress" or "swipe"
///   * The X position of where the screen was first touched
///   * The Y position of where the screen was first touched
///   * The X position of where the screen was last touched (if swiping)
///   * The Y position of where the screen was last touched (if swiping)
///
/// Returns:
///  * The hs.streamdeck device
private func streamdeck_screenCallback(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, UInt32(LS_TFUNCTION | LS_TNIL), LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    device.screenCallbackRef = skin.luaUnref(streamDeckRefTable, ref: device.screenCallbackRef)

    if lua_type(skin.L, 2) == LUA_TFUNCTION {
        device.screenCallbackRef = skin.luaRef(streamDeckRefTable, atIndex: 2)
    }

    lua_pushvalue(skin.L, 1)
    return 1
}

/// hs.streamdeck:setBrightness(brightness)
/// Method
/// Sets the brightness of a Stream Deck device
///
/// Parameters:
///  * brightness - A whole number between 0 and 100 indicating the percentage brightness level to set
///
/// Returns:
///  * The hs.streamdeck device
private func streamdeck_setBrightness(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    device.setBrightness(Int32(lua_tointeger(skin.L, 2)))

    lua_pushvalue(skin.L, 1)
    return 1
}

/// hs.streamdeck:reset()
/// Method
/// Resets a Stream Deck device
///
/// Parameters:
///  * None
///
/// Returns:
///  * The hs.streamdeck object
private func streamdeck_reset(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    device.reset()

    lua_pushvalue(skin.L, 1)
    return 1
}

/// hs.streamdeck:serialNumber()
/// Method
/// Gets the serial number of a Stream Deck device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the serial number of the deck
private func streamdeck_serialNumber(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    skin.pushNSObject(device.serialNumber as NSString?)
    return 1
}

/// hs.streamdeck:firmwareVersion()
/// Method
/// Gets the firmware version of a Stream Deck device
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the firmware version of the deck
private func streamdeck_firmwareVersion(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    skin.pushNSObject(device.firmwareVersion() as NSString?)
    return 1
}

/// hs.streamdeck:buttonLayout()
/// Method
/// Gets the layout of buttons a Stream Deck device has
///
/// Parameters:
///  * None
///
/// Returns:
///  * The number of columns
///  * The number of rows
private func streamdeck_buttonLayout(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    lua_pushinteger(skin.L, lua_Integer(device.keyColumns))
    lua_pushinteger(skin.L, lua_Integer(device.keyRows))
    return 2
}

/// hs.streamdeck:imageSize()
/// Method
/// Gets the width and height of the buttons in pixels
///
/// Parameters:
///  * None
///
/// Returns:
///  * An table with keys `w` and `h` containing the width and height, respectively, of images expected by the Stream Deck
private func streamdeck_imageSize(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    let size = NSSize(width: CGFloat(device.imageWidth), height: CGFloat(device.imageHeight))
    skin.pushNSSize(size)
    return 1
}

/// hs.streamdeck:setButtonImage(button, image)
/// Method
/// Sets the image of a button on the Stream Deck device
///
/// Parameters:
///  * button - A number (from 1 to 15) describing which button to set the image for
///  * image - An hs.image object
///
/// Returns:
///  * The hs.streamdeck object
private func streamdeck_setButtonImage(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TUSERDATA, "hs.image", LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    let image: NSImage = skin.luaObjectAtIndex(3, toClass: "NSImage") as! NSImage
    device.setImage(image, forButton: Int32(lua_tointeger(skin.L, 2)))

    lua_pushvalue(skin.L, 1)
    return 1
}

/// hs.streamdeck:setScreenImage(encoder, image)
/// Method
/// Sets the image of the screen on the Stream Deck device
///
/// Parameters:
///  * encoder - A number (from 1 to 4) describing which encoder to set the image for
///  * image - An hs.image object
///
/// Returns:
///  * The hs.streamdeck object
private func streamdeck_setScreenImage(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TUSERDATA, "hs.image", LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    let image: NSImage = skin.luaObjectAtIndex(3, toClass: "NSImage") as! NSImage
    device.setLCDImage(image, forEncoder: Int32(lua_tointeger(skin.L, 2)))

    lua_pushvalue(skin.L, 1)
    return 1
}

/// hs.streamdeck:setButtonColor(button, color)
/// Method
/// Sets a button on the Stream Deck device to the specified color
///
/// Parameters:
///  * button - A number (from 1 to 15) describing which button to set the color on
///  * color - An hs.drawing.color object
///
/// Returns:
///  * The hs.streamdeck object
private func streamdeck_setButtonColor(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER, LS_TTABLE, LS_TBREAK)

    let device: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    let color: NSColor = skin.luaObjectAtIndex(3, toClass: "NSColor") as! NSColor
    device.setColor(color, forButton: Int32(lua_tointeger(skin.L, 2)))

    lua_pushvalue(skin.L, 1)
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushHSStreamDeckDevice(_ L: OpaquePointer!, obj: AnyObject!) -> Int32 {
    guard let value = obj as? HSStreamDeckDevice else { return 0 }
    value.selfRefCount += 1
    let ptr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
    ptr.storeBytes(of: Unmanaged.passRetained(value).toOpaque(), as: UnsafeMutableRawPointer.self)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

private func toHSStreamDeckDeviceFromLua(_ L: OpaquePointer!, idx: Int32) -> AnyObject! {
    let skin = LuaSkin.shared(withState: L)!
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        return get_objectFromUserdata(HSStreamDeckDevice.self, L, idx, USERDATA_TAG)
    } else {
        skin.logError(String(format: "expected %@ object, found %@", USERDATA_TAG,
                             String(cString: lua_typename(L, lua_type(L, idx)))))
    }
    return nil
}

// MARK: - Hammerspoon/Lua Infrastructure

private func streamdeck_object_tostring(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let obj: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
    let title = "\(obj.deckType), serial: \(obj.serialNumber ?? "unknown")"
    skin.pushNSObject(String(format: "%@: %@ (%p)", USERDATA_TAG, title, lua_topointer(L, 1)!) as NSString)
    return 1
}

private func streamdeck_object_eq(_ L: OpaquePointer!) -> Int32 {
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.shared(withState: L)!
        let obj1: HSStreamDeckDevice = skin.luaObjectAtIndex(1, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
        let obj2: HSStreamDeckDevice = skin.luaObjectAtIndex(2, toClass: "HSStreamDeckDevice") as! HSStreamDeckDevice
        lua_pushboolean(L, obj1.isEqual(to: obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private func streamdeck_object_gc(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
    let theDevice = Unmanaged<HSStreamDeckDevice>.fromOpaque(
        ptr.load(as: UnsafeMutableRawPointer.self)
    ).takeRetainedValue()

    theDevice.selfRefCount -= 1
    if theDevice.selfRefCount == 0 {
        theDevice.buttonCallbackRef = skin.luaUnref(streamDeckRefTable, ref: theDevice.buttonCallbackRef)
        theDevice.encoderCallbackRef = skin.luaUnref(streamDeckRefTable, ref: theDevice.encoderCallbackRef)
        theDevice.screenCallbackRef = skin.luaUnref(streamDeckRefTable, ref: theDevice.screenCallbackRef)
    }

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// MARK: - Lua object function definitions

private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("serialNumber"),    func: streamdeck_serialNumber),
    luaL_Reg(name: strdup("firmwareVersion"), func: streamdeck_firmwareVersion),
    luaL_Reg(name: strdup("buttonLayout"),    func: streamdeck_buttonLayout),
    luaL_Reg(name: strdup("imageSize"),       func: streamdeck_imageSize),

    luaL_Reg(name: strdup("buttonCallback"),  func: streamdeck_buttonCallback),
    luaL_Reg(name: strdup("encoderCallback"), func: streamdeck_encoderCallback),
    luaL_Reg(name: strdup("screenCallback"),  func: streamdeck_screenCallback),

    luaL_Reg(name: strdup("setButtonImage"),  func: streamdeck_setButtonImage),
    luaL_Reg(name: strdup("setScreenImage"),  func: streamdeck_setScreenImage),
    luaL_Reg(name: strdup("setButtonColor"),  func: streamdeck_setButtonColor),
    luaL_Reg(name: strdup("setBrightness"),   func: streamdeck_setBrightness),
    luaL_Reg(name: strdup("reset"),           func: streamdeck_reset),

    luaL_Reg(name: strdup("__tostring"),      func: streamdeck_object_tostring),
    luaL_Reg(name: strdup("__eq"),            func: streamdeck_object_eq),
    luaL_Reg(name: strdup("__gc"),            func: streamdeck_object_gc),

    luaL_Reg(name: nil, func: nil),
]

// MARK: - Lua Library function definitions

private var streamdecklib: [luaL_Reg] = [
    luaL_Reg(name: strdup("init"),              func: streamdeck_init),
    luaL_Reg(name: strdup("discoveryCallback"), func: streamdeck_discoveryCallback),
    luaL_Reg(name: strdup("numDevices"),        func: streamdeck_numDevices),
    luaL_Reg(name: strdup("getDevice"),         func: streamdeck_getDevice),

    luaL_Reg(name: nil, func: nil),
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: streamdeck_gc),

    luaL_Reg(name: nil, func: nil),
]

// MARK: - Lua initialiser

@_cdecl("luaopen_hs_libstreamdeck")
func luaopen_hs_libstreamdeck(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)!
    streamDeckRefTable = skin.registerLibrary(USERDATA_TAG, functions: &streamdecklib, metaFunctions: &metalib)
    skin.registerObject(USERDATA_TAG, objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushHSStreamDeckDevice, forClass: "HSStreamDeckDevice")
    skin.registerLuaObjectHelper(toHSStreamDeckDeviceFromLua, forClass: "HSStreamDeckDevice", withTableMapping: USERDATA_TAG)

    return 1
}
