import Cocoa
import Carbon
import IOKit.pwr_mgt
import LuaSkin
import os.log

// MARK: - Apple Private API items

private let kIOPMAssertionAppliesToLimitedPowerKey = "AppliesToLimitedPower" as CFString
private var loginFramework: CFBundle?
private typealias SACLockScreenImmediatePtr = @convention(c) () -> Void

// MARK: - Assertion state

private var noIdleDisplaySleep: IOPMAssertionID = 0
private var noIdleSystemSleep: IOPMAssertionID = 0
private var noSystemSleep: IOPMAssertionID = 0

// MARK: - Helpers

private func stringFromError(_ errorVal: UInt32) -> String? {
    let ioReturnMap: [Int32: String] = [
        kIOReturnSuccess:          "success",
        kIOReturnError:            "general error",
        kIOReturnNoMemory:         "memory allocation error",
        kIOReturnNoResources:      "resource shortage",
        kIOReturnIPCError:         "Mach IPC failure",
        kIOReturnNoDevice:         "no such device",
        kIOReturnNotPrivileged:    "privilege violation",
        kIOReturnBadArgument:      "invalid argument",
        kIOReturnLockedRead:       "device is read locked",
        kIOReturnLockedWrite:      "device is write locked",
        kIOReturnExclusiveAccess:  "device is exclusive access",
        kIOReturnBadMessageID:     "bad IPC message ID",
        kIOReturnUnsupported:      "unsupported function",
        kIOReturnVMError:          "virtual memory error",
        kIOReturnInternalError:    "internal driver error",
        kIOReturnIOError:          "I/O error",
        kIOReturnCannotLock:       "cannot acquire lock",
        kIOReturnNotOpen:          "device is not open",
        kIOReturnNotReadable:      "device is not readable",
        kIOReturnNotWritable:      "device is not writeable",
        kIOReturnNotAligned:       "alignment error",
        kIOReturnBadMedia:         "media error",
        kIOReturnStillOpen:        "device is still open",
        kIOReturnRLDError:         "rld failure",
        kIOReturnDMAError:         "DMA failure",
        kIOReturnBusy:             "device is busy",
        kIOReturnTimeout:          "I/O timeout",
        kIOReturnOffline:          "device is offline",
        kIOReturnNotReady:         "device is not ready",
        kIOReturnNotAttached:      "device/channel is not attached",
        kIOReturnNoChannels:       "no DMA channels available",
        kIOReturnNoSpace:          "no space for data",
        kIOReturnPortExists:       "device port already exists",
        kIOReturnCannotWire:       "cannot wire physical memory",
        kIOReturnNoInterrupt:      "no interrupt attached",
        kIOReturnNoFrames:         "no DMA frames enqueued",
        kIOReturnMessageTooLarge:  "message is too large",
        kIOReturnNotPermitted:     "operation is not permitted",
        kIOReturnNoPower:          "device is without power",
        kIOReturnNoMedia:          "media is not present",
        kIOReturnUnformattedMedia: "media is not formatted",
        kIOReturnUnsupportedMode:  "unsupported mode",
        kIOReturnUnderrun:         "data underrun",
        kIOReturnOverrun:          "data overrun",
        kIOReturnDeviceError:      "device error",
        kIOReturnNoCompletion:     "no completion routine",
        kIOReturnAborted:          "operation was aborted",
        kIOReturnNoBandwidth:      "bus bandwidth would be exceeded",
        kIOReturnNotResponding:    "device is not responding",
        kIOReturnInvalid:          "unanticipated driver error",
    ]
    return ioReturnMap[Int32(bitPattern: errorVal)]
}

// Create an IOPM Assertion of specified type and store its ID in the specified variable
private func caffeinate_create_assertion(_ L: UnsafeMutablePointer<lua_State>!, _ assertionType: CFString, _ assertionID: UnsafeMutablePointer<IOPMAssertionID>) {
    guard assertionID.pointee == 0 else { return }

    let result = IOPMAssertionCreateWithDescription(
        assertionType,
        "hs.caffeinate" as CFString,
        nil, nil, nil,
        0.0,
        nil,
        assertionID
    )

    if result != kIOReturnSuccess {
        os_log(.error, "caffeinate_create_assertion: failed (%{public}s)", stringFromError(UInt32(result)) ?? "unknown")
    }
}

