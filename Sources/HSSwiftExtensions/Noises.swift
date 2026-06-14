import Cocoa
import CLua
import Lua
import Foundation

// MARK: - Constants

private let USERDATA_TAG = "hs.noises"

// MARK: - HSNoisesListener class

private class HSNoisesListener {
    var callback: LuaValue?
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        callback = nil
    }
}

// MARK: - Lua functions (stubbed — noise detection is not implemented)

private func noises_listener_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_settop(L, 1)
    return 1
}

private func noises_listener_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Push error via lua_error so the @_cdecl entry point stays non-throwing
    luaL_error(L, "hs.noises: noise detection is not implemented in this version")
    return 0
}

/// hs.noises.new(fn) -> listener
/// Constructor
/// Creates a new listener for mouth noise recognition (stub — not implemented)
private func noises_listener_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let listener = HSNoisesListener()
    listener.callback = L.ref(index: 1)

    L.push(userdata: listener)

    return 1
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libnoises")
public func luaopen_hs_libnoises(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<HSNoisesListener>
    L.register(Metatable<HSNoisesListener>(
        fields: [
            "start": .closure { L in
                let _: HSNoisesListener = try L.checkArgument(1)
                throw LuaCallError("hs.noises: noise detection is not implemented in this version")
            },
            "stop": .closure { L in
                let _: HSNoisesListener = try L.checkArgument(1)
                lua_settop(L, 1)
                return 1
            },
        ],
        tostring: .closure { L in
            let _: HSNoisesListener = try L.checkArgument(1)
            L.push("\(USERDATA_TAG): (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    // Post-registration metatable patching
    L.pushMetatable(for: HSNoisesListener.self)

    // Replace __gc with explicit teardown + deinitialize
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let listener: HSNoisesListener = L.touserdata(1) {
            listener.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 1)
    L.push(noises_listener_new)
    lua_setfield(L, -2, "new")

    return 1
}
