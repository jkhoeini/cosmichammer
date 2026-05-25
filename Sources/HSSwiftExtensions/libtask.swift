import Cocoa
import Foundation
import LuaSkin

private let USERDATA_TAG = "hs.task"

private struct TaskUserdata {
    var nsTask: Unmanaged<NSObject>? // bridged NSTask/Process
    var isStream: Bool
    var hasStarted: Bool
    var hasTerminated: Bool
    var luaCallback: Int32
    var luaStreamCallback: Int32
    var launchPath: Unmanaged<NSString>?
    var arguments: Unmanaged<NSArray>?
    var inputData: Unmanaged<AnyObject>?
    var selfRef: Int32
}

private var refTable: LSRefTable = 0
private var tasks: NSMutableArray = NSMutableArray()
private var fileReadObserver: Any?

// MARK: - Helper functions

private func pointerArrayFromNSTask(_ task: Process) -> NSPointerArray? {
    for item in tasks {
        guard let pointerArray = item as? NSPointerArray else { continue }
        let storedTask = Unmanaged<Process>.fromOpaque(pointerArray.pointer(at: 0)!).takeUnretainedValue()
        if storedTask === task {
            return pointerArray
        }
    }
    return nil
}

private func userDataFromNSTask(_ task: Process) -> UnsafeMutablePointer<TaskUserdata>? {
    guard let pointerArray = pointerArrayFromNSTask(task) else { return nil }
    return pointerArray.pointer(at: 1)?.assumingMemoryBound(to: TaskUserdata.self)
}

private func userDataFromNSFileHandle(_ fh: FileHandle) -> UnsafeMutablePointer<TaskUserdata>? {
    for item in tasks {
        guard let pointerArray = item as? NSPointerArray else { continue }
        let task = Unmanaged<Process>.fromOpaque(pointerArray.pointer(at: 0)!).takeUnretainedValue()

        let stdOutFH = (task.standardOutput as? Pipe)?.fileHandleForReading
        let stdErrFH = (task.standardError as? Pipe)?.fileHandleForReading
        let stdInFH = (task.standardInput as? Pipe)?.fileHandleForWriting

        if stdOutFH === fh || stdErrFH === fh || stdInFH === fh {
            return pointerArray.pointer(at: 1)?.assumingMemoryBound(to: TaskUserdata.self)
        }
    }
    return nil
}

private let writerBlock: (FileHandle) -> Void = { stdInFH in
    DispatchQueue.main.sync {
        let skin = LuaSkin.skin(with: nil)

        // Immediately prevent being called again
        stdInFH.writeabilityHandler = nil

        guard let userData = userDataFromNSFileHandle(stdInFH) else {
            skin.logBreadcrumb("ERROR: Unable to get userData in writerBlock")
            return
        }

        guard let inputDataRef = userData.pointee.inputData else {
            skin.logBreadcrumb("ERROR: in writerBlock without any data to write")
            return
        }

        let inputData = inputDataRef.takeRetainedValue()
        userData.pointee.inputData = nil

        do {
            if let data = inputData as? Data {
                try stdInFH.write(contentsOf: data)
            } else if let str = inputData as? NSString {
                if let data = str.data(using: String.Encoding.utf8.rawValue) {
                    try stdInFH.write(contentsOf: data)
                }
            }
        } catch {
            skin.logWarn("Exception while writing to hs.task handle")
        }

        // If we're not a streaming task, we can close the file handle now
        if !userData.pointee.isStream {
            stdInFH.closeFile()
        }
    }
}

