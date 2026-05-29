import Cocoa
import CLua
import Darwin.POSIX.sys.time
import os.log

// MARK: - Common Code

private let USERDATA_TAG = "hs.timer"
private var refTable: Int32 = 0

// MARK: - HSTimer class

class HSTimer: NSObject {
    var t: Timer?
    var fnRef: Int32 = LUA_NOREF
    var continueOnError: Bool = false
    var repeats: Bool = false
    var interval: TimeInterval = 0
    var generation: UInt64 = 0

    func create(_ interval: TimeInterval, repeat shouldRepeat: Bool) {
        t = Timer(timeInterval: interval, target: self, selector: #selector(callback(_:)), userInfo: nil, repeats: shouldRepeat)
    }

    @objc func callback(_ timer: Timer) {
        if !lua_isStateGenerationValid(generation) {
            stop()
            return
        }

        let L = lua_getCurrentState()!

        if !timer.isValid {
            os_log(.error, "hs.timer callback fired on an invalid hs.timer object. This is a bug")
            return
        }

        if timer !== t {
            os_log(.error, "hs.timer callback fired with inconsistencies about which NSTimer object it owns. This is a bug")
        }

        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fnRef))
        if lua_pcall(L, 0, 0, 0) != LUA_OK {
            let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "(non-string error)"
            os_log(.error, "hs.timer callback error: %{public}s", errorMsg)
            lua_pop(L, 1) // clear error message from stack
            if !continueOnError {
                os_log(.error, "hs.timer callback failed. The timer has been stopped to prevent repeated notifications of the error.")
                let doesRepeat = CFRunLoopTimerDoesRepeat(t as CFRunLoopTimer?)
                os_log(.error, "  timer details: %{public}s repeating, every %f seconds", doesRepeat ? "is" : "is not", interval)
                t?.invalidate()
            }
        }
    }

    var isRunning: Bool {
        guard let timer = t else { return false }
        return CFRunLoopContainsTimer(CFRunLoopGetMain(), timer as CFRunLoopTimer, CFRunLoopMode.defaultMode)
    }

    func start() {
        if let timer = t, !timer.isValid {
            // We've previously been stopped, which means the NSTimer is invalid, so recreate it
            create(interval, repeat: repeats)
        }

        setNextTrigger(interval)
        RunLoop.main.add(t!, forMode: .common)
    }

    func stop() {
        if let timer = t, timer.isValid {
            timer.invalidate()
        }
    }

    var nextTrigger: Double {
        let now = CFAbsoluteTimeGetCurrent()
        let next = CFRunLoopTimerGetNextFireDate(t as CFRunLoopTimer?)
        return next - now
    }

    func setNextTrigger(_ interval: TimeInterval) {
        if let timer = t, timer.isValid {
            timer.fireDate = Date(timeIntervalSinceNow: interval)
        }
    }

    func trigger() {
        if let timer = t, timer.isValid {
            timer.fire()
        }
    }
}

private func createHSTimer(_ interval: TimeInterval, callbackRef: Int32, continueOnError: Bool, shouldRepeat: Bool) -> HSTimer {
    let timer = HSTimer()
    timer.fnRef = callbackRef
    timer.continueOnError = continueOnError
    timer.repeats = shouldRepeat
    timer.interval = interval
    timer.create(interval, repeat: shouldRepeat)
    timer.generation = lua_currentStateGeneration()

    return timer
}

// MARK: - Helper to extract HSTimer from userdata

private func getTimer(from L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSTimer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSTimer>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee).takeUnretainedValue()
}