// Release a previously stored assertion
private func caffeinate_release_assertion(_ L: UnsafeMutablePointer<lua_State>!, _ assertionID: UnsafeMutablePointer<IOPMAssertionID>) {
    guard assertionID.pointee != 0 else { return }

    let result = IOPMAssertionRelease(assertionID.pointee)

    if result != kIOReturnSuccess {
        os_log(.error, "caffeinate_release_assertion: failed (%{public}s)", stringFromError(UInt32(result)) ?? "unknown")
    }

    assertionID.pointee = 0
}

// MARK: - Functions for display sleep when user is idle

// Prevent display sleep if the user goes idle (and by implication, system sleep)
private func caffeinate_preventIdleDisplaySleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    caffeinate_create_assertion(L, kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, &noIdleDisplaySleep)
    return 0
}

// Allow display sleep if the user goes idle
private func caffeinate_allowIdleDisplaySleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    caffeinate_release_assertion(L, &noIdleDisplaySleep)
    return 0
}

// Determine if idle display sleep is currently prevented
private func caffeinate_isIdleDisplaySleepPrevented(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushboolean(L, noIdleDisplaySleep != 0 ? 1 : 0)
    return 1
}

// MARK: - Functions for system sleep when user is idle

// Prevent system sleep if the user goes idle (display may still sleep)
private func caffeinate_preventIdleSystemSleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    caffeinate_create_assertion(L, kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, &noIdleSystemSleep)
    return 0
}

// Allow system sleep if the user goes idle
private func caffeinate_allowIdleSystemSleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    caffeinate_release_assertion(L, &noIdleSystemSleep)
    return 0
}

// Determine if idle system sleep is currently prevented
private func caffeinate_isIdleSystemSleepPrevented(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushboolean(L, noIdleSystemSleep != 0 ? 1 : 0)
    return 1
}

// MARK: - Functions for system sleep

// Prevent system sleep
private func caffeinate_preventSystemSleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var acAndBattery = false
    if lua_isboolean(L, 1) {
        acAndBattery = lua_toboolean(L, 1) != 0
    }
    lua_settop(L, 1)

    caffeinate_create_assertion(L, kIOPMAssertionTypePreventSystemSleep as CFString, &noSystemSleep)

    if noSystemSleep != 0 {
        let value: CFBoolean = acAndBattery ? kCFBooleanTrue : kCFBooleanFalse
        let result = IOPMAssertionSetProperty(
            noSystemSleep,
            kIOPMAssertionAppliesToLimitedPowerKey,
            value
        )
        if result != kIOReturnSuccess {
            os_log(.error, "Unable to set systemSleep assertion property (%{public}s)", stringFromError(UInt32(result)) ?? "unknown")
        }
    }

    return 0
}

// Allow system sleep
private func caffeinate_allowSystemSleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    caffeinate_release_assertion(L, &noSystemSleep)
    return 0
}

// Determine if system sleep is currently prevented
private func caffeinate_isSystemSleepPrevented(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushboolean(L, noSystemSleep != 0 ? 1 : 0)
    return 1
}

/// hs.caffeinate.systemSleep()
/// Function
/// Requests the system to sleep immediately
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func caffeinate_systemSleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let port = IOPMFindPowerManagement(UInt32(MACH_PORT_NULL))
    IOPMSleepSystem(port)
    IOServiceClose(port)
    return 0
}

/// hs.caffeinate.declareUserActivity([id])
/// Function
/// Informs the OS that the user performed some activity
///
/// Parameters:
///  * id - An option number containing the assertion ID returned by a previous call of this function
///
/// Returns:
///  * A number containing the ID of the assertion generated by this function
///
/// Notes:
///  * This is intended to simulate user activity, for example to prevent displays from sleeping, or to wake them up
///  * It is not mandatory to re-use assertion IDs if you are calling this function multiple times, but it is recommended that you do so if the calls are related
private func caffeinate_declareUserActivity(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Optional integer or nil argument

    var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    if lua_type(L, 1) == LUA_TNUMBER {
        assertionID = IOPMAssertionID(lua_tointeger(L, 1))
    }
    IOPMAssertionDeclareUserActivity("hs.caffeinate.declareUserActivity()" as CFString, kIOPMUserActiveLocal, &assertionID)

    lua_pushinteger(L, lua_Integer(assertionID))
    return 1
}