private func create_task(_ userData: UnsafeMutablePointer<TaskUserdata>) {
    let task = Process()
    let stdOut = Pipe()
    let stdErr = Pipe()
    let stdIn = Pipe()

    userData.pointee.nsTask = Unmanaged.passRetained(task as NSObject)
    task.standardOutput = stdOut
    task.standardError = stdErr
    task.standardInput = stdIn

    task.launchPath = userData.pointee.launchPath?.takeUnretainedValue() as String?
    task.arguments = userData.pointee.arguments?.takeUnretainedValue() as? [String]
    task.terminationHandler = { terminatedTask in
        // Ensure this callback happens on the main thread
        DispatchQueue.main.sync {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)

            let stdOutFH = (terminatedTask.standardOutput as? Pipe)?.fileHandleForReading
            let stdErrFH = (terminatedTask.standardError as? Pipe)?.fileHandleForReading
            let stdInFH = (terminatedTask.standardInput as? Pipe)?.fileHandleForWriting

            var stdOutStr: String?
            var stdErrStr: String?

            if let data = stdOutFH?.availableData ?? stdOutFH?.readDataToEndOfFile() {
                stdOutStr = String(data: data, encoding: .utf8)
            }
            // Re-read to end for full output
            stdOutStr = String(data: stdOutFH?.readDataToEndOfFile() ?? Data(), encoding: .utf8)
            stdErrStr = String(data: stdErrFH?.readDataToEndOfFile() ?? Data(), encoding: .utf8)
            stdOutFH?.closeFile()
            stdErrFH?.closeFile()

            guard let ud = userDataFromNSTask(terminatedTask) else {
                NSLog("NSTask terminationHandler called on a task we don't recognise. This was likely a stuck process, or one that didn't respond to SIGTERM, and we have already GC'd its objects. Ignoring")
                _lua_stackguard_exit(L)
                return
            }

            ud.pointee.hasTerminated = true

            // We only need to close stdin on streaming tasks
            if ud.pointee.isStream {
                stdInFH?.closeFile()
            }

            if ud.pointee.luaCallback != LUA_NOREF && ud.pointee.luaCallback != LUA_REFNIL {
                skin.pushLuaRef(refTable, ref: ud.pointee.luaCallback)
                lua_pushinteger(L, lua_Integer(terminatedTask.terminationStatus))
                skin.pushNSObject(stdOutStr as NSString?)
                skin.pushNSObject(stdErrStr as NSString?)
                skin.protectedCallAndError("hs.task callback", nargs: 3, nresults: 0)
            }
            ud.pointee.selfRef = skin.luaUnref(refTable, ref: ud.pointee.selfRef)
            _lua_stackguard_exit(L)
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
private func task_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TFUNCTION | LS_TNIL, LS_TTABLE | LS_TFUNCTION | LS_TOPTIONAL, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)

    // Create our Lua userdata object
    let userData = lua_newuserdata(L, MemoryLayout<TaskUserdata>.size)!.assumingMemoryBound(to: TaskUserdata.self)
    memset(userData, 0, MemoryLayout<TaskUserdata>.size)
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    lua_pushvalue(L, -1)
    userData.pointee.selfRef = skin.luaRef(refTable)

    // Capture callback
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        userData.pointee.luaCallback = skin.luaRef(refTable)
    } else {
        userData.pointee.luaCallback = LUA_REFNIL
    }

    // Capture stream callback
    if lua_type(L, 3) == LUA_TFUNCTION {
        lua_pushvalue(L, 3)
        userData.pointee.luaStreamCallback = skin.luaRef(refTable)
        userData.pointee.isStream = true
    } else {
        userData.pointee.luaStreamCallback = LUA_REFNIL
        userData.pointee.isStream = false
    }

    userData.pointee.hasStarted = false
    userData.pointee.hasTerminated = false
    userData.pointee.launchPath = Unmanaged.passRetained(skin.toNSObject(atIndex: 1) as! NSString)
    userData.pointee.inputData = nil

    var arguments: NSArray
    if lua_type(L, 3) == LUA_TTABLE {
        arguments = skin.toNSObject(atIndex: 3) as! NSArray
    } else if lua_type(L, 4) == LUA_TTABLE {
        arguments = skin.toNSObject(atIndex: 4) as! NSArray
    } else {
        arguments = NSArray()
    }

    // Ensure all arguments are strings
    for element in arguments {
        if !(element is NSString) {
            skin.logError("All arguments for hs.task.new must be strings")
            lua_pushnil(L)
            return 1
        }
    }

    userData.pointee.arguments = Unmanaged.passRetained(arguments)

    // Create and populate the NSTask object
    create_task(userData)

    // Keep a mapping between the NSTask object and its Lua wrapper
    let pointers = NSPointerArray(options: [.opaqueMemory, .opaquePersonality])
    pointers.addPointer(userData.pointee.nsTask?.toOpaque())
    pointers.addPointer(userData)
    tasks.add(pointers)

    return 1
}