private func getTimerTransfer(from L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> HSTimer {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
    return Unmanaged<HSTimer>.fromOpaque(ptr.assumingMemoryBound(to: UnsafeMutableRawPointer.self).pointee).takeRetainedValue()
}

// MARK: - Lua functions

/// hs.timer.new(interval, fn [, continueOnError]) -> timer
/// Constructor
/// Creates a new `hs.timer` object for repeating interval callbacks
///
/// Parameters:
///  * interval - A number of seconds between firings of the timer
///  * fn - A function to call every time the timer fires
///  * continueOnError - An optional boolean, true if the timer should continue to be triggered after the callback function has produced an error, false if the timer should stop being triggered after the callback function has produced an error. Defaults to false.
///
/// Returns:
///  * An `hs.timer` object
///
/// Notes:
///  * The returned object does not start its timer until its `:start()` method is called
///  * If `interval` is 0, the timer will not repeat (because if it did, it would be repeating as fast as your machine can manage, which seems generally unwise)
///  * For non-zero intervals, the lowest acceptable value for the interval is 0.00001s. Values >0 and <0.00001 will be coerced to 0.00001
private func timer_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TNUMBER)
    luaL_checktype(L, 2, LUA_TFUNCTION)

    var sec = lua_tonumber(L, 1)
    if sec > 0 && sec < 0.00001 {
        os_log(.info, "Minimum non-zero hs.timer interval is 0.00001s. Forcing to 0.00001")
        sec = 0.00001
    }
    lua_pushvalue(L, 2)
    let callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    let continueOnError: Bool
    if lua_isboolean(L, 3) {
        continueOnError = lua_toboolean(L, 3) != 0
    } else {
        continueOnError = false
    }

    let shouldRepeat = sec != 0.0

    let timer = createHSTimer(sec, callbackRef: callbackRef, continueOnError: continueOnError, shouldRepeat: shouldRepeat)

    // Wire up the timer object to Lua
    let userData = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    userData.pointee = Unmanaged.passRetained(timer).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.timer:start() -> timer
/// Method
/// Starts an `hs.timer` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.timer` object
///
/// Notes:
///  * The timer will not call the callback immediately, the timer will wait until it fires
///  * If the callback function results in an error, the timer will be stopped to prevent repeated error notifications (see the `continueOnError` parameter to `hs.timer.new()` to override this)
private func timer_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimer(from: L, at: 1)
    lua_settop(L, 1)

    if !timer.isRunning {
        timer.start()
    }

    return 1
}

/// hs.timer.doAfter(sec, fn) -> timer
/// Constructor
/// Calls a function after a delay
///
/// Parameters:
///  * sec - A number of seconds to wait before calling the function
///  * fn - A function to call
///
/// Returns:
///  * An `hs.timer` object
///
/// Notes:
///  * There is no need to call `:start()` on the returned object, the timer will be already running.
///  * The callback can be cancelled by calling the `:stop()` method on the returned object before `sec` seconds have passed.
private func timer_doAfter(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TNUMBER)
    luaL_checktype(L, 2, LUA_TFUNCTION)

    let sec = lua_tonumber(L, 1)
    lua_pushvalue(L, 2)
    let callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    let timer = createHSTimer(sec, callbackRef: callbackRef, continueOnError: false, shouldRepeat: false)

    // Immediately start it
    timer.start()

    // Wire up the timer object to Lua
    let userData = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!.assumingMemoryBound(to: UnsafeMutableRawPointer.self)
    userData.pointee = Unmanaged.passRetained(timer).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.timer.usleep(microsecs)
/// Function
/// Blocks Lua execution for the specified time
///
/// Parameters:
///  * microsecs - A number containing a time in microseconds to block for
///
/// Returns:
///  * None
///
/// Notes:
///  * Use of this function is strongly discouraged, as it blocks all main-thread execution in Cosmic Hammer. This means no hotkeys or events will be processed in that time, no GUI updates will happen, and no Lua will execute. This is only provided as a last resort, or for extremely short sleeps. For all other purposes, you really should be splitting up your code into multiple functions and calling `hs.timer.doAfter()`
private func timer_usleep(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let microsecs = useconds_t(luaL_checkinteger(L, 1))
    usleep(microsecs)
    return 0
}

/// hs.timer:running() -> boolean
/// Method
/// Returns a boolean indicating whether or not the timer is currently running.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean value indicating whether or not the timer is currently running.
private func timer_running(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimer(from: L, at: 1)

    lua_pushboolean(L, timer.isRunning ? 1 : 0)
    return 1
}

/// hs.timer:nextTrigger() -> number
/// Method
/// Returns the number of seconds until the timer will next trigger
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the number of seconds until the next firing
///
/// Notes:
///  * The return value may be a negative integer in two circumstances:
///   * Cosmic Hammer's runloop is backlogged and is catching up on missed timer triggers
///   * The timer object is not currently running. In this case, the return value of this method is the number of seconds since the last firing (you can check if the timer is running or not, with `hs.timer:running()`
private func timer_nextTrigger(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimer(from: L, at: 1)

    lua_pushnumber(L, timer.nextTrigger)
    return 1
}

