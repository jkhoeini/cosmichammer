import Foundation
import CLua
import Lua
import Cocoa

private let USERDATA_TAG = "hs.midi"

private func midi_removed(_ L: LuaState) throws -> CInt {
    throw LuaCallError("hs.midi has been removed (MIKMIDI dependency dropped)")
}

@_cdecl("luaopen_hs_libmidi")
func luaopen_hs_libmidi(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 5)
        L.push(midi_removed)
        lua_setfield(L, -2, "new")
        L.push(midi_removed)
        lua_setfield(L, -2, "newVirtualSource")
        L.push(midi_removed)
        lua_setfield(L, -2, "devices")
        L.push(midi_removed)
        lua_setfield(L, -2, "virtualSources")
        L.push(midi_removed)
        lua_setfield(L, -2, "deviceCallback")
    }
}
