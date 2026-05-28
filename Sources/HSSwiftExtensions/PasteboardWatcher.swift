import Cocoa
import LuaSkin

/// === hs.pasteboard.watcher ===
///
/// Watch for Pasteboard Changes.
/// macOS doesn't offer any API for getting Pasteboard notifications, so this extension uses polling to check for Pasteboard changes at a chosen interval (defaults to 0.25).

private let USERDATA_TAG = "hs.pasteboard.watcher"

// How often we should poll the Pasteboard for changes:
private var pollingInterval: Double = 0.25

// We only use a single NSTimer for all Pasteboard Watchers:
private var sharedPasteboardTimerCount: Int = 0
private var sharedPasteboardTimer: Timer?

private func get_objectFromUserdata<T: AnyObject>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: String) -> T? {
    guard let ptr = luaL_checkudata(L, idx, tag) else { return nil }
    return Unmanaged<T>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeUnretainedValue()
}

private func get_objectFromUserdata_transfer<T: AnyObject>(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ tag: String) -> T? {
    guard let ptr = luaL_checkudata(L, idx, tag) else { return nil }
    return Unmanaged<T>.fromOpaque(ptr.load(as: UnsafeRawPointer.self)).takeRetainedValue()
}

class HSPasteboardTimer: NSObject {
    var t: Timer?
    var pbName: String?
    var fnRef: Int32 = LUA_NOREF
    var changeCount: Int = 0
    var isRunning: Bool = false

    @objc func sharedPasteboardTimerCallback(_ timer: Timer) {
        NotificationCenter.default.post(
            name: NSNotification.Name("sharedPasteboardNotification"),
            object: nil
        )
    }

    @objc func sharedPasteboardChanged(_ notification: Notification) {
        // Get the correct Pasteboard:
        let pb: NSPasteboard
        if let name = pbName {
            pb = NSPasteboard(name: NSPasteboard.Name(rawValue: name))
        } else {
            pb = NSPasteboard.general
        }

        // Check if the Pasteboard Change Count has changed:
        let currentChangeCount = pb.changeCount
        if currentChangeCount == changeCount {
            return
        }

        // Update change count:
        changeCount = currentChangeCount

        // Trigger Lua Callback Function:
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!

        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fnRef))

        let result = pb.string(forType: .string)
        if let result = result {
            lua_pushany(L, result)
        } else {
            lua_pushnil(L)
        }

        if lua_pcall(L, 1, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
    }

    func start() {
        // Abort if the watcher is already running:
        if isRunning {
            return
        }

        // If the Shared Pasteboard Timer doesn't exist, create it:
        if sharedPasteboardTimer == nil || !sharedPasteboardTimer!.isValid {
            sharedPasteboardTimer = Timer(
                timeInterval: pollingInterval,
                target: self,
                selector: #selector(sharedPasteboardTimerCallback(_:)),
                userInfo: nil,
                repeats: true
            )
        }

        // Update Initial Change Count:
        let pb: NSPasteboard
        if let name = pbName {
            pb = NSPasteboard(name: NSPasteboard.Name(rawValue: name))
        } else {
            pb = NSPasteboard.general
        }
        changeCount = pb.changeCount

        // Start the Shared Pasteboard NSTimer if it's not already running:
        if let timer = sharedPasteboardTimer,
           !CFRunLoopContainsTimer(CFRunLoopGetCurrent(), timer as CFRunLoopTimer, CFRunLoopMode.defaultMode) {
            RunLoop.current.add(timer, forMode: .common)
        }

        // Increment the General Pasteboard Timer Counter:
        sharedPasteboardTimerCount += 1

        // Add observer:
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sharedPasteboardChanged(_:)),
            name: NSNotification.Name("sharedPasteboardNotification"),
            object: nil
        )

        // The watcher is now running:
        isRunning = true
    }

    func stop() {
        // Remove observer:
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name("sharedPasteboardNotification"),
            object: nil
        )

        // Decrement the Shared Pasteboard Timer Counter:
        sharedPasteboardTimerCount -= 1

        // If no more watchers are left, destroy the NSTimer:
        if sharedPasteboardTimerCount == 0 {
            sharedPasteboardTimer?.invalidate()
            sharedPasteboardTimer = nil
        }

        // Watcher is no longer running:
        isRunning = false
    }
}