/// hs.task:setCallback(fn) -> hs.task object
/// Method
/// Set or remove a callback function for a task.
///
/// Parameters:
///  * fn - A function to be called when the task completes or is terminated, or nil to remove an existing callback
///
/// Returns:
///  * the hs.task object
private func task_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)

    userData.pointee.luaCallback = skin.luaUnref(refTable, ref: userData.pointee.luaCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        userData.pointee.luaCallback = skin.luaRef(refTable)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.task:setInput(inputData) -> hs.task object
/// Method
/// Sets the standard input data for a task
///
/// Parameters:
///  * inputData - Data, in string form, to pass to the task as its standard input
///
/// Returns:
///  * The hs.task object
///
/// Notes:
///  * This method can be called before the task has been started, to prepare some input for it (particularly if it is not a streaming task)
///  * If this method is called multiple times, any input that has not been passed to the task already, is discarded (for streaming tasks, the data is generally consumed very quickly, but for now there is no way to synchronize this)
private func task_setInput(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNUMBER, LS_TBREAK)

    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)

    if !userData.pointee.hasTerminated {
        let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process
        let stdIn = task.standardInput as! Pipe
        let stdInFH = stdIn.fileHandleForWriting

        // Force numerical input to be rendered to a string
        _ = luaL_checkstring(L, 2)

        // Discard any previous input data
        if let oldRef = userData.pointee.inputData {
            let _ = oldRef.takeRetainedValue()
            userData.pointee.inputData = nil
        }

        // Store input data
        let inputObj = skin.toNSObject(atIndex: 2, withOptions: .nsPreserveLuaStringExactly) as AnyObject
        userData.pointee.inputData = Unmanaged.passRetained(inputObj)
        stdInFH.writeabilityHandler = writerBlock
    } else {
        skin.logWarn("hs.task:setInput() called on a task that has already terminated")
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.task:closeInput() -> hs.task object
/// Method
/// Closes the task's stdin
///
/// Parameters:
///  * None
///
/// Returns:
///  * The hs.task object
///
/// Notes:
///  * This should only be called on tasks with a streaming callback - tasks without it will automatically close stdin when any data supplied via `hs.task:setInput()` has been written
///  * This is primarily useful for sending EOF to long-running tasks
private func task_closeInput(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)

    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    let stdIn = task.standardInput as! Pipe
    let stdInFH = stdIn.fileHandleForWriting
    stdInFH.closeFile()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.task:setStreamingCallback(fn) -> hs.task object
/// Method
/// Set a stream callback function for a task
///
/// Parameters:
///  * fn - A function to be called when the task outputs to stdout or stderr, or nil to remove a callback
///
/// Returns:
///  * The hs.task object
///
/// Notes:
///  * For information about the requirements of the callback function, see `hs.task.new()`
///  * If a callback is removed without it previously having returned false, any further stdout/stderr output from the task will be silently discarded
private func task_setStreamingCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)

    userData.pointee.luaStreamCallback = skin.luaUnref(refTable, ref: userData.pointee.luaStreamCallback)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        userData.pointee.luaStreamCallback = skin.luaRef(refTable)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.task:workingDirectory() -> path
/// Method
/// Returns the working directory for the task.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the working directory for the task.
///
/// Notes:
///  * This only returns the directory that the task starts in.  If the task changes the directory itself, this value will not reflect that change.
private func task_getWorkingDirectory(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    skin.pushNSObject(task.currentDirectoryPath as NSString?)
    return 1
}

/// hs.task:setWorkingDirectory(path) -> hs.task object | false
/// Method
/// Sets the working directory for the task.
///
/// Parameters:
///  * path - a string containing the path you wish to be the working directory for the task.
///
/// Returns:
///  * The hs.task object, or false if the working directory was not set (usually because the task is already running or has completed)
///
/// Notes:
///  * You can only set the working directory if the task has not already been started.
///  * This will only set the directory that the task starts in.  The task itself can change the directory while it is running.
private func task_setWorkingDirectory(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process
    let thePath = skin.toNSObject(atIndex: 2) as! String

    task.currentDirectoryPath = thePath
    lua_pushvalue(L, 1)

    return 1
}

/// hs.task:pid() -> integer
/// Method
/// Gets the PID of a running/finished task
///
/// Parameters:
///  * None
///
/// Returns:
///  * An integer containing the PID of the task
///
/// Notes:
///  * The PID will still be returned if the task has already completed and the process terminated
private func task_getPID(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    lua_pushinteger(L, lua_Integer(task.processIdentifier))
    return 1
}

