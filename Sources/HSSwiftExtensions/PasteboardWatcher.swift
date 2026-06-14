import Cocoa
import CLua
import Lua

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

class HSPasteboardTimer: NSObject, LuaTeardownable {
    var t: Timer?
    var pbName: String?
    var callback: LuaValue?
    var changeCount: Int = 0
    var isRunning: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if isRunning {
            stop()
        }
        callback = nil
        t = nil
        pbName = nil
    }

    @objc func sharedPasteboardTimerCallback(_ timer: Timer) {
        NotificationCenter.default.post(
            name: NSNotification.Name("sharedPasteboardNotification"),
            object: nil
        )
    }

    @objc func sharedPasteboardChanged(_ notification: Notification) {
        guard lua_isStateGenerationValid(generation) else { return }
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
        if let cb = callback {
            let L = lua_getCurrentState()!

            cb.push(onto: L)

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

// MARK: - Module entry point

@_cdecl("luaopen_hs_libpasteboardwatcher")
public func luaopen_hs_libpasteboardwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        L.register(Metatable<HSPasteboardTimer>(
            fields: [
                "start": .closure { L in
                    let timer: HSPasteboardTimer = try L.checkArgument(1)
                    lua_settop(L, 1)
                    timer.start()
                    return 1
                },
                "stop": .closure { L in
                    let timer: HSPasteboardTimer = try L.checkArgument(1)
                    lua_settop(L, 1)
                    timer.stop()
                    return 1
                },
                "running": .closure { L in
                    let timer: HSPasteboardTimer = try L.checkArgument(1)
                    L.push(timer.isRunning)
                    return 1
                },
            ],
            tostring: .closure { L in
                let timer: HSPasteboardTimer = try L.checkArgument(1)
                let title = timer.isRunning ? "running" : "not running"
                let str = "\(USERDATA_TAG): \(title) (\(lua_topointer(L, 1)!))"
                L.push(str)
                return 1
            }
        ))
        installMetatableBoilerplate(L, for: HSPasteboardTimer.self, tag: USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 2)

        // new constructor
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checktype(L, 1, LUA_TFUNCTION)
            let pbName: String? = (lua_type(L, 2) == LUA_TSTRING) ? String(cString: lua_tostring(L, 2)!) : nil

            let timer = HSPasteboardTimer()
            timer.callback = L.ref(index: 1)
            timer.generation = lua_currentStateGeneration()
            timer.pbName = pbName

            // Start the timer:
            timer.start()

            L.push(userdata: timer)
            return 1
        })
        lua_setfield(L, -2, "new")

        // interval function
        L.push({ (L: LuaState) throws -> CInt in
            if lua_gettop(L) == 1 && lua_type(L, 1) == LUA_TNUMBER {
                pollingInterval = lua_tonumber(L, 1)
            }
            L.push(pollingInterval)
            return 1
        })
        lua_setfield(L, -2, "interval")

        // Set module metatable for __gc (shared timer cleanup)
        lua_createtable(L, 0, 1)
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            if let timer = sharedPasteboardTimer {
                timer.invalidate()
                sharedPasteboardTimer = nil
            }
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