/// hs.pasteboard.watcher.new(callbackFn[, name]) -> pasteboardWatcher
/// Constructor
/// Creates and starts a new `hs.pasteboard.watcher` object for watching for Pasteboard changes.
///
/// Parameters:
///  * callbackFn - A function that will be called when the Pasteboard contents has changed. It should accept one parameter:
///   * A string containing the pasteboard contents or `nil` if the contents is not a valid string.
///  * name - An optional string containing the name of the pasteboard. Defaults to the system pasteboard.
///
/// Returns:
///  * An `hs.pasteboard.watcher` object
///
/// Notes:
///  * Internally this extension uses a single `NSTimer` to check for changes to the pasteboard count every half a second.
///  * Example usage:
///  ```lua
///  generalPBWatcher = hs.pasteboard.watcher.new(function(v) print(string.format("General Pasteboard Contents: %s", v)) end)
///  specialPBWatcher = hs.pasteboard.watcher.new(function(v) print(string.format("Special Pasteboard Contents: %s", v)) end, "special")
///  hs.pasteboard.writeObjects("This is on the general pasteboard.")
///  hs.pasteboard.writeObjects("This is on the special pasteboard.", "special")```
private func pasteboardwatcher_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let pbName: String? = (lua_type(L, 2) == LUA_TSTRING) ? String(cString: lua_tostring(L, 2)!) : nil

    lua_pushvalue(L, 1)
    let callbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Create the timer object:
    let timer = HSPasteboardTimer()
    timer.fnRef = callbackRef
    timer.pbName = pbName

    // Start the timer:
    timer.start()

    // Wire up the timer object to Lua:
    let userData = lua_newuserdata(L, MemoryLayout<UnsafeRawPointer>.size)!
    let unmanaged = Unmanaged.passRetained(timer)
    userData.storeBytes(of: unmanaged.toOpaque(), as: UnsafeRawPointer.self)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.pasteboard.watcher:start() -> timer
/// Method
/// Starts an `hs.pasteboard.watcher` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.pasteboard.watcher` object
private func pasteboardwatcher_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer: HSPasteboardTimer? = get_objectFromUserdata(L, 1, USERDATA_TAG)
    lua_settop(L, 1)

    // Start the timer:
    timer?.start()

    return 1
}

/// hs.pasteboard.watcher:running() -> boolean
/// Method
/// Returns a boolean indicating whether or not the Pasteboard Watcher is currently running.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A boolean value indicating whether or not the timer is currently running.
private func pasteboardwatcher_running(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer: HSPasteboardTimer? = get_objectFromUserdata(L, 1, USERDATA_TAG)

    lua_pushboolean(L, (timer?.isRunning ?? false) ? 1 : 0)

    return 1
}

/// hs.pasteboard.watcher:stop() -> timer
/// Method
/// Stops an `hs.pasteboard.watcher` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.pasteboard.watcher` object
private func pasteboardwatcher_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer: HSPasteboardTimer? = get_objectFromUserdata(L, 1, USERDATA_TAG)
    lua_settop(L, 1)

    // Stop the timer:
    timer?.stop()

    return 1
}

/// hs.pasteboard.watcher.interval([value]) -> number
/// Function
/// Gets or sets the polling interval (i.e. the frequency the pasteboard watcher checks the pasteboard).
///
/// Parameters:
///  * value - an optional number to set the polling interval to.
///
/// Returns:
///  * The polling interval as a number.
///
/// Notes:
///  * This only affects new watchers, not existing/running ones.
///  * The default value is 0.25.
private func pasteboardwatcher_interval(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if lua_gettop(L) == 1 && lua_type(L, 1) == LUA_TNUMBER {
        pollingInterval = lua_tonumber(L, 1)
    }
    lua_pushnumber(L, pollingInterval)
    return 1
}

private func pasteboardwatcher_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer: HSPasteboardTimer? = get_objectFromUserdata_transfer(L, 1, USERDATA_TAG)

    if let timer = timer {
        timer.stop()
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, timer.fnRef)
        timer.fnRef = LUA_NOREF
        timer.t = nil
        timer.pbName = nil
    }

    // Remove the Metatable so future use of the variable in Lua won't think its valid
    lua_pushnil(L)
    lua_setmetatable(L, 1)

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if let timer = sharedPasteboardTimer {
        timer.invalidate()
        sharedPasteboardTimer = nil
    }
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let timer: HSPasteboardTimer? = get_objectFromUserdata(L, 1, USERDATA_TAG)

    let title: String
    if timer?.isRunning ?? false {
        title = "running"
    } else {
        title = "not running"
    }

    let str = "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))"
    lua_pushstring(L, str)
    return 1
}

// Metatable for created objects when _new invoked
private let pasteboardWatcher_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: { L in pasteboardwatcher_start(L) }),
    luaL_Reg(name: strdup("stop"),       func: { L in pasteboardwatcher_stop(L) }),
    luaL_Reg(name: strdup("running"),    func: { L in pasteboardwatcher_running(L) }),
    luaL_Reg(name: strdup("__tostring"), func: { L in userdata_tostring(L) }),
    luaL_Reg(name: strdup("__gc"),       func: { L in pasteboardwatcher_gc(L) }),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private let pasteboardWatcher_lib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"),      func: { L in pasteboardwatcher_new(L) }),
    luaL_Reg(name: strdup("interval"), func: { L in pasteboardwatcher_interval(L) }),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for returned object when module loads
private let meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: { L in meta_gc(L) }),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libpasteboardwatcher")
public func luaopen_hs_libpasteboardwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")  // mt.__index = mt
    luaL_setfuncs(L, pasteboardWatcher_metalib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(pasteboardWatcher_lib.count - 1))
    luaL_setfuncs(L, pasteboardWatcher_lib, 0)

    // Set module metatable for __gc
    lua_createtable(L, 0, 1)
    luaL_setfuncs(L, meta_gcLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
