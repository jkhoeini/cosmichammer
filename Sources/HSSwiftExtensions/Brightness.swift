import Cocoa
import CLua
import Lua
import HSDSTCore
import Carbon
import IOKit.graphics
import os.log

// MARK: - Private framework function lookups via dlsym

private let _displayServicesHandle: UnsafeMutableRawPointer? = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    RTLD_LAZY
)

private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

private let _getBrightness: GetBrightnessFn? = {
    guard let handle = _displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(sym, to: GetBrightnessFn.self)
}()

private let _setBrightness: SetBrightnessFn? = {
    guard let handle = _displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(sym, to: SetBrightnessFn.self)
}()

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
private func brightness_ambient(_ L: LuaState) throws -> CInt {
    let serviceObject = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleLMUController"))

    if serviceObject == IO_OBJECT_NULL {
        // M1+ macs don't have an AppleLMUController IOService, so we use the
        // private DisplayServicesClient class via ObjC runtime to call
        // -[DisplayServicesClient copyPropertyForKey:@"AggregatedLux"].
        // NSInvocation/NSMethodSignature are unavailable in Swift, so we use
        // performSelector to invoke the method instead.
        if let dscClass = NSClassFromString("DisplayServicesClient") as? NSObject.Type {
            let ourDSC = dscClass.init()
            let sel = NSSelectorFromString("copyPropertyForKey:")
            if ourDSC.responds(to: sel) {
                let key: NSString = "AggregatedLux"
                if let result = catchingObjCException({
                    ourDSC.perform(sel, with: key)?.takeRetainedValue() as? NSNumber
                }) {
                    L.push(result.doubleValue)
                    return 1
                }
            }
        }
        // Fall through to push -1
        L.push(Int(-1))
        return 1
    }

    var dataPort: io_connect_t = 0
    var result = KERN_SUCCESS
    if let error: String = catchingObjCException({
        result = IOServiceOpen(serviceObject, mach_task_self_, 0, &dataPort)
    }) {
        os_log(.error, "caught ObjC exception in IOServiceOpen: \(error, privacy: .public)")
        IOObjectRelease(serviceObject)
        L.push(Int(-1))
        return 1
    }
    IOObjectRelease(serviceObject)

    guard result == KERN_SUCCESS else {
        L.push(Int(-1))
        return 1
    }

    var outputs: UInt32 = 2
    var values: (UInt64, UInt64) = (0, 0)
    if let error: String = catchingObjCException({
        result = withUnsafeMutablePointer(to: &values) { ptr in
            ptr.withMemoryRebound(to: UInt64.self, capacity: 2) { valuesPtr in
                IOConnectCallMethod(dataPort, 0, nil, 0, nil, 0, valuesPtr, &outputs, nil, nil)
            }
        }
    }) {
        os_log(.error, "caught ObjC exception in IOConnectCallMethod: \(error, privacy: .public)")
        IOServiceClose(dataPort)
        L.push(Int(-1))
        return 1
    }
    IOServiceClose(dataPort)

    guard result == KERN_SUCCESS else {
        L.push(Int(-1))
        return 1
    }

    // Take the mean of the two sensor values (note that most modern MacBooks only have one sensor, so the values are identical)
    let lux = LMUtoLux((values.0 + values.1) / 2)
    L.push(Int(lux))
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
private func brightness_set(_ L: LuaState) throws -> CInt {
    let brightness = luaL_checknumber(L, 1)
    let level = min(max(brightness / 100.0, 0.0), 1.0)
    let screen = environmentGet(L).screen
    if let main = screen.mainScreen() {
        L.push(screen.setBrightness(level, forScreenID: main.id))
    } else {
        L.push(false)
    }
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
private func brightness_get(_ L: LuaState) throws -> CInt {
    if let main = environmentGet(L).screen.mainScreen() {
        L.push(Int(main.brightness * 100.0))
    } else {
        lua_pushnil(L)
    }
    return 1
}

// MARK: - Module registration

@_cdecl("luaopen_hs_libbrightness")
public func luaopen_hs_libbrightness(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 3)
        L.push(brightness_set)
        lua_setfield(L, -2, "set")
        L.push(brightness_get)
        lua_setfield(L, -2, "get")
        L.push(brightness_ambient)
        lua_setfield(L, -2, "ambient")
    }
}
