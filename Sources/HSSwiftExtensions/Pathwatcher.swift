import Cocoa
import CLua
import Lua

// Common Code

private let USERDATA_TAG = "hs.pathwatcher"
private var refTable: Int32 = 0

// Not so common code

private struct WatcherPath {
    var closureref: Int32
    var stream: FSEventStreamRef?
    var started: Bool
    var generation: UInt64
}

private func pusheventflagstable(_ L: UnsafeMutablePointer<lua_State>!, _ flags: FSEventStreamEventFlags) {
    lua_newtable(L)
    if (flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs))    != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "mustScanSubDirs")    }
    if (flags & UInt32(kFSEventStreamEventFlagUserDropped))        != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "userDropped")        }
    if (flags & UInt32(kFSEventStreamEventFlagKernelDropped))      != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "kernelDropped")      }
    if (flags & UInt32(kFSEventStreamEventFlagEventIdsWrapped))    != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "eventIdsWrapped")    }
    if (flags & UInt32(kFSEventStreamEventFlagHistoryDone))        != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "historyDone")        }
    if (flags & UInt32(kFSEventStreamEventFlagRootChanged))        != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "rootChanged")        }
    if (flags & UInt32(kFSEventStreamEventFlagMount))              != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "mount")              }
    if (flags & UInt32(kFSEventStreamEventFlagUnmount))            != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "unmount")            }
    if (flags & UInt32(kFSEventStreamEventFlagOwnEvent))           != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "ownEvent")           }
    if (flags & UInt32(kFSEventStreamEventFlagItemCreated))        != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemCreated")        }
    if (flags & UInt32(kFSEventStreamEventFlagItemRemoved))        != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemRemoved")        }
    if (flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod))   != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemInodeMetaMod")   }
    if (flags & UInt32(kFSEventStreamEventFlagItemRenamed))        != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemRenamed")        }
    if (flags & UInt32(kFSEventStreamEventFlagItemModified))       != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemModified")       }
    if (flags & UInt32(kFSEventStreamEventFlagItemFinderInfoMod))  != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemFinderInfoMod")  }
    if (flags & UInt32(kFSEventStreamEventFlagItemChangeOwner))    != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemChangeOwner")    }
    if (flags & UInt32(kFSEventStreamEventFlagItemXattrMod))       != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemXattrMod")       }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsFile))         != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemIsFile")         }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsDir))          != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemIsDir")          }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsSymlink))      != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemIsSymlink")      }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsHardlink))     != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemIsHardlink")     }
    if (flags & UInt32(kFSEventStreamEventFlagItemIsLastHardlink)) != 0 { lua_pushboolean(L, 1); lua_setfield(L, -2, "itemIsLastHardlink") }
}

private let event_callback: FSEventStreamCallback = {
    (streamRef: ConstFSEventStreamRef,
     clientCallBackInfo: UnsafeMutableRawPointer?,
     numEvents: Int,
     eventPaths: UnsafeMutableRawPointer,
     eventFlags: UnsafePointer<FSEventStreamEventFlags>,
     eventIds: UnsafePointer<FSEventStreamEventId>) in

    guard let clientCallBackInfo = clientCallBackInfo else { return }
    let pw = clientCallBackInfo.assumingMemoryBound(to: WatcherPath.self)

    let L = lua_getCurrentState()!

    guard lua_isStateGenerationValid(pw.pointee.generation) else { return }

    guard let changedFiles = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String],
          changedFiles.count >= numEvents else {
        return
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(pw.pointee.closureref))

    lua_newtable(L)
    for i in 0..<numEvents {
        lua_pushstring(L, changedFiles[i])
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    lua_newtable(L)
    for i in 0..<numEvents {
        pusheventflagstable(L, eventFlags[i])
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }

    if lua_pcall(L, 2, 0, 0) != LUA_OK {
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
private func watcher_path_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    luaL_checktype(L, 2, LUA_TFUNCTION)

    let path = String(cString: lua_tostring(L, 1)!)

    let watcherPtr = lua_newuserdata(L, MemoryLayout<WatcherPath>.size)!
        .assumingMemoryBound(to: WatcherPath.self)
    watcherPtr.pointee.started = false
    watcherPtr.pointee.generation = lua_currentStateGeneration()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    lua_pushvalue(L, 2)
    watcherPtr.pointee.closureref = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    var context = FSEventStreamContext(
        version: 0,
        info: watcherPtr,
        retain: nil,
        release: nil,
        copyDescription: nil
    )

    let standardized = (path as NSString).standardizingPath
    let resolved = (standardized as NSString).resolvingSymlinksInPath

    watcherPtr.pointee.stream = FSEventStreamCreate(
        nil,
        event_callback,
        &context,
        [resolved] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.4,
        UInt32(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
    )

    return 1
}

/// hs.pathwatcher:start()
/// Method
/// Starts a path watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.pathwatcher` object
private func watcher_path_start(_ L: LuaState) throws -> CInt {
    let watcherPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: WatcherPath.self)
    lua_settop(L, 1)

    if watcherPtr.pointee.started { return 1 }
    watcherPtr.pointee.started = true

    if let stream = watcherPtr.pointee.stream {
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
    }

    return 1
}

/// hs.pathwatcher:stop()
/// Method
/// Stops a path watcher
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func watcher_path_stop(_ L: LuaState) throws -> CInt {
    let watcherPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: WatcherPath.self)
    lua_settop(L, 1)

    if !watcherPtr.pointee.started { return 1 }

    watcherPtr.pointee.started = false
    if let stream = watcherPtr.pointee.stream {
        FSEventStreamStop(stream)
        FSEventStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    return 1
}

private func watcher_path_gc(_ L: LuaState) throws -> CInt {
    let watcherPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: WatcherPath.self)

    // Stop the watcher
    _ = try watcher_path_stop(L)

    if let stream = watcherPtr.pointee.stream {
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, watcherPtr.pointee.closureref)
    watcherPtr.pointee.closureref = Int32(LUA_NOREF)

    return 0
}

private func meta_gc(_ L: LuaState) throws -> CInt {
    return 0
}

private func userdata_tostring(_ L: LuaState) throws -> CInt {
    let watcherPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: WatcherPath.self)
    var thePath = "(unknown path)"
    if let stream = watcherPtr.pointee.stream {
        if let thePaths = FSEventStreamCopyPathsBeingWatched(stream) as? [String],
           !thePaths.isEmpty {
            thePath = thePaths[0]
        }
    }

    let str = "\(USERDATA_TAG): \(thePath) (\(lua_topointer(L, 1)!))"
    lua_pushstring(L, str)
    return 1
}

@_cdecl("luaopen_hs_libpathwatcher")
public func luaopen_hs_libpathwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")
        L.push(watcher_path_start)
        lua_setfield(L, -2, "start")
        L.push(watcher_path_stop)
        lua_setfield(L, -2, "stop")
        L.push(watcher_path_gc)
        lua_setfield(L, -2, "__gc")
        L.push(userdata_tostring)
        lua_setfield(L, -2, "__tostring")
        lua_pop(L, 1)

        // Create module table
        lua_createtable(L, 0, 1)
        L.push(watcher_path_new)
        lua_setfield(L, -2, "new")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(meta_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
