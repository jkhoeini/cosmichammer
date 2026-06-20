import Cocoa
import CLua
import Lua
import Carbon
import os.log

private let USERDATA_TAG = "hs.uielement.watcher"

// MARK: - Lua<->NSObject Conversion Functions

/// Push an HSuielementWatcher (or any HSuielementWatcherProtocol-conforming object) as
/// raw-pointer userdata. This is called from Uielement.swift, Window.swift, and
/// Application.swift, so it must remain public and keep the Unmanaged/selfRefCount pattern.
@discardableResult
func pushHSuielementWatcher(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) -> Int32 {
    guard let value = obj as? NSObject & HSuielementWatcherProtocol else { return 0 }
    value.selfRefCount += 1
    let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    valuePtr.pointee = Unmanaged.passRetained(value as NSObject).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

func pushHSuielementWatcherOrNil(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) {
    if pushHSuielementWatcher(L, obj) == 0 {
        lua_pushnil(L)
    }
}

private func getWatcher(_ L: UnsafeMutablePointer<lua_State>!, at idx: Int32) -> (NSObject & HSuielementWatcherProtocol)? {
    let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    guard let rawPtr = ptr.pointee else { return nil }
    return Unmanaged<NSObject>.fromOpaque(rawPtr).takeUnretainedValue() as? NSObject & HSuielementWatcherProtocol
}

// MARK: - Registration

@_cdecl("luaopen_hs_libuielementwatcher")
public func luaopen_hs_libuielementwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Register userdata metatable
        luaL_newmetatable(L, USERDATA_TAG)
        lua_pushvalue(L, -1)
        lua_setfield(L, -2, "__index")

        // _start
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checkudata(L, 1, USERDATA_TAG)
            luaL_checktype(L, 2, LUA_TTABLE)
            guard let watcher = getWatcher(L, at: 1) else { return 0 }
            if let concreteWatcher = watcher as? HSuielementWatcher {
                concreteWatcher.watcherSelfRef = nil  // release old ref before reassigning
                concreteWatcher.watcherSelfRef = L.ref(index: 1)
            }
            if let events = lua_tovalue(L, at: 2) as? [String] {
                watcher.start(events, withState: L)
            }
            lua_pushvalue(L, 1)
            return 1
        })
        lua_setfield(L, -2, "_start")

        // _stop
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checkudata(L, 1, USERDATA_TAG)
            guard let watcher = getWatcher(L, at: 1) else { return 0 }
            watcher.stop()
            if let concreteWatcher = watcher as? HSuielementWatcher {
                concreteWatcher.watcherSelfRef = nil
            }
            lua_pushvalue(L, 1)
            return 1
        })
        lua_setfield(L, -2, "_stop")

        // pid
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checkudata(L, 1, USERDATA_TAG)
            guard let watcher = getWatcher(L, at: 1) else { return 0 }
            L.push(lua_Number(watcher.pid))
            return 1
        })
        lua_setfield(L, -2, "pid")

        // element
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checkudata(L, 1, USERDATA_TAG)
            guard let watcher = getWatcher(L, at: 1) else { return 0 }

            let element = HSuielement(withElement: watcher.elementRef)

            if element.isWindow {
                let handle = ProductionWindowElement(element: watcher.elementRef)
                pushWindowElement(L, handle)
                return 1
            } else if element.isApplication {
                let app = HSapplication(pid: watcher.pid, withState: L)
                pushHSapplicationOrNil(L, app)
                return 1
            }
            pushHSuielement(L, element)
            return 1
        })
        lua_setfield(L, -2, "element")

        // watchDestroyed
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checkudata(L, 1, USERDATA_TAG)
            guard let watcher = getWatcher(L, at: 1) else { return 0 }

            if lua_type(L, 2) == LUA_TBOOLEAN {
                watcher.watchDestroyed = lua_toboolean(L, 2) != 0
                lua_pushvalue(L, 1)
            } else {
                L.push(watcher.watchDestroyed)
            }
            return 1
        })
        lua_setfield(L, -2, "watchDestroyed")

        // __tostring
        L.push({ (L: LuaState) throws -> CInt in
            luaL_checkudata(L, 1, USERDATA_TAG)
            let desc = "\(USERDATA_TAG): (\(String(describing: lua_topointer(L, 1)!)))"
            L.push(desc)
            return 1
        })
        lua_setfield(L, -2, "__tostring")

        // __eq
        L.push({ (L: LuaState) throws -> CInt in
            var isEqual = false
            if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
                let ptr1 = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                let ptr2 = luaL_checkudata(L, 2, USERDATA_TAG)!.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                if let raw1 = ptr1.pointee, let raw2 = ptr2.pointee {
                    let obj1 = Unmanaged<NSObject>.fromOpaque(raw1).takeUnretainedValue()
                    let obj2 = Unmanaged<NSObject>.fromOpaque(raw2).takeUnretainedValue()
                    isEqual = obj1.isEqual(obj2)
                }
            }
            L.push(isEqual)
            return 1
        })
        lua_setfield(L, -2, "__eq")

        // __gc — handles Unmanaged raw-pointer layout with selfRefCount
        lua_pushcclosure(L, { (L: LuaState!) -> CInt in
            luaL_checkudata(L, 1, USERDATA_TAG)
            let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let rawPtr = ptr.pointee {
                let watcher = Unmanaged<NSObject>.fromOpaque(rawPtr).takeRetainedValue()
                if let w = watcher as? HSuielementWatcherProtocol {
                    w.selfRefCount -= 1
                    if w.selfRefCount == 0 {
                        if let concreteWatcher = watcher as? HSuielementWatcher {
                            concreteWatcher.teardown()
                        } else {
                            w.stop()
                        }
                    }
                }
                ptr.pointee = nil
            }
            lua_pushnil(L)
            lua_setmetatable(L, 1)
            return 0
        }, 0)
        lua_setfield(L, -2, "__gc")

        // Set __type and __name for type identification
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__type")
        L.push(USERDATA_TAG)
        lua_setfield(L, -2, "__name")

        // Alias the metatable under the registry name
        lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

        // Create module table
        lua_createtable(L, 0, 0)

        // Set module metatable (empty)
        lua_createtable(L, 0, 0)
        lua_setmetatable(L, -2)
    }
}
