import Cocoa
import CLua
import Lua
import HSDSTCore

/// === hs.pasteboard.watcher ===
///
/// Watch for Pasteboard Changes.
/// macOS doesn't offer any API for getting Pasteboard notifications, so this extension uses polling to check for Pasteboard changes at a chosen interval (defaults to 0.25).

private let USERDATA_TAG = "hs.pasteboard.watcher"

// How often we should poll the Pasteboard for changes:
private var pollingInterval: Double = 0.25

class HSPasteboardTimer: NSObject, LuaTeardownable {
    var pbName: String?
    var callback: LuaValue?
    var changeCount: Int = 0
    var isRunning: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false
    var timerHandle: (any TimerHandle)?
    var pasteboard: (any PasteboardProtocol)?
    var clock: (any ClockProtocol)?

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if isRunning {
            stop()
        }
        callback = nil
        timerHandle = nil
        pbName = nil
        pasteboard = nil
        clock = nil
    }

    func pollPasteboard() {
        guard lua_isStateGenerationValid(generation) else { return }

        // Check if the Pasteboard Change Count has changed:
        let currentChangeCount: Int
        if pbName != nil, let pb = namedPasteboard() {
            currentChangeCount = pb.changeCount
        } else if let pb = pasteboard {
            currentChangeCount = pb.changeCount
        } else {
            return
        }

        if currentChangeCount == changeCount {
            return
        }

        // Update change count:
        changeCount = currentChangeCount

        // Trigger Lua Callback Function:
        if let cb = callback {
            let L = lua_getCurrentState()!

            cb.push(onto: L)

            let result: String?
            if pbName != nil, let pb = namedPasteboard() {
                result = pb.string(forType: .string)
            } else {
                result = pasteboard?.string(forType: NSPasteboard.PasteboardType.string.rawValue)
            }
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

        guard let clock = clock else { return }

        // Update Initial Change Count:
        if pbName != nil, let pb = namedPasteboard() {
            changeCount = pb.changeCount
        } else if let pb = pasteboard {
            changeCount = pb.changeCount
        }

        // Create a timer using the clock protocol:
        timerHandle = clock.createTimer(interval: pollingInterval, repeats: true) { [weak self] in
            self?.pollPasteboard()
        }
        timerHandle?.schedule()

        // The watcher is now running:
        isRunning = true
    }

    func stop() {
        // Invalidate the timer:
        timerHandle?.invalidate()
        timerHandle = nil

        // Watcher is no longer running:
        isRunning = false
    }

    // Helper for named pasteboards (not covered by the protocol):
    private func namedPasteboard() -> NSPasteboard? {
        guard let name = pbName else { return nil }
        return NSPasteboard(name: NSPasteboard.Name(rawValue: name))
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

            let env = environmentGet(L)
            let timer = HSPasteboardTimer()
            timer.callback = L.ref(index: 1)
            timer.generation = lua_currentStateGeneration()
            timer.pbName = pbName
            timer.pasteboard = env.pasteboard
            timer.clock = env.clock

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

        // Set module metatable for __gc
        lua_createtable(L, 0, 1)
        lua_pushcclosure(L, { (_: LuaState!) -> CInt in
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