/// hs.task:start() -> hs.task object | false
/// Method
/// Starts the task
///
/// Parameters:
///  * None
///
/// Returns:
///  *  If the task was started successfully, returns the task object; otherwise returns false
///
/// Notes:
///  * If the task does not start successfully, the error message will be printed to the Cosmic Hammer Console
private func task_launch(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    var result = false

    do {
        let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process
        let stdIn = task.standardInput as! Pipe
        let stdInFH = stdIn.fileHandleForWriting

        if !userData.pointee.isStream && userData.pointee.inputData == nil {
            stdInFH.closeFile()
        }

        try task.run()
        result = true
        userData.pointee.hasStarted = true

        if userData.pointee.isStream {
            let stdOut = task.standardOutput as! Pipe
            let stdErr = task.standardError as! Pipe

            let stdOutFH = stdOut.fileHandleForReading
            let stdErrFH = stdErr.fileHandleForReading

            stdOutFH.readInBackgroundAndNotify()
            stdErrFH.readInBackgroundAndNotify()
        }
    } catch {
        skin.logWarn("hs.task:launch() Unable to launch hs.task process: \(error)")
    }

    if result {
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.task:terminate() -> hs.task object
/// Method
/// Terminates the task
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.task` object
///
/// Notes:
///  * This will send SIGTERM to the process
private func task_SIGTERM(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    task.terminate()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.task:interrupt() -> hs.task object
/// Method
/// Interrupts the task
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.task` object
///
/// Notes:
///  * This will send SIGINT to the process
private func task_SIGINT(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    task.interrupt()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.task:pause() -> boolean
/// Method
/// Pauses the task
///
/// Parameters:
///  * None
///
/// Returns:
///  *  If the task was paused successfully, returns the task object; otherwise returns false
///
/// Notes:
///  * If the task is not paused, the error message will be printed to the Cosmic Hammer Console
///  * This method can be called multiple times, but a matching number of `hs.task:resume()` calls will be required to allow the process to continue
private func task_pause(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process
    let result = task.suspend()

    if result {
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.task:resume() -> boolean
/// Method
/// Resumes the task
///
/// Parameters:
///  * None
///
/// Returns:
///  *  If the task was resumed successfully, returns the task object; otherwise returns false
///
/// Notes:
///  * If the task is not resumed successfully, the error message will be printed to the Cosmic Hammer Console
private func task_resumeTask(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process
    let result = task.resume()

    if result {
        lua_pushvalue(L, 1)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.task:waitUntilExit() -> hs.task object
/// Method
/// Blocks Cosmic Hammer until the task exits
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.task` object
///
/// Notes:
///  * All Lua and Cosmic Hammer activity will be blocked by this method. Its use is highly discouraged.
private func task_block(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    task.waitUntilExit()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.task:terminationStatus() -> exitCode | false
/// Method
/// Returns the termination status of a task, or false if the task is still running.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the numeric exitCode of the task, or the boolean false if the task has not yet exited (either because it has not yet been started or because it is still running).
private func task_terminationStatus(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    // Process.terminationStatus throws NSInvalidArgumentException if task hasn't exited
    // We need to catch this ObjC exception via a check
    if userData.pointee.hasTerminated {
        lua_pushinteger(L, lua_Integer(task.terminationStatus))
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.task:isRunning() -> boolean
/// Method
/// Test if a task is still running.
///
/// Parameters:
///  * None
///
/// Returns:
///  * true if the task is running or false if it is not.
///
/// Notes:
///  * A task which has not yet been started yet will also return false.
private func task_isRunning(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)

    if !userData.pointee.hasStarted {
        lua_pushboolean(L, 0)
    } else {
        lua_pushcfunction(L, { task_terminationStatus($0) })
        lua_pushvalue(L, 1)
        lua_call(L, 1, 1)
        lua_pushboolean(L, (lua_type(L, -1) == LUA_TNUMBER) ? 0 : 1)
        lua_remove(L, -2)
    }
    return 1
}

/// hs.task:terminationReason() -> exitCode | false
/// Method
/// Returns the termination reason for a task, or false if the task is still running.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string value of "exit" if the process exited normally or "interrupt" if it was killed by a signal.  Returns false if the termination reason is unavailable (the task is still running, or has not yet been started).
private func task_terminationReason(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    if userData.pointee.hasTerminated {
        switch task.terminationReason {
        case .exit:
            lua_pushstring(L, "exit")
        case .uncaughtSignal:
            lua_pushstring(L, "interrupt")
        @unknown default:
            lua_pushstring(L, "unknown")
        }
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

/// hs.task:environment() -> environment
/// Method
/// Returns the environment variables as a table for the task.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table of the environment variables for the task where each key is the environment variable name.
///
/// Notes:
///  * if you have not yet set an environment table with the `hs.task:setEnvironment` method, this method will return a copy of the Cosmic Hammer environment table, as this is what the task will inherit by default.
private func task_getEnvironment(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    if let env = task.environment {
        skin.pushNSObject(env as NSDictionary)
    } else {
        skin.pushNSObject(ProcessInfo.processInfo.environment as NSDictionary)
    }
    return 1
}

/// hs.task:setEnvironment(environment) -> hs.task object | false
/// Method
/// Sets the environment variables for the task.
///
/// Parameters:
///  * environment - a table of key-value pairs representing the environment variables that will be set for the task.
///
/// Returns:
///  * The hs.task object, or false if the table was not set (usually because the task is already running or has completed)
///
/// Notes:
///  * If you do not set an environment table with this method, the task will inherit the environment variables of the Cosmic Hammer application.  Set this to an empty table if you wish for no variables to be set for the task.
private func task_setEnvironment(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TTABLE, LS_TBREAK)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process

    if let env = skin.toNSObject(atIndex: 2) as? [String: String] {
        task.environment = env
        lua_pushvalue(L, 1)
    } else {
        skin.logWarn("hs.task:setEnvironment() Unable to set environment")
        lua_pushboolean(L, 0)
    }

    return 1
}

private func task_toString(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)

    let launchPath = userData.pointee.launchPath?.takeUnretainedValue() as String? ?? ""
    let args = (userData.pointee.arguments?.takeUnretainedValue() as? [String])?.joined(separator: " ") ?? ""
    skin.pushNSObject("hs.task: \(launchPath) \(args) (\(lua_topointer(L, 1)!))" as NSString)
    return 1
}

private func task_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: TaskUserdata.self)
    let task = userData.pointee.nsTask!.takeRetainedValue() as! Process
    let pointerArray = pointerArrayFromNSTask(task)

    if let pointerArray = pointerArray {
        tasks.remove(pointerArray)
    }

    task.terminationHandler = { _ in }

    // Attempt to terminate; ignore exceptions if task is not running
    if task.isRunning {
        task.terminate()
    }

    userData.pointee.luaCallback = skin.luaUnref(refTable, ref: userData.pointee.luaCallback)
    userData.pointee.selfRef = skin.luaUnref(refTable, ref: userData.pointee.selfRef)
    userData.pointee.luaStreamCallback = skin.luaUnref(refTable, ref: userData.pointee.luaStreamCallback)

    if let ref = userData.pointee.launchPath {
        let _ = ref.takeRetainedValue()
        userData.pointee.launchPath = nil
    }
    if let ref = userData.pointee.arguments {
        let _ = ref.takeRetainedValue()
        userData.pointee.arguments = nil
    }

    return 0
}

private func task_metagc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    tasks.removeAllObjects()
    if let observer = fileReadObserver {
        NotificationCenter.default.removeObserver(observer)
    }
    return 0
}

// MARK: - luaL_Reg tables

private var taskLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: { task_new($0) }),
    luaL_Reg(name: nil, func: nil),
]

private var taskMetaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: { task_metagc($0) }),
    luaL_Reg(name: nil, func: nil),
]

private var taskObjectLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("environment"), func: { task_getEnvironment($0) }),
    luaL_Reg(name: strdup("setEnvironment"), func: { task_setEnvironment($0) }),
    luaL_Reg(name: strdup("pid"), func: { task_getPID($0) }),
    luaL_Reg(name: strdup("start"), func: { task_launch($0) }),
    luaL_Reg(name: strdup("terminate"), func: { task_SIGTERM($0) }),
    luaL_Reg(name: strdup("interrupt"), func: { task_SIGINT($0) }),
    luaL_Reg(name: strdup("pause"), func: { task_pause($0) }),
    luaL_Reg(name: strdup("resume"), func: { task_resumeTask($0) }),
    luaL_Reg(name: strdup("terminationStatus"), func: { task_terminationStatus($0) }),
    luaL_Reg(name: strdup("terminationReason"), func: { task_terminationReason($0) }),
    luaL_Reg(name: strdup("isRunning"), func: { task_isRunning($0) }),
    luaL_Reg(name: strdup("setWorkingDirectory"), func: { task_setWorkingDirectory($0) }),
    luaL_Reg(name: strdup("workingDirectory"), func: { task_getWorkingDirectory($0) }),
    luaL_Reg(name: strdup("setCallback"), func: { task_setCallback($0) }),
    luaL_Reg(name: strdup("setStreamingCallback"), func: { task_setStreamingCallback($0) }),
    luaL_Reg(name: strdup("setInput"), func: { task_setInput($0) }),
    luaL_Reg(name: strdup("closeInput"), func: { task_closeInput($0) }),
    luaL_Reg(name: strdup("waitUntilExit"), func: { task_block($0) }),
    luaL_Reg(name: strdup("__gc"), func: { task_gc($0) }),
    luaL_Reg(name: strdup("__tostring"), func: { task_toString($0) }),
    luaL_Reg(name: nil, func: nil),
]

// MARK: - Module entry point

@_cdecl("luaopen_hs_libtask")
public func luaopen_hs_libtask(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG, functions: &taskLib, metaFunctions: &taskMetaLib, objectFunctions: &taskObjectLib)

    tasks = NSMutableArray()

    let nc = NotificationCenter.default
    fileReadObserver = nc.addObserver(forName: FileHandle.readCompletionNotification, object: nil, queue: nil) { note in
        guard let fh = note.object as? FileHandle,
              let fhData = note.userInfo?[NSFileHandleNotificationDataItem] as? Data,
              !fhData.isEmpty else {
            return
        }

        let dataString = String(data: fhData, encoding: .utf8)

        guard let userData = userDataFromNSFileHandle(fh) else {
            skin.logWarn("hs.task received output data from an unknown task. This may be a bug")
            return
        }

        if userData.pointee.luaStreamCallback != LUA_NOREF && userData.pointee.luaStreamCallback != LUA_REFNIL {
            let _skin = LuaSkin.skin(with: nil)
            let _L = _skin.l!
            _lua_stackguard_entry(_L)

            let task = userData.pointee.nsTask!.takeUnretainedValue() as! Process
            let stdOutFH = (task.standardOutput as? Pipe)?.fileHandleForReading
            let stdErrFH = (task.standardError as? Pipe)?.fileHandleForReading

            var stdOutArg: NSString = ""
            var stdErrArg: NSString = ""

            if fh === stdOutFH {
                stdOutArg = (dataString ?? "") as NSString
            } else if fh === stdErrFH {
                stdErrArg = (dataString ?? "") as NSString
            } else {
                _skin.logError("hs.task:setStreamingCallback() Received data from an unknown file handle")
                _lua_stackguard_exit(_L)
                return
            }

            let notLastGasp = (userData.pointee.selfRef != LUA_NOREF && userData.pointee.selfRef != LUA_REFNIL)
            _skin.pushLuaRef(refTable, ref: userData.pointee.luaStreamCallback)
            if notLastGasp {
                _skin.pushLuaRef(refTable, ref: userData.pointee.selfRef)
            } else {
                lua_pushnil(L)
            }
            _skin.pushNSObject(stdOutArg)
            _skin.pushNSObject(stdErrArg)

            if !_skin.protectedCallAndTraceback(3, nresults: 1) {
                let errorMsg = lua_tostring(_L, -1).map { String(cString: $0) } ?? "unknown error"
                _skin.logError("hs.task:setStreamingCallback() callback error: \(errorMsg)")
                // No lua_pop here, handled below
            }

            if lua_type(_L, -1) != LUA_TBOOLEAN {
                _skin.logError("hs.task:setStreamingCallback() callback did not return a boolean")
            } else {
                let continueStreaming = lua_toboolean(_L, -1) != 0

                if continueStreaming && notLastGasp {
                    fh.readInBackgroundAndNotify()
                }
            }
            lua_pop(_L, 1) // result or error
            _lua_stackguard_exit(_L)
        }
    }

    return 1
}
