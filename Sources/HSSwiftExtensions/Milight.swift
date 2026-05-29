import Cocoa
import CLua
import Carbon

private let USERDATA_TAG = "hs.milight"
private var refTable: Int32 = LUA_NOREF

private struct BridgeData {
    var ip: UnsafeMutablePointer<CChar>?
    var port: Int32
    var socket: Int32
    var sockaddr: sockaddr_in
}

// Option value for SO_BROADCAST
private var broadcastOption: Int32 = 1

private let cmd_suffix: UInt8 = 0x55

private func pushCommand(_ L: UnsafeMutablePointer<lua_State>!, _ cmd: UnsafePointer<CChar>, _ value: Int) {
    lua_pushinteger(L, lua_Integer(value))
    lua_setfield(L, -2, cmd)
}

func milight_cacheCommands(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_createtable(L, 0, 0)

    pushCommand(L, "rgbw", 0x40)
    pushCommand(L, "all_off", 0x41)
    pushCommand(L, "all_on", 0x42)
    pushCommand(L, "disco_slower", 0x43)
    pushCommand(L, "disco_faster", 0x44)
    pushCommand(L, "zone1_on", 0x45)
    pushCommand(L, "zone1_off", 0x46)
    pushCommand(L, "zone2_on", 0x47)
    pushCommand(L, "zone2_off", 0x48)
    pushCommand(L, "zone3_on", 0x49)
    pushCommand(L, "zone3_off", 0x4A)
    pushCommand(L, "zone4_on", 0x4B)
    pushCommand(L, "zone4_off", 0x4C)
    pushCommand(L, "disco", 0x4D)
    pushCommand(L, "brightness", 0x4E)
    pushCommand(L, "all_white", 0xC2)
    pushCommand(L, "zone1_white", 0xC5)
    pushCommand(L, "zone2_white", 0xC7)
    pushCommand(L, "zone3_white", 0xC9)
    pushCommand(L, "zone4_white", 0xCB)

    // Convenience colors
    pushCommand(L, "violet", 0x00)
    pushCommand(L, "royalblue", 0x10)
    pushCommand(L, "babyblue", 0x20)
    pushCommand(L, "aqua", 0x30)
    pushCommand(L, "mint", 0x40)
    pushCommand(L, "seafoam", 0x50)
    pushCommand(L, "green", 0x60)
    pushCommand(L, "lime", 0x70)
    pushCommand(L, "yellow", 0x80)
    pushCommand(L, "yelloworange", 0x90)
    pushCommand(L, "orange", 0xA0)
    pushCommand(L, "red", 0xB0)
    pushCommand(L, "pink", 0xC0)
    pushCommand(L, "fuchsia", 0xD0)
    pushCommand(L, "lilac", 0xE0)
    pushCommand(L, "lavender", 0xF0)

    return 1
}

/// hs.milight.new(ip[, port]) -> bridge
/// Constructor
/// Creates a new bridge object, which will be connected to the supplied IP address and port
///
/// Parameters:
///  * ip - A string containing the IP address of the MiLight WiFi bridge device. For convenience this can be the broadcast address of your network (e.g. 192.168.0.255)
///  * port - An optional number containing the UDP port to talk to the bridge on. Defaults to 8899
///
/// Returns:
///  * An `hs.milight` object
///
/// Notes:
///  * You can not use 255.255.255.255 as the IP address, to do so requires elevated privileges for the Cosmic Hammer process
private func milight_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ip = luaL_checkstring(L, 1)!
    let port: Int32

    if lua_isnone(L, 2) {
        port = 8899
    } else {
        port = Int32(luaL_checkinteger(L, 2))
    }

    let bridge = lua_newuserdata(L, MemoryLayout<BridgeData>.size)!.assumingMemoryBound(to: BridgeData.self)
    memset(bridge, 0, MemoryLayout<BridgeData>.size)

    bridge.pointee.ip = strdup(ip)
    bridge.pointee.port = port

    bridge.pointee.socket = socket(AF_INET, SOCK_DGRAM, 0)
    let ipLen = strlen(ip)
    if ipLen > 3 {
        let lastThree = ip.advanced(by: ipLen - 3)
        if strncmp(lastThree, "255", 3) == 0 {
            setsockopt(bridge.pointee.socket, SOL_SOCKET, SO_BROADCAST, &broadcastOption, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    bzero(&bridge.pointee.sockaddr, MemoryLayout<sockaddr_in>.size)
    bridge.pointee.sockaddr.sin_family = sa_family_t(AF_INET)
    bridge.pointee.sockaddr.sin_addr.s_addr = inet_addr(ip)
    bridge.pointee.sockaddr.sin_port = UInt16(port).bigEndian

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.milight:delete()
/// Method
/// Deletes an `hs.milight` object
///
/// Parameters:
///  * None
///
/// Returns:
///  * None
private func milight_del(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let bridge = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: BridgeData.self)

    if bridge.pointee.socket >= 0 {
        close(bridge.pointee.socket)
        bridge.pointee.socket = -1
    }
    if let ip = bridge.pointee.ip {
        free(ip)
        bridge.pointee.ip = nil
    }

    return 0
}

/// hs.milight:send(cmd[, value]) -> bool
/// Method
/// Sends a command to the bridge
///
/// Parameters:
///  * cmd - A command from the `hs.milight.cmd` table
///  * value - An optional value, if appropriate for the command (defaults to 0x00)
///
/// Returns:
///  * True if the command was sent, otherwise false
///
/// Notes:
///  * This is a low level command, you typically should use a specific method for the operation you want to perform
private func milight_send(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let bridge = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: BridgeData.self)

    let cmd_key = UInt8(luaL_checkinteger(L, 2))
    let value: UInt8
    if lua_isnone(L, 3) {
        value = 0x0
    } else {
        value = UInt8(luaL_checkinteger(L, 3))
    }

    var cmd: [UInt8] = [cmd_key, value, cmd_suffix]

    var addr = bridge.pointee.sockaddr
    let result = withUnsafePointer(to: &addr) { addrPtr -> ssize_t in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            sendto(bridge.pointee.socket, &cmd, 3, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    if result == 3 {
        lua_pushboolean(L, 1)
        usleep(100000) // The bridge requires we sleep for 100ms after each command
    } else {
        lua_pushboolean(L, 0)
    }

    return 1
}

// Lua/HS glue
private func milight_metagc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    _ = milight_del(L)
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let bridge = luaL_checkudata(L, 1, USERDATA_TAG)!.assumingMemoryBound(to: BridgeData.self)
    let ptr = lua_topointer(L, 1)
    let ip = bridge.pointee.ip.map { String(cString: $0) } ?? "(deleted)"
    let str = "\(USERDATA_TAG): \(ip):\(bridge.pointee.port) (\(String(describing: ptr)))" as NSString
    lua_pushstring(L, str.utf8String)
    return 1
}

private var milightlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("_cacheCommands"), func: milight_cacheCommands),
    luaL_Reg(name: strdup("new"), func: milight_new),
    luaL_Reg(name: nil, func: nil),
]

private var milight_objectlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("delete"), func: milight_del),
    luaL_Reg(name: strdup("send"), func: milight_send),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: milight_metagc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libmilight")
public func luaopen_hs_libmilight(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")  // mt.__index = mt
    luaL_setfuncs(L, &milight_objectlib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(milightlib.count - 1))
    luaL_setfuncs(L, &milightlib, 0)

    return 1
}
