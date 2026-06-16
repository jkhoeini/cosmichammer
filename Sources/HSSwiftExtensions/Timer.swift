import Cocoa
import CLua
import Lua
import HSDSTCore
import os.log

// MARK: - Common Code

private let USERDATA_TAG = "hs.timer"

// MARK: - HSTimer class

class HSTimer: NSObject {
    var timerHandle: (any TimerHandle)?
    var callback: LuaValue?
    var continueOnError: Bool = false
    var repeats: Bool = false
    var interval: TimeInterval = 0
    var generation: UInt64 = 0
    private var tornDown = false

    func create(_ L: LuaState, interval: TimeInterval, repeat shouldRepeat: Bool) {
        let clock = environmentGet(L).clock
        timerHandle = clock.createTimer(interval: interval, repeats: shouldRepeat) { [weak self] in
            self?.callbackFired()
        }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        timerHandle?.invalidate()
        timerHandle = nil
        callback = nil
    }

    func callbackFired() {
        if !lua_isStateGenerationValid(generation) {
            teardown()
            return
        }

        let L = lua_getCurrentState()!

        guard let th = timerHandle, th.isValid else {
            os_log(.error, "hs.timer callback fired on an invalid hs.timer object. This is a bug")
            return
        }

        guard let cb = callback else { return }

        cb.push(onto: L)
        if lua_pcall(L, 0, 0, 0) != LUA_OK {
            let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "(non-string error)"
            os_log(.error, "hs.timer callback error: %{public}s", errorMsg)
            lua_pop(L, 1)
            if !continueOnError {
                os_log(.error, "hs.timer callback failed. The timer has been stopped to prevent repeated notifications of the error.")
                os_log(.error, "  timer details: %{public}s repeating, every %f seconds", repeats ? "is" : "is not", interval)
                timerHandle?.invalidate()
            }
        }
    }

    var isRunning: Bool {
        timerHandle?.isScheduled ?? false
    }

    func start(_ L: LuaState) {
        if let th = timerHandle, !th.isValid {
            create(L, interval: interval, repeat: repeats)
        }

        timerHandle?.setNextFire(afterInterval: interval)
        timerHandle?.schedule()
    }

    func stop() {
        timerHandle?.invalidate()
    }

    var nextTrigger: Double {
        timerHandle?.nextFireInterval ?? 0
    }

    func setNextTrigger(_ interval: TimeInterval) {
        timerHandle?.setNextFire(afterInterval: interval)
    }

    func trigger() {
        guard let th = timerHandle, th.isValid else { return }
        th.fire()
    }
}

private func createHSTimer(_ L: LuaState, interval: TimeInterval, callbackValue: LuaValue, continueOnError: Bool, shouldRepeat: Bool) -> HSTimer {
    let timer = HSTimer()
    timer.callback = callbackValue
    timer.continueOnError = continueOnError
    timer.repeats = shouldRepeat
    timer.interval = interval
    timer.create(L, interval: interval, repeat: shouldRepeat)
    timer.generation = lua_currentStateGeneration()

    return timer
}

// MARK: - Lua constructors

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

    let cb = L.ref(index: 2)

    let continueOnError: Bool
    if lua_isboolean(L, 3) {
        continueOnError = lua_toboolean(L, 3) != 0
    } else {
        continueOnError = false
    }

    let shouldRepeat = sec != 0.0

    let timer = createHSTimer(L, interval: sec, callbackValue: cb, continueOnError: continueOnError, shouldRepeat: shouldRepeat)

    L.push(userdata: timer)

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
    let cb = L.ref(index: 2)

    let timer = createHSTimer(L, interval: sec, callbackValue: cb, continueOnError: false, shouldRepeat: false)

    timer.start(L)

    L.push(userdata: timer)

    return 1
}

// MARK: - Lua pure functions

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
    let microsecs = UInt32(luaL_checkinteger(L, 1))
    environmentGet(L).clock.sleep(microseconds: microsecs)
    return 0
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
    L.push(environmentGet(L).clock.secondsSinceEpoch())
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
    L.push(lua_Integer(environmentGet(L).clock.absoluteTimeNanos()))
    return 1
}

// MARK: - Module-level pure functions + constructors

// MARK: - Module entry point

@_cdecl("luaopen_hs_libtimer")
public func luaopen_hs_libtimer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    L.register(Metatable<HSTimer>(
        fields: [
            "start": .closure { L in
                let timer: HSTimer = try L.checkArgument(1)
                lua_settop(L, 1)
                if !timer.isRunning {
                    timer.start(L)
                }
                return 1
            },
            "stop": .closure { L in
                let timer: HSTimer = try L.checkArgument(1)
                lua_settop(L, 1)
                timer.stop()
                return 1
            },
            "setNextTrigger": .closure { L in
                let timer: HSTimer = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TNUMBER)
                let seconds = lua_tonumber(L, 2)
                if !timer.isRunning {
                    timer.start(L)
                }
                timer.setNextTrigger(seconds)
                lua_pushvalue(L, 1)
                return 1
            },
            "fire": .closure { L in
                let timer: HSTimer = try L.checkArgument(1)
                timer.trigger()
                lua_pushvalue(L, 1)
                return 1
            },
            "running": .memberfn { $0.isRunning },
            "nextTrigger": .memberfn { $0.nextTrigger },
        ],
        tostring: .closure { L in
            let timer: HSTimer = try L.checkArgument(1)
            let title: String
            if timer.timerHandle == nil {
                title = "BUG ENCOUNTERED, hs.timer tostring found timer.t nil"
            } else if timer.isRunning {
                title = "running"
            } else {
                title = "not running"
            }
            L.push("\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    L.pushMetatable(for: HSTimer.self)

    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let timer: HSTimer = L.touserdata(1) {
            timer.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    lua_createtable(L, 0, 5)
    L.push(timer_doAfter)
    lua_setfield(L, -2, "doAfter")
    L.push(timer_new)
    lua_setfield(L, -2, "new")
    L.push(timer_usleep)
    lua_setfield(L, -2, "usleep")
    L.push(timer_getSecondsSinceEpoch)
    lua_setfield(L, -2, "secondsSinceEpoch")
    L.push(timer_absoluteTime)
    lua_setfield(L, -2, "absoluteTime")

    return 1
}
