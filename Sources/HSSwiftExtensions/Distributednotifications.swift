import Foundation
import CLua
import Lua
import Cocoa

private let USERDATA_TAG = "hs.distributednotifications"

// MARK: - HSDistNotWatcher Definition

private class HSDistNotWatcher: NSObject {
    var callback: LuaValue?
    var object: String?
    var name: String?
    var generation: UInt64 = 0
    private var tornDown = false

    /// Idempotent teardown: remove observer, drop the Lua callback reference,
    /// mark as torn down.  Called from the explicit __gc closure while the
    /// lua_State is still alive.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        let center = DistributedNotificationCenter.default()
        let noteName: NSNotification.Name? = name.map { NSNotification.Name($0) }
        center.removeObserver(self, name: noteName, object: object)
        callback = nil
    }

    @objc func callbackFired(_ note: NSNotification) {
        if !lua_isStateGenerationValid(generation) {
            teardown()
            return
        }

        guard let cb = callback else { return }
        let L = lua_getCurrentState()!
        cb.push(onto: L)
        lua_pushany(L, note.name.rawValue)
        lua_pushany(L, note.object)
        lua_pushany(L, note.userInfo)
        if lua_pcall(L, 3, 0, 0) != LUA_OK {
            lua_pop(L, 1)
        }
    }
}

// MARK: - Module Functions

/// hs.distributednotifications.new(callback[, name[, object]]) -> object
/// Constructor
/// Creates a new NSDistributedNotificationCenter watcher
///
/// Parameters:
///  * callback - A function to be called when a matching notification arrives. The function should accept one argument:
///   * notificationName - A string containing the name of the notification
///  * name - An optional string containing the name of notifications to watch for. A value of `nil` will cause all notifications to be watched on macOS versions earlier than Catalina. Defaults to `nil`.
///  * object - An optional string containing the name of sending objects to watch for. A value of `nil` will cause all sending objects to be watched. Defaults to `nil`.
///
/// Returns:
///  * An `hs.distributednotifications` object
///
/// Notes:
///  * On Catalina and above, it is no longer possible to observe all notifications - the `name` parameter is effectively now required. See https://mjtsai.com/blog/2019/10/04/nsdistributednotificationcenter-no-longer-supports-nil-names/
private func distnot_new(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TFUNCTION)

    let name: String? = lua_isnoneornil(L, 2) ? nil : (lua_type(L, 2) == LUA_TSTRING ? String(cString: lua_tostring(L, 2)!) : nil)
    let obj: String? = lua_isnoneornil(L, 3) ? nil : (lua_type(L, 3) == LUA_TSTRING ? String(cString: lua_tostring(L, 3)!) : nil)

    let watcher = HSDistNotWatcher()
    watcher.callback = L.ref(index: 1)
    watcher.name = name
    watcher.object = obj
    watcher.generation = lua_currentStateGeneration()

    L.push(userdata: watcher)

    return 1
}

/// hs.distributednotifications.post(name[, sender[, userInfo]])
/// Function
/// Sends a distributed notification
///
/// Parameters:
///  * name - A string containing the name of the notification
///  * sender - An optional string containing the name of the sender of the notification (in the form `com.domain.application.foo`). Defaults to nil.
///  * userInfo - An optional table containing additional information to post with the notification. Defaults to nil.
///
/// Returns:
///  * None
private func distnot_post(_ L: LuaState) throws -> CInt {
    guard lua_type(L, 1) == LUA_TSTRING else {
        throw LuaCallError("expected string for argument 1")
    }

    let noteName = String(cString: lua_tostring(L, 1)!)
    let object: String? = (lua_type(L, 2) == LUA_TSTRING) ? String(cString: lua_tostring(L, 2)!) : nil
    let userInfo: [AnyHashable: Any]? = (lua_type(L, 3) == LUA_TTABLE) ? (lua_tovalue(L, at: 3) as? [String: Any]) : nil

    let center = DistributedNotificationCenter.default()
    center.postNotificationName(
        NSNotification.Name(noteName),
        object: object,
        userInfo: userInfo,
        deliverImmediately: true
    )

    return 0
}

// MARK: - Module Entry Point

@_cdecl("luaopen_hs_libdistributednotifications")
public func luaopen_hs_libdistributednotifications(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Register idiomatic Metatable<HSDistNotWatcher> with LuaSwift.
    L.register(Metatable<HSDistNotWatcher>(
        fields: [
            "start": .closure { L in
                let watcher: HSDistNotWatcher = try L.checkArgument(1)
                lua_settop(L, 1)

                let center = DistributedNotificationCenter.default()
                let noteName: NSNotification.Name? = watcher.name.map { NSNotification.Name($0) }
                center.addObserver(
                    watcher,
                    selector: #selector(HSDistNotWatcher.callbackFired(_:)),
                    name: noteName,
                    object: watcher.object,
                    suspensionBehavior: .deliverImmediately
                )

                return 1  // return self
            },
            "stop": .closure { L in
                let watcher: HSDistNotWatcher = try L.checkArgument(1)
                lua_settop(L, 1)

                let center = DistributedNotificationCenter.default()
                let noteName: NSNotification.Name? = watcher.name.map { NSNotification.Name($0) }
                center.removeObserver(watcher, name: noteName, object: watcher.object)

                return 1  // return self
            },
        ],
        tostring: .closure { L in
            let watcher: HSDistNotWatcher = try L.checkArgument(1)
            let ptr = lua_topointer(L, 1)!
            L.push("\(USERDATA_TAG): name: \(watcher.name ?? "nil") object: \(watcher.object ?? "nil") (\(ptr))")
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // LuaSwift's register() installs its own gcUserdata as __gc, which only
    // deinitializes the Any box. Replace it with a custom __gc that first
    // calls teardown() (remove observer, drop LuaValue callback) and THEN
    // deinitializes the Any box.
    L.pushMetatable(for: HSDistNotWatcher.self)

    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let watcher: HSDistNotWatcher = L.touserdata(1) {
            watcher.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    L.push(USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.distributednotifications") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 2)
    L.push(distnot_new)
    lua_setfield(L, -2, "new")
    L.push(distnot_post)
    lua_setfield(L, -2, "post")

    return 1
}
