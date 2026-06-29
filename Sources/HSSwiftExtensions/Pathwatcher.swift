import Cocoa
import CLua
import HSDSTCore
import Lua

// Common Code

private let USERDATA_TAG = "hs.pathwatcher"
private var activePathWatcherCount = 0

private func recordActivePathWatcherGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.pathwatcher.active",
        kind: .gauge,
        value: Double(activePathWatcherCount),
        attributes: [:],
        unit: "1"
    )
}

// MARK: - HSPathWatcher class

class HSPathWatcher: NSObject {
    var callback: LuaValue?
    var stream: FSEventStreamRef?
    var started: Bool = false
    var generation: UInt64 = 0
    private var tornDown = false

    /// Idempotent teardown: stop the FSEventStream, drop the Lua callback
    /// reference, mark as torn down.  Called from the explicit __gc closure
    /// while the lua_State is still alive.
    func teardown(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
        guard !tornDown else { return }
        tornDown = true
        if started, let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        setStarted(false, L: L)
        if let stream = stream {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        callback = nil   // drops the LuaValue ref while L is still open
    }

    func start(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
        guard !started, let stream = stream else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        if FSEventStreamStart(stream) {
            setStarted(true, L: L)
        } else {
            FSEventStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    func stop(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
        guard started, let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        setStarted(false, L: L)
    }

    private func setStarted(_ active: Bool, L: UnsafeMutablePointer<lua_State>?) {
        guard started != active else { return }
        started = active
        if active {
            activePathWatcherCount += 1
        } else {
            activePathWatcherCount = max(0, activePathWatcherCount - 1)
        }
        recordActivePathWatcherGauge(L)
    }
}

// MARK: - FSEvent helpers

private func pusheventflagstable(_ L: UnsafeMutablePointer<lua_State>!, _ flags: FSEventStreamEventFlags) {
    lua_newtable(L)
    if (flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs))    != 0 { L.push(true); lua_setfield(L, -2, "mustScanSubDirs")    }
    if (flags & UInt32(kFSEventStreamEventFlagUserDropped))        != 0 { L.push(true); lua_setfield(L, -2, "userDropped")        }
    if (flags & UInt32(kFSEventStreamEventFlagKernelDropped))      != 0 { L.push(true); lua_setfield(L, -2, "kernelDropped")      }
    if (flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped))    != 0 { L.push(true); lua_setfield(L, -2, "eventIdsWrapped")    }
    if (flags & UInt32(kFSEventStreamEventFlagHistoryDone))        != 0 { L.push(true); lua_setfield(L, -2, "historyDone")        }
    if (flags & UInt32(kFSEventStreamEventFlagRootChanged))        != 0 { L.push(true); lua_setfield(L, -2, "rootChanged")        }
    if (flags & UInt32(kFSEventStreamEventFlagMount))              != 0 { L.push(true); lua_setfield(L, -2, "mount")              }
    if (flags & UInt32(kFSEventStreamEventFlagUnmount))            != 0 { L.push(true); lua_setfield(L, -2, "unmount")            }
    if (flags & UInt32(kFSEventStreamEventFlagOwnEvent))           != 0 { L.push(true); lua_setfield(L, -2, "ownEvent")           }
    if (flags & UInt32(kFSEventStreamEventFlagItemCreated))        != 0 { L.push(true); lua_setfield(L, -2, "itemCreated")        }
    if (flags & UInt32(kFSEventStreamEventFlagItemRemoved))        != 0 { L.push(true); lua_setfield(L, -2, "itemRemoved")        }
    if (flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod))   != 0 { L.push(true); lua_setfield(L, -2, "itemInodeMetaMod")   }
    if (flags & UInt32(kFSEventStreamEventFlagItemRenamed))        != 0 { L.push(true); lua_setfield(L, -2, "itemRenamed")        }
    if (flags & UInt32(kFSEventStreamEventFlagItemModified))       != 0 { L.push(true); lua_setfield(L, -2, "itemModified")       }
    if (flags & UInt32(kFSEventStreamEventFlagItemFinderInfoMod))  != 0 { L.push(true); lua_setfield(L, -2, "itemFinderInfoMod")  }
    if (flags & UInt32(kFSEventStreamEventFlagItemChangeOwner))    != 0 { L.push(true); lua_setfield(L, -2, "itemChangeOwner")    }
    if (flags & UInt32(kFSEventStreamEventFlagItemXattrMod))       != 0 { L.push(true); lua_setfield(L, -2, "itemXattrMod")       }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsFile))         != 0 { L.push(true); lua_setfield(L, -2, "itemIsFile")         }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsDir))          != 0 { L.push(true); lua_setfield(L, -2, "itemIsDir")          }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsSymlink))      != 0 { L.push(true); lua_setfield(L, -2, "itemIsSymlink")      }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsHardlink))     != 0 { L.push(true); lua_setfield(L, -2, "itemIsHardlink")     }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsLastHardlink)) != 0 { L.push(true); lua_setfield(L, -2, "itemIsLastHardlink") }
}

