import Cocoa
import CLua
import Lua
import Foundation
import HSDSTCore
import os.log

private let USERDATA_TAG = "hs.task"

// TigerStyle bounds: maximum process output size (100 MB)
private let kMaxProcessOutputSize = 104_857_600

// MARK: - HSTask class

private class HSTask: NSObject {
    var handle: (any ProcessHandle)?
    var processProvider: (any ProcessProtocol)?
    var isStream: Bool = false
    var hasStarted: Bool = false
    var hasTerminated: Bool = false
    var luaCallback: LuaValue?
    var luaStreamCallback: LuaValue?
    var launchPath: String = ""
    var arguments: [String] = []
    var inputData: Data?
    var selfRef: LuaValue?
    var generation: UInt64 = 0
    var customEnvironment: [String: String]?
    var workingDirectory: String?
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let h = handle, h.isRunning {
            h.terminate()
        }
        handle = nil
        processProvider = nil
        luaCallback = nil
        luaStreamCallback = nil
        selfRef = nil
        inputData = nil
        assert(handle == nil, "handle must be nil after teardown")
        assert(luaCallback == nil, "luaCallback must be nil after teardown")
        assert(selfRef == nil, "selfRef must be nil after teardown")
    }
}

private var activeTasks: [HSTask] = []
private var fileReadObserver: (any NotificationObserverToken)?
private weak var fileReadNotificationRef: (any NotificationProtocol)?

// MARK: - Lua functions

/// hs.task.new(launchPath, callbackFn[, streamCallbackFn][, arguments]) -> hs.task object
/// Function
/// Creates a new hs.task object
///
/// Parameters:
///  * launchPath - A string containing the path to an executable file.  This must be the full path to an executable and not just an executable which is in your environment's path (e.g. `/bin/ls` rather than just `ls`).
///  * callbackFn - A callback function to be called when the task terminates, or nil if no callback should be called. The function should accept three arguments:
///   * exitCode - An integer containing the exit code of the process
///   * stdOut - A string containing the standard output of the process
///   * stdErr - A string containing the standard error output of the process
///  * streamCallbackFn - A optional callback function to be called whenever the task outputs data to stdout or stderr. The function must return a boolean value - true to continue calling the streaming callback, false to stop calling it. The function should accept three arguments:
///   * task - The hs.task object or nil if this is the final output of the completed task.
///   * stdOut - A string containing the standard output received since the last call to this callback
///   * stdErr - A string containing the standard error output received since the last call to this callback
///  * arguments - An optional table of command line argument strings for the executable
///
/// Returns:
///  * An `hs.task` object or nil if an error occurred
///
/// Notes:
///  * The arguments are not processed via a shell, so you do not need to do any quoting or escaping. They are passed to the executable exactly as provided.
///  * When using a stream callback, the callback may be invoked one last time after the termination callback has already been invoked. In this case, the `task` argument to the stream callback will be `nil` rather than the task userdata object and the return value of the stream callback will be ignored.
private func task_new(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    luaL_checktype(L, 1, LUA_TSTRING)

    let task = HSTask()
    task.generation = lua_currentStateGeneration()
    task.processProvider = environmentGet(L).process

    // Capture callback
    if lua_type(L, 2) == LUA_TFUNCTION {
        task.luaCallback = L.ref(index: 2)
    }

    // Capture stream callback
    if lua_type(L, 3) == LUA_TFUNCTION {
        task.luaStreamCallback = L.ref(index: 3)
        task.isStream = true
    }

    task.hasStarted = false
    task.hasTerminated = false
    task.launchPath = String(cString: lua_tostring(L, 1)!)
    task.inputData = nil

    // Build arguments array from Lua table
    let argsIdx: Int32 = lua_type(L, 3) == LUA_TTABLE ? 3 : (lua_type(L, 4) == LUA_TTABLE ? 4 : 0)
    if argsIdx > 0 {
        var args: [String] = []
        lua_pushnil(L)
        while lua_next(L, argsIdx) != 0 {
            if lua_type(L, -1) != LUA_TSTRING {
                throw LuaCallError("All arguments for hs.task.new must be strings")
            }
            args.append(String(cString: lua_tostring(L, -1)!))
            lua_pop(L, 1)
        }
        task.arguments = args
    }

    // Push userdata onto stack
    L.push(userdata: task)

    // Track the task
    activeTasks.append(task)

    assert(!task.hasStarted, "newly created task must not be marked as started")
    assert(!task.hasTerminated, "newly created task must not be marked as terminated")
    return 1
}