/// hs.timer:setNextTrigger(seconds) -> timer
/// Method
/// Sets the next trigger time of a timer
///
/// Parameters:
///  * seconds - A number of seconds after which to trigger the timer
///
/// Returns:
///  * The `hs.timer` object, or nil if an error occurred
///
/// Notes:
///  * If the timer is not already running, this will start it
private func timer_setNextTrigger(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimer(from: L, at: 1)
    luaL_checktype(L, 2, LUA_TNUMBER)

    let seconds = lua_tonumber(L, 2)

    if !timer.isRunning {
        timer.start()
    }

    timer.setNextTrigger(seconds)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.timer:fire() -> timer
/// Method
/// Immediately fires a timer
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.timer` object
///
/// Notes:
///  * This cannot be used on a timer which has already stopped running
private func timer_trigger(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimer(from: L, at: 1)

    timer.trigger()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.timer:stop() -> timer
/// Method
/// Stops an `hs.timer` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.timer` object
private func timer_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimer(from: L, at: 1)
    lua_settop(L, 1)

    timer.stop()

    return 1
}

private func timer_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimerTransfer(from: L, at: 1)

    timer.stop()
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, timer.fnRef)
    timer.fnRef = Int32(LUA_NOREF)
    timer.t = nil

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer = getTimer(from: L, at: 1)

    let title: String
    if timer.t == nil {
        title = "BUG ENCOUNTERED, hs.timer tostring found timer.t nil"
    } else if timer.isRunning {
        title = "running"
    } else {
        title = "not running"
    }

    lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
    return 1
}

/// hs.timer.secondsSinceEpoch() -> sec
/// Function
/// Gets the (fractional) number of seconds since the UNIX epoch (January 1, 1970)
///
/// Parameters:
///  * None
///
/// Returns:
///  * The number of seconds since the epoch
///
/// Notes:
///  * This has much better precision than `os.time()`, which is limited to whole seconds.
private func timer_getSecondsSinceEpoch(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var v = timeval()
    gettimeofday(&v, nil)
    lua_pushnumber(L, Double(v.tv_sec) + Double(v.tv_usec) / 1.0e6)
    return 1
}

/// hs.timer.absoluteTime() -> nanoseconds
/// Function
/// Returns the absolute time in nanoseconds since the last system boot.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the time since the last system boot in nanoseconds
///
/// Notes:
///  * this value does not include time that the system has spent asleep
///  * this value is used for the timestamps in system generated events.
private func timer_absoluteTime(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let absTime = mach_absolute_time()
    lua_pushinteger(L, lua_Integer((absTime * UInt64(timebase.numer)) / UInt64(timebase.denom)))
    return 1
}

// MARK: - luaL_Reg tables

// Metatable for created objects when _new invoked
private var timer_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"), func: { timer_start($0) }),
    luaL_Reg(name: strdup("stop"), func: { timer_stop($0) }),
    luaL_Reg(name: strdup("running"), func: { timer_running($0) }),
    luaL_Reg(name: strdup("nextTrigger"), func: { timer_nextTrigger($0) }),
    luaL_Reg(name: strdup("setNextTrigger"), func: { timer_setNextTrigger($0) }),
    luaL_Reg(name: strdup("fire"), func: { timer_trigger($0) }),
    luaL_Reg(name: strdup("__tostring"), func: { userdata_tostring($0) }),
    luaL_Reg(name: strdup("__gc"), func: { timer_gc($0) }),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private var timerLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("doAfter"), func: { timer_doAfter($0) }),
    luaL_Reg(name: strdup("new"), func: { timer_new($0) }),
    luaL_Reg(name: strdup("usleep"), func: { timer_usleep($0) }),
    luaL_Reg(name: strdup("secondsSinceEpoch"), func: { timer_getSecondsSinceEpoch($0) }),
    luaL_Reg(name: strdup("absoluteTime"), func: { timer_absoluteTime($0) }),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for returned object when module loads
private var meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: { meta_gc($0) }),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libtimer")
public func luaopen_hs_libtimer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &timer_metalib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(timerLib.count - 1))
    luaL_setfuncs(L, &timerLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(meta_gcLib.count - 1))
    luaL_setfuncs(L, &meta_gcLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