// The FSEventStream callback must be a C function pointer. We pass the
// HSPathWatcher as the retained `info` pointer in the FSEventStreamContext.
private let event_callback: FSEventStreamCallback = {
    (streamRef: ConstFSEventStreamRef,
     clientCallBackInfo: UnsafeMutableRawPointer?,
     numEvents: Int,
     eventPaths: UnsafeMutableRawPointer,
     eventFlags: UnsafePointer<FSEventStreamEventFlags>,
     eventIds: UnsafePointer<FSEventStreamEventId>) in

    guard let clientCallBackInfo = clientCallBackInfo else { return }
    let watcher = Unmanaged<HSPathWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

    guard lua_isStateGenerationValid(watcher.generation) else {
        watcher.teardown()
        return
    }

    let L = lua_getCurrentState()!

    guard let changedFiles = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String],
          changedFiles.count >= numEvents else {
        return
    }

    guard let cb = watcher.callback else { return }

    cb.push(onto: L)

    lua_newtable(L)
    for i in 0..<numEvents {
        L.push(changedFiles[i])
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    lua_newtable(L)
    for i in 0..<numEvents {
        pusheventflagstable(L, eventFlags[i])
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }

    if luaTelemetryPCall(
        L,
        nargs: 2,
        nresults: 0,
        callbackName: "hs.pathwatcher",
        attributes: ["file.event.count": numEvents]
    ) != LUA_OK {
        lua_pop(L, 1)
    }
}

/// hs.pathwatcher.new(path, fn) -> watcher
/// Constructor
/// Creates a new path watcher object
///
/// Parameters:
///  * path - A string containing the path to be watched
///  * fn - A function to be called when changes are detected. It should accept two arguments:
///    * `paths`: a table containing a list of file paths that have changed
///    * `flagTables`: a table containing a list of tables denoting how each corresponding file in `paths` has changed, each containing boolean values indicating which types of events occurred; The possible keys are:
///      * mustScanSubDirs
///      * userDropped
///      * kernelDropped
///      * eventIdsWrapped
///      * historyDone
///      * rootChanged
///      * mount
///      * unmount
///      * itemCreated
///      * itemRemoved
///      * itemInodeMetaMod
///      * itemRenamed
///      * itemModified
///      * itemFinderInfoMod
///      * itemChangeOwner
///      * itemXattrMod
///      * itemIsFile
///      * itemIsDir
///      * itemIsSymlink
///      * ownEvent (OS X 10.9+)
///      * itemIsHardlink (OS X 10.10+)
///      * itemIsLastHardlink (OS X 10.10+)
///
/// Returns:
///  * An `hs.pathwatcher` object
///
/// Notes:
///  * For more information about the event flags, see [the official documentation](https://developer.apple.com/reference/coreservices/1455361-fseventstreameventflags/)
private func watcher_path_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TSTRING)
    luaL_checktype(L, 2, LUA_TFUNCTION)

    let path = String(cString: lua_tostring(L, 1)!)
    let cb = L.ref(index: 2)

    let watcher = HSPathWatcher()
    watcher.callback = cb
    watcher.generation = lua_currentStateGeneration()

    // The FSEventStreamContext retains the HSPathWatcher so the C callback
    // can reach it.  We use Unmanaged to bridge the pointer.
    let unmanaged = Unmanaged.passRetained(watcher)
    var context = FSEventStreamContext(
        version: 0,
        info: unmanaged.toOpaque(),
        retain: nil,
        release: nil,
        copyDescription: nil
    )

    let standardized = (path as NSString).standardizingPath
    let resolved = (standardized as NSString).resolvingSymlinksInPath

    watcher.stream = FSEventStreamCreate(
        nil,
        event_callback,
        &context,
        [resolved] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.4,
        UInt32(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
    )

    L.push(userdata: watcher)
    return 1
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libpathwatcher")
public func luaopen_hs_libpathwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<HSPathWatcher> with LuaSwift.
    L.register(Metatable<HSPathWatcher>(
        fields: [
            "start": .closure { L in
                let watcher: HSPathWatcher = try L.checkArgument(1)
                lua_settop(L, 1)
                watcher.start(L)
                return 1  // return self
            },
            "stop": .closure { L in
                let watcher: HSPathWatcher = try L.checkArgument(1)
                lua_settop(L, 1)
                watcher.stop(L)
                return 1  // return self
            },
        ],
        tostring: .closure { L in
            let watcher: HSPathWatcher = try L.checkArgument(1)
            var thePath = "(unknown path)"
            if let stream = watcher.stream {
                if let thePaths = FSEventStreamCopyPathsBeingWatched(stream) as? [String],
                   !thePaths.isEmpty {
                    thePath = thePaths[0]
                }
            }
            L.push("\(USERDATA_TAG): \(thePath) (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // LuaSwift's register() always installs its own gcUserdata as __gc, which
    // only deinitializes the Any box. We MUST replace it with a custom __gc
    // that first calls teardown() (stop the FSEventStream, drop the LuaValue
    // callback) and THEN deinitializes the Any box. Without this, the retained
    // Unmanaged reference keeps HSPathWatcher alive after the box is
    // deinitialized, leaking the callback ref and letting the watcher fire.
    L.pushMetatable(for: HSPathWatcher.self)

    // Replace __gc with our explicit teardown + deinitialize
    L.push({ (L: LuaState!) -> CInt in
        // Extract the HSPathWatcher from the Any box BEFORE deinitializing
        if let watcher: HSPathWatcher = L.touserdata(1) {
            watcher.teardown(L)
            // Balance the Unmanaged.passRetained from watcher_path_new
            Unmanaged.passUnretained(watcher).release()
        }
        // Now deinitialize the Any box (same as LuaSwift's gcUserdata)
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

    // Alias the metatable under the legacy registry name "hs.pathwatcher" so that
    // core_getObjectMetatable("hs.pathwatcher") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 1)
    L.push(watcher_path_new)
    lua_setfield(L, -2, "new")

    return 1
}