private func task_metagc(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    activeTasks.removeAll()
    if let observer = fileReadObserver {
        fileReadNotificationRef?.removeObserver(observer)
        fileReadObserver = nil
    }
    assert(activeTasks.isEmpty, "activeTasks must be empty after module gc")
    assert(fileReadObserver == nil, "fileReadObserver must be nil after module gc")
    return 0
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libtask")
public func luaopen_hs_libtask(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register idiomatic Metatable<HSTask> with LuaSwift
        L.register(Metatable<HSTask>(
            fields: [
                "environment": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if let env = task.handle?.environment ?? task.customEnvironment {
                        lua_pushany(L, env as NSDictionary)
                    } else {
                        lua_pushany(L, ProcessInfo.processInfo.environment as NSDictionary)
                    }
                    return 1
                },
                "setEnvironment": .closure { L in
                    luaL_checktype(L, 2, LUA_TTABLE)
                    let task: HSTask = try L.checkArgument(1)
                    if let env = lua_tovalue(L, at: 2) as? [String: String] {
                        if task.hasStarted {
                            // Cannot change environment after start
                            os_log(.info, "hs.task:setEnvironment() Unable to set environment after start")
                            L.push(false)
                        } else {
                            task.customEnvironment = env
                            if let handle = task.handle {
                                handle.environment = env
                            }
                            lua_pushvalue(L, 1)
                        }
                    } else {
                        os_log(.info, "hs.task:setEnvironment() Unable to set environment")
                        L.push(false)
                    }
                    return 1
                },
                "pid": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    guard let handle = task.handle else {
                        L.push(0 as lua_Integer)
                        return 1
                    }
                    L.push(lua_Integer(handle.processIdentifier))
                    return 1
                },
                "start": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    guard !task.hasStarted else {
                        L.push(false)
                        return 1
                    }
                    guard let provider = task.processProvider else {
                        L.push(false)
                        return 1
                    }

                    // Create self-reference now to prevent GC during execution
                    if task.selfRef == nil {
                        lua_pushvalue(L, 1)
                        task.selfRef = L.ref(index: -1)
                        lua_pop(L, 1)
                    }

                    task.hasStarted = true

                    if task.isStream {
                        // Streaming mode: use streamingRun
                        let handle = provider.streamingRun(
                            executablePath: task.launchPath,
                            arguments: task.arguments,
                            environment: task.customEnvironment,
                            currentDirectory: task.workingDirectory,
                            onStdout: { [weak task] data in
                                guard let task = task else { return }
                                guard lua_isStateGenerationValid(task.generation) else {
                                    task.teardown()
                                    return
                                }
                                guard let streamCb = task.luaStreamCallback else { return }
                                let _L = lua_getCurrentState()!
                                let dataString = String(data: data, encoding: .utf8) ?? ""
                                let notLastGasp = (task.selfRef != nil)
                                streamCb.push(onto: _L)
                                if notLastGasp {
                                    _L.push(userdata: task)
                                } else {
                                    lua_pushnil(_L)
                                }
                                _L.push(dataString)
                                _L.push("")
                                if lua_pcall(_L, 3, 1, 0) != LUA_OK {
                                    lua_pop(_L, 1)
                                } else {
                                    lua_pop(_L, 1) // pop result
                                }
                            },
                            onStderr: { [weak task] data in
                                guard let task = task else { return }
                                guard lua_isStateGenerationValid(task.generation) else {
                                    task.teardown()
                                    return
                                }
                                guard let streamCb = task.luaStreamCallback else { return }
                                let _L = lua_getCurrentState()!
                                let dataString = String(data: data, encoding: .utf8) ?? ""
                                let notLastGasp = (task.selfRef != nil)
                                streamCb.push(onto: _L)
                                if notLastGasp {
                                    _L.push(userdata: task)
                                } else {
                                    lua_pushnil(_L)
                                }
                                _L.push("")
                                _L.push(dataString)
                                if lua_pcall(_L, 3, 1, 0) != LUA_OK {
                                    lua_pop(_L, 1)
                                } else {
                                    lua_pop(_L, 1) // pop result
                                }
                            },
                            onExit: { [weak task] exitCode in
                                guard let task = task else { return }
                                guard lua_isStateGenerationValid(task.generation) else {
                                    task.teardown()
                                    return
                                }
                                task.hasTerminated = true
                                if let cb = task.luaCallback {
                                    let _L = lua_getCurrentState()!
                                    cb.push(onto: _L)
                                    _L.push(lua_Integer(exitCode))
                                    _L.push("")  // stdout already delivered via stream
                                    _L.push("")  // stderr already delivered via stream
                                    if lua_pcall(_L, 3, 0, 0) != LUA_OK { lua_pop(_L, 1) }
                                }
                                task.selfRef = nil
                            }
                        )
                        task.handle = handle

                        // Send initial input data if any
                        if let inputData = task.inputData {
                            task.inputData = nil
                            handle.writeToStdin(inputData)
                        }
                    } else {
                        // Non-streaming mode: use run with completion
                        let handle = provider.run(
                            executablePath: task.launchPath,
                            arguments: task.arguments,
                            environment: task.customEnvironment,
                            currentDirectory: task.workingDirectory
                        ) { [weak task] result in
                            guard let task = task else { return }
                            guard lua_isStateGenerationValid(task.generation) else {
                                task.teardown()
                                return
                            }
                            task.hasTerminated = true

                            if let cb = task.luaCallback {
                                let _L = lua_getCurrentState()!
                                cb.push(onto: _L)
                                _L.push(lua_Integer(result.exitCode))
                                let stdOutStr = String(data: result.stdout, encoding: .utf8) ?? ""
                                let stdErrStr = String(data: result.stderr, encoding: .utf8) ?? ""
                                _L.push(stdOutStr)
                                _L.push(stdErrStr)
                                if lua_pcall(_L, 3, 0, 0) != LUA_OK { lua_pop(_L, 1) }
                            }
                            task.selfRef = nil
                        }
                        task.handle = handle

                        // Send initial input data if any, then close stdin
                        // for non-streaming tasks
                        if let inputData = task.inputData {
                            task.inputData = nil
                            handle.writeToStdin(inputData)
                        }
                        if !task.isStream {
                            handle.closeStdin()
                        }
                    }

                    lua_pushvalue(L, 1)
                    return 1
                },
                "terminate": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.handle?.terminate()
                    lua_pushvalue(L, 1)
                    return 1
                },
                "interrupt": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.handle?.interrupt()
                    lua_pushvalue(L, 1)
                    return 1
                },
                "pause": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    let result = task.handle?.suspend() ?? false
                    if result {
                        lua_pushvalue(L, 1)
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "resume": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    let result = task.handle?.resume() ?? false
                    if result {
                        lua_pushvalue(L, 1)
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "terminationStatus": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if task.hasTerminated, let handle = task.handle {
                        L.push(lua_Integer(handle.terminationStatus))
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "terminationReason": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if task.hasTerminated, let handle = task.handle {
                        switch handle.terminationReason {
                        case .exit:
                            L.push("exit")
                        case .uncaughtSignal:
                            L.push("interrupt")
                        }
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "isRunning": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    L.push(task.hasStarted && !task.hasTerminated)
                    return 1
                },
                "setWorkingDirectory": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    let thePath = String(cString: luaL_checkstring(L, 2))
                    task.workingDirectory = thePath
                    if let handle = task.handle {
                        handle.currentDirectoryPath = thePath
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
                "workingDirectory": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if let dir = task.handle?.currentDirectoryPath ?? task.workingDirectory {
                        L.push(dir)
                    } else {
                        lua_pushnil(L)
                    }
                    return 1
                },
                "setCallback": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.luaCallback = nil
                    if lua_type(L, 2) == LUA_TFUNCTION {
                        task.luaCallback = L.ref(index: 2)
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
                "setStreamingCallback": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.luaStreamCallback = nil
                    if lua_type(L, 2) == LUA_TFUNCTION {
                        task.luaStreamCallback = L.ref(index: 2)
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
                "setInput": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if !task.hasTerminated {
                        _ = luaL_checkstring(L, 2)
                        let inputStr = String(cString: lua_tostring(L, 2)!)
                        let data = inputStr.data(using: .utf8)!
                        if let handle = task.handle {
                            // Process is running, write directly
                            handle.writeToStdin(data)
                        } else {
                            // Not started yet, buffer
                            task.inputData = data
                        }
                    } else {
                        os_log(.info, "hs.task:setInput() called on a task that has already terminated")
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
                "closeInput": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.handle?.closeStdin()
                    lua_pushvalue(L, 1)
                    return 1
                },
                "waitUntilExit": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.handle?.waitUntilExit()
                    // After waitUntilExit, sync our state
                    if let handle = task.handle, handle.hasTerminated {
                        task.hasTerminated = true
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
            ],
            tostring: .closure { L in
                let task: HSTask = try L.checkArgument(1)
                let args = task.arguments.joined(separator: " ")
                L.push("hs.task: \(task.launchPath) \(args) (\(lua_topointer(L, 1)!))")
                return 1
            }
        ))

        // -- Post-registration metatable patching --
        L.pushMetatable(for: HSTask.self)

        // Replace __gc with our explicit teardown + deinitialize
        L.push({ (L: LuaState!) -> CInt in
            if let task: HSTask = L.touserdata(1) {
                // Remove from active tasks tracking
                if let idx = activeTasks.firstIndex(where: { $0 === task }) {
                    activeTasks.remove(at: idx)
                }
                task.teardown()
            }
            // Deinitialize the Any box (same as LuaSwift's gcUserdata)
            let rawptr = lua_touserdata(L, 1)!
            let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
            anyPtr.deinitialize(count: 1)
            return 0
        })
        lua_setfield(L, -2, "__gc")

        // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the legacy registry name so that
        // core_getObjectMetatable("hs.task") still resolves.
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(task_new)
        lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(task_metagc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)

        activeTasks = []
    }
}
