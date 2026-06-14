import Cocoa
import CLua
import Lua
import Foundation
import os.log

private let USERDATA_TAG = "hs.task"

// TigerStyle bounds: maximum process output size (100 MB)
private let kMaxProcessOutputSize = 104_857_600

// MARK: - HSTask class

private class HSTask: NSObject {
    var process: Process?
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
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let task = process, task.isRunning {
            task.terminationHandler = nil
            task.terminate()
        }
        process = nil
        luaCallback = nil
        luaStreamCallback = nil
        selfRef = nil
        inputData = nil
        assert(process == nil, "process must be nil after teardown")
        assert(luaCallback == nil, "luaCallback must be nil after teardown")
        assert(selfRef == nil, "selfRef must be nil after teardown")
    }
}

private var activeTasks: [HSTask] = []
private var fileReadObserver: Any?

// MARK: - Helper functions

private func findTask(for fileHandle: FileHandle) -> HSTask? {
    activeTasks.first { task in
        guard let process = task.process else { return false }
        let stdOutFH = (process.standardOutput as? Pipe)?.fileHandleForReading
        let stdErrFH = (process.standardError as? Pipe)?.fileHandleForReading
        let stdInFH = (process.standardInput as? Pipe)?.fileHandleForWriting
        return stdOutFH === fileHandle || stdErrFH === fileHandle || stdInFH === fileHandle
    }
}

private let writerBlock: (FileHandle) -> Void = { stdInFH in
    DispatchQueue.main.sync {
        // Immediately prevent being called again
        stdInFH.writeabilityHandler = nil

        guard let task = findTask(for: stdInFH) else {
            os_log(.info, "ERROR: Unable to get task in writerBlock")
            return
        }

        guard let inputData = task.inputData else {
            os_log(.info, "ERROR: in writerBlock without any data to write")
            return
        }

        task.inputData = nil

        do {
            try stdInFH.write(contentsOf: inputData)
        } catch {
            os_log(.info, "Exception while writing to hs.task handle")
        }

        // If we're not a streaming task, we can close the file handle now
        if !task.isStream {
            stdInFH.closeFile()
        }
    }
}

private func create_task(_ task: HSTask) {
    precondition(!task.launchPath.isEmpty, "launchPath must not be empty")
    precondition(!task.hasStarted, "cannot create_task for an already-started task")
    let process = Process()
    let stdOut = Pipe()
    let stdErr = Pipe()
    let stdIn = Pipe()

    task.process = process
    process.standardOutput = stdOut
    process.standardError = stdErr
    process.standardInput = stdIn

    process.launchPath = task.launchPath
    process.arguments = task.arguments
    process.terminationHandler = { [weak task] terminatedProcess in
        // Ensure this callback happens on the main thread
        DispatchQueue.main.sync {
            guard let task = task else { return }
            guard lua_isStateGenerationValid(task.generation) else {
                task.teardown()
                return
            }

            let L = lua_getCurrentState()!

            let stdOutFH = (terminatedProcess.standardOutput as? Pipe)?.fileHandleForReading
            let stdErrFH = (terminatedProcess.standardError as? Pipe)?.fileHandleForReading
            let stdInFH = (terminatedProcess.standardInput as? Pipe)?.fileHandleForWriting

            var stdOutStr: String?
            var stdErrStr: String?

            // TigerStyle: read process output in bounded chunks to prevent unbounded memory growth
            func readBounded(_ fh: FileHandle?) -> Data {
                guard let fh = fh else { return Data() }
                var accumulated = Data()
                let chunkSize = 65_536
                while true {
                    let chunk = fh.readData(ofLength: chunkSize)
                    if chunk.isEmpty { break }
                    accumulated.append(chunk)
                    if accumulated.count > kMaxProcessOutputSize {
                        os_log(.error, "hs.task: process output exceeded kMaxProcessOutputSize (%d bytes), truncating", kMaxProcessOutputSize)
                        break
                    }
                }
                return accumulated
            }
            stdOutStr = String(data: readBounded(stdOutFH), encoding: .utf8)
            stdErrStr = String(data: readBounded(stdErrFH), encoding: .utf8)
            stdOutFH?.closeFile()
            stdErrFH?.closeFile()

            task.hasTerminated = true

            // We only need to close stdin on streaming tasks
            if task.isStream {
                stdInFH?.closeFile()
            }

            if let cb = task.luaCallback {
                cb.push(onto: L)
                L.push(lua_Integer(terminatedProcess.terminationStatus))
                if let s = stdOutStr { L.push(s) } else { lua_pushnil(L) }
                if let s = stdErrStr { L.push(s) } else { lua_pushnil(L) }
                if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
            }

            // Release self-reference, allowing GC
            task.selfRef = nil
        }
    }
}

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

    // Create and populate the Process object
    create_task(task)

    // Push userdata onto stack
    L.push(userdata: task)

    // Track the task (selfRef is created later in :start() to avoid
    // leaking never-started tasks)
    activeTasks.append(task)

    assert(task.process != nil, "task.process must be set after create_task")
    assert(!task.hasStarted, "newly created task must not be marked as started")
    assert(!task.hasTerminated, "newly created task must not be marked as terminated")
    return 1
}

