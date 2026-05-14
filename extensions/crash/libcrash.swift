import Cocoa
import LuaSkin

// ----------------------- API Implementation ---------------------

/// hs.crash.crash()
/// Function
/// Causes Hammerspoon to immediately crash
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
///
/// Notes:
///  * This is for testing purposes only, you are extremely unlikely to need this in normal Hammerspoon usage
private func burnTheWorld(_ L: OpaquePointer!) -> Int32 {
    let x = UnsafeMutablePointer<Int>.allocate(capacity: 0)
    x.deinitialize(count: 0)
    x.deallocate()
    // Force a crash via null pointer dereference
    let nullPtr: UnsafeMutablePointer<Int32>? = nil
    nullPtr!.pointee = 42
    return 0
}

/// hs.crash.throwObjCException(name, message)
/// Function
/// Causes Hammerspoon to generate an Objective C exception
///
/// Parameters:
///  * name - A string containing the name of the exception
///  * message - A human readable string explaining the exception
///
/// Returns:
///  * None
///
/// Notes:
///  * Outside of a context of a Lua pcall() (or a C lua_pcall()), this will cause Hammerspoon to exit. We follow the safe behaviour of terminating the app on any unhandled Objective C exception.
private func throwTheWorld(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)

    let name = skin.toNSObject(atIndex: 1) as! String
    let message = skin.toNSObject(atIndex: 2) as! String
    NSException.raise(NSExceptionName(rawValue: name), format: "%@", message)

    return 0
}

/// hs.crash.crashLog(logMessage)
/// Function
/// Leaves a breadcrumb log message
///
/// Parameters:
///  * logMessage - A string containing a message to log
///
/// Returns:
///  * None
///
/// Notes:
///  * This is probably only useful to extension developers.
private func crashLog(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.logBreadcrumb(skin.toNSObject(atIndex: 1) as! String)

    return 0
}

/// hs.crash.crashKV(key, value)
/// Function
/// Sets a key/value pair in the crash data
///
/// Parameters:
///  * key - A string containing the key name of the pair
///  * value - A string containing the value of the pair
///
/// Returns:
///  * None
private func crashKV(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)

    let _ = skin.toNSObject(atIndex: 1) as! String
    let _ = skin.toNSObject(atIndex: 2) as! String

    return 0
}

/// hs.crash.residentSize() -> integer or nil
/// Function
/// Gets the resident size of the Hammerspoon process
///
/// Parameters:
///  * None
///
/// Returns:
///  * An integer containing the amount of RAM in use by Hammerspoon (in bytes), or nil if an error occurred
private func residentSize(_ L: OpaquePointer!) -> Int32 {
    var info = task_basic_info()
    var size = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size) / 4
    let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), intPtr, &size)
        }
    }

    if kerr == KERN_SUCCESS {
        lua_pushinteger(L, lua_Integer(info.resident_size))
    } else {
        lua_pushnil(L)
        NSLog("Error with task_info(): %s", mach_error_string(kerr))
    }

    return 1
}

private var crashlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("crash"), func: burnTheWorld),
    luaL_Reg(name: strdup("throwObjCException"), func: throwTheWorld),
    luaL_Reg(name: strdup("crashLog"), func: crashLog),
    luaL_Reg(name: strdup("crashKV"), func: crashKV),
    luaL_Reg(name: strdup("residentSize"), func: residentSize),
    luaL_Reg(name: nil, func: nil),
]

/* NOTE: The substring "hs_crash_internal" in the following function's name
         must match the require-path of this file, i.e. "hs.crash.internal". */

@_cdecl("luaopen_hs_libcrash")
public func luaopen_hs_libcrash(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.registerLibrary("hs.crash", functions: &crashlib, metaFunctions: nil)
    return 1
}