/// hs.caffeinate.lockScreen()
/// Function
/// Locks the displays
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
///
/// Notes:
///  * This function uses private Apple APIs and could therefore stop working in any given release of macOS without warning.
private func caffeinate_lockScreen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Load the private API we need to call SACLockScreenImmediate()
    if loginFramework == nil {
        let bundlePath = "/System/Library/PrivateFrameworks/login.framework"
        let bundleURL = URL(fileURLWithPath: bundlePath) as CFURL
        loginFramework = CFBundleCreate(kCFAllocatorDefault, bundleURL)
    }

    guard let framework = loginFramework else {
        os_log(.error, "Unable to load login.framework")
        return 0
    }

    guard let funcPtr = CFBundleGetFunctionPointerForName(framework, "SACLockScreenImmediate" as CFString) else {
        os_log(.error, "Unable to load SACLockScreenImmediate from private login.framework")
        return 0
    }

    let sacLockScreenImmediate = unsafeBitCast(funcPtr, to: SACLockScreenImmediatePtr.self)
    sacLockScreenImmediate()

    return 0
}

/// hs.caffeinate.sessionProperties()
/// Function
/// Fetches information from the display server about the current session
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing information about the current session, or nil if an error occurred
///
/// Notes:
///  * The keys in this dictionary will vary based on the current state of the system (e.g. local vs VNC login, screen locked vs unlocked).
private func caffeinate_sessionProperties(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    guard let ref = CGSessionCopyCurrentDictionary() else {
        lua_pushnil(L)
        return 1
    }

    lua_pushany(L, ref as NSDictionary)
    return 1
}

/// hs.caffeinate.currentAssertions()
/// Function
/// Fetches information about processes which are currently asserting display/power sleep restrictions
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing information about current power assertions, with process IDs (PID) as the keys, each of which may contain multiple assertions
private func caffeinate_currentAssertions(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var assertions: Unmanaged<CFDictionary>?
    let result = IOPMCopyAssertionsByProcess(&assertions)
    if result != kIOReturnSuccess {
        lua_pushany(L, NSDictionary())
        return 1
    }

    if let dict = assertions?.takeRetainedValue() {
        lua_pushany(L, dict as NSDictionary)
    } else {
        lua_pushany(L, NSDictionary())
    }

    return 1
}

// MARK: - Lua/hs glue

private func caffeinate_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // TODO: We should register which of the assertions we have active, somewhere that persists a reload()
    _ = caffeinate_allowIdleDisplaySleep(L)
    _ = caffeinate_allowIdleSystemSleep(L)
    _ = caffeinate_allowSystemSleep(L)

    loginFramework = nil

    return 0
}

// MARK: - Module registration

private var caffeinatelib: [luaL_Reg] = [
    luaL_Reg(name: strdup("preventIdleDisplaySleep"), func: caffeinate_preventIdleDisplaySleep),
    luaL_Reg(name: strdup("allowIdleDisplaySleep"), func: caffeinate_allowIdleDisplaySleep),
    luaL_Reg(name: strdup("isIdleDisplaySleepPrevented"), func: caffeinate_isIdleDisplaySleepPrevented),

    luaL_Reg(name: strdup("preventIdleSystemSleep"), func: caffeinate_preventIdleSystemSleep),
    luaL_Reg(name: strdup("allowIdleSystemSleep"), func: caffeinate_allowIdleSystemSleep),
    luaL_Reg(name: strdup("isIdleSystemSleepPrevented"), func: caffeinate_isIdleSystemSleepPrevented),

    luaL_Reg(name: strdup("_preventSystemSleep"), func: caffeinate_preventSystemSleep),
    luaL_Reg(name: strdup("allowSystemSleep"), func: caffeinate_allowSystemSleep),
    luaL_Reg(name: strdup("isSystemSleepPrevented"), func: caffeinate_isSystemSleepPrevented),
    luaL_Reg(name: strdup("systemSleep"), func: caffeinate_systemSleep),

    luaL_Reg(name: strdup("declareUserActivity"), func: caffeinate_declareUserActivity),
    luaL_Reg(name: strdup("lockScreen"), func: caffeinate_lockScreen),

    luaL_Reg(name: strdup("sessionProperties"), func: caffeinate_sessionProperties),

    luaL_Reg(name: strdup("currentAssertions"), func: caffeinate_currentAssertions),

    luaL_Reg(name: nil, func: nil),
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: caffeinate_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libcaffeinate")
public func luaopen_hs_libcaffeinate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create module table
    lua_createtable(L, 0, Int32(caffeinatelib.count - 1))
    luaL_setfuncs(L, &caffeinatelib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(metalib.count - 1))
    luaL_setfuncs(L, &metalib, 0)
    lua_setmetatable(L, -2)

    return 1
}