private func task_metagc(_ L: LuaState) throws -> CInt {
    precondition(L != nil, "Lua state must not be nil")
    activeTasks.removeAll()
    if let observer = fileReadObserver {
        NotificationCenter.default.removeObserver(observer)
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
                    if let process = task.process, let env = process.environment {
                        lua_pushany(L, env as NSDictionary)
                    } else {
                        lua_pushany(L, ProcessInfo.processInfo.environment as NSDictionary)
                    }
                    return 1
                },
                "setEnvironment": .closure { L in
                    luaL_checktype(L, 2, LUA_TTABLE)
                    let task: HSTask = try L.checkArgument(1)
                    if let process = task.process, let env = lua_tovalue(L, at: 2) as? [String: String] {
                        process.environment = env
                        lua_pushvalue(L, 1)
                    } else {
                        os_log(.info, "hs.task:setEnvironment() Unable to set environment")
                        L.push(false)
                    }
                    return 1
                },
                "pid": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    guard let process = task.process else {
                        L.push(0 as lua_Integer)
                        return 1
                    }
                    L.push(lua_Integer(process.processIdentifier))
                    return 1
                },
                "start": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    var result = false
                    do {
                        guard let process = task.process else {
                            L.push(false)
                            return 1
                        }
                        let stdIn = process.standardInput as! Pipe
                        let stdInFH = stdIn.fileHandleForWriting
                        if !task.isStream && task.inputData == nil {
                            stdInFH.closeFile()
                        }
                        try process.run()
                        result = true
                        task.hasStarted = true
                        // Create self-reference now that the task is running,
                        // preventing GC until termination releases it.
                        if task.selfRef == nil {
                            lua_pushvalue(L, 1)
                            task.selfRef = L.ref(index: -1)
                            lua_pop(L, 1)
                        }
                        if task.isStream {
                            let stdOut = process.standardOutput as! Pipe
                            let stdErr = process.standardError as! Pipe
                            stdOut.fileHandleForReading.readInBackgroundAndNotify()
                            stdErr.fileHandleForReading.readInBackgroundAndNotify()
                        }
                    } catch {
                        os_log(.info, "hs.task:launch() Unable to launch hs.task process: %{public}s", "\(error)")
                    }
                    if result {
                        lua_pushvalue(L, 1)
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "terminate": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.process?.terminate()
                    lua_pushvalue(L, 1)
                    return 1
                },
                "interrupt": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.process?.interrupt()
                    lua_pushvalue(L, 1)
                    return 1
                },
                "pause": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    let result = task.process?.suspend() ?? false
                    if result {
                        lua_pushvalue(L, 1)
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "resume": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    let result = task.process?.resume() ?? false
                    if result {
                        lua_pushvalue(L, 1)
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "terminationStatus": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if task.hasTerminated, let process = task.process {
                        L.push(lua_Integer(process.terminationStatus))
                    } else {
                        L.push(false)
                    }
                    return 1
                },
                "terminationReason": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if task.hasTerminated, let process = task.process {
                        switch process.terminationReason {
                        case .exit:
                            L.push("exit")
                        case .uncaughtSignal:
                            L.push("interrupt")
                        @unknown default:
                            L.push("unknown")
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
                    guard let process = task.process else {
                        L.push(false)
                        return 1
                    }
                    let thePath = String(cString: luaL_checkstring(L, 2))
                    process.currentDirectoryPath = thePath
                    lua_pushvalue(L, 1)
                    return 1
                },
                "workingDirectory": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    guard let process = task.process else {
                        lua_pushnil(L)
                        return 1
                    }
                    L.push(process.currentDirectoryPath)
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
                        guard let process = task.process else {
                            lua_pushvalue(L, 1)
                            return 1
                        }
                        let stdIn = process.standardInput as! Pipe
                        let stdInFH = stdIn.fileHandleForWriting
                        _ = luaL_checkstring(L, 2)
                        let inputStr = String(cString: lua_tostring(L, 2)!)
                        task.inputData = inputStr.data(using: .utf8)
                        stdInFH.writeabilityHandler = writerBlock
                    } else {
                        os_log(.info, "hs.task:setInput() called on a task that has already terminated")
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
                "closeInput": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    if let process = task.process {
                        let stdIn = process.standardInput as! Pipe
                        stdIn.fileHandleForWriting.closeFile()
                    }
                    lua_pushvalue(L, 1)
                    return 1
                },
                "waitUntilExit": .closure { L in
                    let task: HSTask = try L.checkArgument(1)
                    task.process?.waitUntilExit()
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

        let nc = NotificationCenter.default
        fileReadObserver = nc.addObserver(forName: FileHandle.readCompletionNotification, object: nil, queue: nil) { note in
            guard let fh = note.object as? FileHandle,
                  let fhData = note.userInfo?[NSFileHandleNotificationDataItem] as? Data,
                  !fhData.isEmpty else {
                return
            }

            let dataString = String(data: fhData, encoding: .utf8)

            guard let task = findTask(for: fh) else {
                os_log(.info, "hs.task received output data from an unknown task. This may be a bug")
                return
            }

            guard lua_isStateGenerationValid(task.generation) else {
                task.teardown()
                return
            }

            if let streamCb = task.luaStreamCallback {
                let _L = lua_getCurrentState()!

                guard let process = task.process else { return }
                let stdOutFH = (process.standardOutput as? Pipe)?.fileHandleForReading
                let stdErrFH = (process.standardError as? Pipe)?.fileHandleForReading

                var stdOutArg: String = ""
                var stdErrArg: String = ""

                if fh === stdOutFH {
                    stdOutArg = dataString ?? ""
                } else if fh === stdErrFH {
                    stdErrArg = dataString ?? ""
                } else {
                    os_log(.error, "hs.task:setStreamingCallback() Received data from an unknown file handle")
                    return
                }

                let notLastGasp = (task.selfRef != nil)
                streamCb.push(onto: _L)
                if notLastGasp {
                    _L.push(userdata: task)
                } else {
                    lua_pushnil(_L)
                }
                _L.push(stdOutArg)
                _L.push(stdErrArg)

                if lua_pcall(_L, 3, 1, 0) != LUA_OK {
                    lua_pop(_L, 1)
                } else {
                    if lua_type(_L, -1) != LUA_TBOOLEAN {
                        os_log(.error, "hs.task:setStreamingCallback() callback did not return a boolean")
                    } else {
                        let continueStreaming = lua_toboolean(_L, -1) != 0

                        if continueStreaming && notLastGasp {
                            fh.readInBackgroundAndNotify()
                        }
                    }
                    lua_pop(_L, 1) // result
                }
            }
        }
    }
}
