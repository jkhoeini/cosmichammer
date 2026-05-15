import Foundation
import Cocoa
import LuaSkin

private let USERDATA_TAG = "hs.midi"

private func midi_removed(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return luaL_error(L, "hs.midi has been removed (MIKMIDI dependency dropped)")
}

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"),              func: midi_removed),
    luaL_Reg(name: strdup("newVirtualSource"), func: midi_removed),
    luaL_Reg(name: strdup("devices"),          func: midi_removed),
    luaL_Reg(name: strdup("virtualSources"),   func: midi_removed),
    luaL_Reg(name: strdup("deviceCallback"),   func: midi_removed),
    luaL_Reg(name: nil,                        func: nil),
]

private var module_metaLib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libmidi")
func luaopen_hs_libmidi(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.registerLibrary(USERDATA_TAG, functions: &moduleLib, metaFunctions: &module_metaLib)
    return 1
}
