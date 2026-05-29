import Cocoa
import CLua
import os.log

// ----------------------- API Implementation ---------------------

/// hs.crash.crash()
/// Function
/// Causes Cosmic Hammer to immediately crash
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
///
/// Notes:
///  * This is for testing purposes only, you are extremely unlikely to need this in normal Cosmic Hammer usage
private func burnTheWorld(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
/// Causes Cosmic Hammer to generate an Objective C exception
///
/// Parameters:
///  * name - A string containing the name of the exception
///  * message - A human readable string explaining the exception
///
/// Returns:
///  * None
///
/// Notes:
///  * Outside of a context of a Lua pcall() (or a C lua_pcall()), this will cause Cosmic Hammer to exit. We follow the safe behaviour of terminating the app on any unhandled Objective C exception.
private func throwTheWorld(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard lua_type(L, 1) == LUA_TSTRING else {
        return luaL_error(L, "expected string for argument 1")
    }
    guard lua_type(L, 2) == LUA_TSTRING else {
        return luaL_error(L, "expected string for argument 2")
    }

    let name = String(cString: lua_tostring(L, 1)!)
    let message = String(cString: lua_tostring(L, 2)!)
    NSException(name: NSExceptionName(rawValue: name), reason: message, userInfo: nil).raise()

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
private func crashLog(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let msg = String(cString: luaL_checkstring(L, 1))
    os_log(.info, "breadcrumb: %{public}s", msg)

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
private func crashKV(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard lua_type(L, 1) == LUA_TSTRING else {
        return luaL_error(L, "expected string for argument 1")
    }
    guard lua_type(L, 2) == LUA_TSTRING else {
        return luaL_error(L, "expected string for argument 2")
    }

    let _ = String(cString: lua_tostring(L, 1)!)
    let _ = String(cString: lua_tostring(L, 2)!)

    return 0
}

/// hs.crash.residentSize() -> integer or nil
/// Function
/// Gets the resident size of the Cosmic Hammer process
///
/// Parameters:
///  * None
///
/// Returns:
///  * An integer containing the amount of RAM in use by Cosmic Hammer (in bytes), or nil if an error occurred
private func residentSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
        os_log(.error, "Error with task_info(): %{public}s", String(cString: mach_error_string(kerr)))
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
public func luaopen_hs_libcrash(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_createtable(L, 0, Int32(crashlib.count - 1))
    luaL_setfuncs(L, &crashlib, 0)
    return 1
}
