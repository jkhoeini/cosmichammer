import Cocoa
import LuaSkin

// Common Code

private let USERDATA_TAG = "hs.pathwatcher"
private var refTable: LSRefTable = 0

// Not so common code

private struct WatcherPath {
    var closureref: Int32
    var stream: FSEventStreamRef?
    var started: Bool
    var lsCanary: LSGCCanary
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

    let skin = LuaSkin.skin(with: nil)
    let L = skin.l!

    if !skin.check(pw.pointee.lsCanary) {
        return
    }

    _lua_stackguard_entry(L)

    let changedFiles = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]

    skin.pushLuaRef(refTable, ref: pw.pointee.closureref)

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

    skin.protectedCallAndError("hs.pathwatcher callback", nargs: 2, nresults: 0)
    _lua_stackguard_exit(L)
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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TFUNCTION, LS_TBREAK)

    let path = String(cString: lua_tostring(L, 1)!)

    let watcherPtr = lua_newuserdata(L, MemoryLayout<WatcherPath>.size)!
        .assumingMemoryBound(to: WatcherPath.self)
    watcherPtr.pointee.started = false
    watcherPtr.pointee.lsCanary = skin.createGCCanary()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    lua_pushvalue(L, 2)
    watcherPtr.pointee.closureref = skin.luaRef(refTable)

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
        UInt32(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
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
private func watcher_path_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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
private func watcher_path_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
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

private func watcher_path_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    let watcherPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: WatcherPath.self)

    // Stop the watcher
    lua_pushcfunction(L) { L in watcher_path_stop(L) }
    lua_pushvalue(L, 1)
    lua_call(L, 1, 1)

    if let stream = watcherPtr.pointee.stream {
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    watcherPtr.pointee.closureref = skin.luaUnref(refTable, ref: watcherPtr.pointee.closureref)
    skin.destroy(&watcherPtr.pointee.lsCanary)

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let watcherPtr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: WatcherPath.self)
    var thePath = "(unknown path)"
    if let stream = watcherPtr.pointee.stream {
        let thePaths = FSEventStreamCopyPathsBeingWatched(stream) as! [String]
        if !thePaths.isEmpty {
            thePath = thePaths[0]
        }
    }

    let str = "\(USERDATA_TAG): \(thePath) (\(lua_topointer(L, 1)!))"
    lua_pushstring(L, str)
    return 1
}

// Metatable for created objects when _new invoked
private let path_metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("start"),      func: { L in watcher_path_start(L) }),
    luaL_Reg(name: strdup("stop"),       func: { L in watcher_path_stop(L) }),
    luaL_Reg(name: strdup("__gc"),       func: { L in watcher_path_gc(L) }),
    luaL_Reg(name: strdup("__tostring"), func: { L in userdata_tostring(L) }),
    luaL_Reg(name: nil, func: nil),
]

// Functions for returned object when module loads
private let pathLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: { L in watcher_path_new(L) }),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for returned object when module loads
private let meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: { L in meta_gc(L) }),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libpathwatcher")
public func luaopen_hs_libpathwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG, functions: pathLib, metaFunctions: meta_gcLib, objectFunctions: path_metalib)
    return 1
}
