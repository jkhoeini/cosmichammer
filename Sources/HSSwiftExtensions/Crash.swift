import Cocoa
import CLua
import Lua
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
private func burnTheWorld(_ L: LuaState) throws -> CInt {
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
private func throwTheWorld(_ L: LuaState) throws -> CInt {
    let name: String = try L.checkArgument(1)
    let message: String = try L.checkArgument(2)

    if let error = catchingObjCException({
        NSException(name: NSExceptionName(rawValue: name), reason: message, userInfo: nil).raise()
    }) {
        throw LuaCallError("ObjC exception: \(error)")
    }

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
private func crashLog(_ L: LuaState) throws -> CInt {
    let msg: String = try L.checkArgument(1)
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
private func crashKV(_ L: LuaState) throws -> CInt {
    let _: String = try L.checkArgument(1)
    let _: String = try L.checkArgument(2)

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
private func residentSize(_ L: LuaState) throws -> CInt {
    var info = task_basic_info()
    var size = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size) / 4
    let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), intPtr, &size)
        }
    }

    if kerr == KERN_SUCCESS {
        L.push(Int(info.resident_size))
    } else {
        lua_pushnil(L)
        os_log(.error, "Error with task_info(): %{public}s", String(cString: mach_error_string(kerr)))
    }

    return 1
}

/* NOTE: The substring "hs_crash_internal" in the following function's name
         must match the require-path of this file, i.e. "hs.crash.internal". */

@_cdecl("luaopen_hs_libcrash")
public func luaopen_hs_libcrash(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 5)
        L.push(burnTheWorld)
        lua_setfield(L, -2, "crash")
        L.push(throwTheWorld)
        lua_setfield(L, -2, "throwObjCException")
        L.push(crashLog)
        lua_setfield(L, -2, "crashLog")
        L.push(crashKV)
        lua_setfield(L, -2, "crashKV")
        L.push(residentSize)
        lua_setfield(L, -2, "residentSize")
    }
}
