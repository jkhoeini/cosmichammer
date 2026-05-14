import Cocoa
import Carbon
import IOKit.graphics
import LuaSkin

// MARK: - Private framework declarations

@_silgen_name("DisplayServicesGetBrightness")
func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32

@_silgen_name("DisplayServicesSetBrightness")
func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32

// MARK: - Helpers

private func LMUtoLux(_ value: UInt64) -> UInt64 {
    // Conversion formula from regression.
    // -3*(10^-27)*x^4 + 2.6*(10^-19)*x^3 + -3.4*(10^-12)*x^2 + 3.9*(10^-5)*x - 0.19
    let x = Double(value)
    let lux = (-3 * pow(10, -27)) * pow(x, 4)
            + (2.6 * pow(10, -19)) * pow(x, 3)
            - (3.4 * pow(10, -12)) * pow(x, 2)
            + (3.9 * pow(10, -5)) * x
            - 0.19
    return UInt64(max(lux, 0))
}

// MARK: - Lua callbacks

/// hs.brightness.ambient() -> number
/// Function
/// Gets the current ambient brightness
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the current ambient brightness, measured in lux. If an error occurred, the number will be -1
///
/// Notes:
///  * Even though external Apple displays include an ambient light sensor, their data is typically not available, so this function will likely only be useful to MacBook users
///
///  * On Silicon based macs, this function uses a method similar to that used by `corebrightnessdiag` to retrieve the aggregate lux as reported to `sysdiagnose`.
///  * On Intel based macs, the raw sensor data is converted to lux via an algorithm used by Mozilla Firefox and is not guaranteed to give an accurate lux value.
private func brightness_ambient(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)

    let serviceObject = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleLMUController"))

    if serviceObject == IO_OBJECT_NULL {
        // M1 macs don't have such an IOService, so we have to use an undocumented class...
        if let dscClass = NSClassFromString("DisplayServicesClient") as? NSObject.Type {
            let ourDSC = dscClass.init()
            let key: NSString = "AggregatedLux"
            // copyPropertyForKey: has same signature as NSDictionary's objectForKey:
            let signature = NSDictionary.instanceMethodSignature(for: #selector(NSDictionary.object(forKey:)))!
            let invocation = NSInvocation(methodSignature: signature)
            invocation.target = ourDSC
            invocation.selector = NSSelectorFromString("copyPropertyForKey:")
            var keyArg: NSString? = key
            withUnsafeMutablePointer(to: &keyArg) { ptr in
                invocation.setArgument(ptr, at: 2)
            }
            invocation.invoke()
            var tempResultValuePtr: Unmanaged<AnyObject>?
            invocation.getReturnValue(&tempResultValuePtr)
            if let aggregatedLux = tempResultValuePtr?.takeUnretainedValue() as? NSNumber {
                skin.pushNSObject(aggregatedLux)
                return 1
            }
        }
        // Fall through to push -1
        lua_pushinteger(L, -1)
        return 1
    }

    var dataPort: io_connect_t = 0
    var result = IOServiceOpen(serviceObject, mach_task_self_, 0, &dataPort)
    IOObjectRelease(serviceObject)

    guard result == KERN_SUCCESS else {
        lua_pushinteger(L, -1)
        return 1
    }

    var outputs: UInt32 = 2
    var values: (UInt64, UInt64) = (0, 0)
    result = withUnsafeMutablePointer(to: &values) { ptr in
        ptr.withMemoryRebound(to: UInt64.self, capacity: 2) { valuesPtr in
            IOConnectCallMethod(dataPort, 0, nil, 0, nil, 0, valuesPtr, &outputs, nil, nil)
        }
    }
    IOServiceClose(dataPort)

    guard result == KERN_SUCCESS else {
        lua_pushinteger(L, -1)
        return 1
    }

    // Take the mean of the two sensor values (note that most modern MacBooks only have one sensor, so the values are identical)
    let lux = LMUtoLux((values.0 + values.1) / 2)
    lua_pushinteger(L, lua_Integer(lux))
    return 1
}

/// hs.brightness.set(brightness) -> boolean
/// Function
/// Sets the display brightness
///
/// Parameters:
///  * brightness - A number between 0 and 100
///
/// Returns:
///  * True if the brightness was set, false if not
private func brightness_set(_ L: OpaquePointer!) -> Int32 {
    let level = Float(min(max(Double(luaL_checkinteger(L, 1)) / 100.0, 0.0), 1.0))
    let err = DisplayServicesSetBrightness(CGMainDisplayID(), level)
    lua_pushboolean(L, (err == Int32(kCGErrorSuccess.rawValue)) ? 1 : 0)
    return 1
}

/// hs.brightness.get() -> number
/// Function
/// Returns the current brightness of the display
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the brightness of the display, between 0 and 100
private func brightness_get(_ L: OpaquePointer!) -> Int32 {
    var level: Float = 0
    let err = DisplayServicesGetBrightness(CGMainDisplayID(), &level)
    if err == Int32(kCGErrorSuccess.rawValue) {
        lua_pushinteger(L, lua_Integer(level * 100.0))
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Module registration

private let brightnessLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("set"), func: brightness_set),
    luaL_Reg(name: strdup("get"), func: brightness_get),
    luaL_Reg(name: strdup("ambient"), func: brightness_ambient),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libbrightness")
public func luaopen_hs_libbrightness(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.registerLibrary("hs.brightness", functions: brightnessLib, metaFunctions: nil)
    return 1
}
