import Foundation
import CLua
import Lua
import Cocoa
import HSDSTCore

private let USERDATA_TAG = "hs.distributednotifications"
private var activeDistributedNotificationWatcherCount = 0

private func recordActiveDistributedNotificationWatcherGauge(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
    let telemetry = L.map { environmentGet($0).telemetry } ?? environmentGetGlobalOrNil()?.telemetry
    telemetry?.recordMetric(
        name: "cosmichammer.distributednotifications.watcher.active",
        kind: .gauge,
        value: Double(activeDistributedNotificationWatcherCount),
        attributes: [:],
        unit: "1"
    )
}

// MARK: - HSDistNotWatcher Definition

private class HSDistNotWatcher: NSObject {
    var callback: LuaValue?
    var object: String?
    var name: String?
    var generation: UInt64 = 0
    var observerToken: (any NotificationObserverToken)?
    weak var notificationRef: (any NotificationProtocol)?
    private var tornDown = false

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stop(lua_getCurrentState())
        notificationRef = nil
        callback = nil
    }

    func start(_ L: UnsafeMutablePointer<lua_State>) {
        guard observerToken == nil else { return }

        let notif = environmentGet(L).notification
        let token = notif.addDistributedObserver(name: name, object: object) { [weak self] name, object, userInfo in
            guard let self = self else { return }
            if !lua_isStateGenerationValid(self.generation) {
                self.teardown()
                return
            }
            guard let cb = self.callback else { return }
            let L = lua_getCurrentState()!
            cb.push(onto: L)
            lua_pushany(L, name)
            lua_pushany(L, object)
            lua_pushany(L, userInfo)
            if luaTelemetryPCall(
                L,
                nargs: 3,
                nresults: 0,
                callbackName: "hs.distributednotifications",
                attributes: ["notification.name": name]
            ) != LUA_OK {
                lua_pop(L, 1)
            }
        }
        observerToken = token
        notificationRef = notif
        activeDistributedNotificationWatcherCount += 1
        recordActiveDistributedNotificationWatcherGauge(L)
    }

    func stop(_ L: UnsafeMutablePointer<lua_State>? = lua_getCurrentState()) {
        guard let token = observerToken else { return }
        notificationRef?.removeObserver(token)
        observerToken = nil
        activeDistributedNotificationWatcherCount = max(0, activeDistributedNotificationWatcherCount - 1)
        recordActiveDistributedNotificationWatcherGauge(L)
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
    let userInfo: [String: Any]? = (lua_type(L, 3) == LUA_TTABLE) ? (lua_tovalue(L, at: 3) as? [String: Any]) : nil

    environmentGet(L).notification.postDistributed(name: noteName, object: object, userInfo: userInfo)

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
                watcher.start(L)
                return 1  // return self
            },
            "stop": .closure { L in
                let watcher: HSDistNotWatcher = try L.checkArgument(1)
                lua_settop(L, 1)
                watcher.stop(L)
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
