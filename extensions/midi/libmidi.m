@import Foundation;
@import Cocoa;
@import LuaSkin;

static const char *USERDATA_TAG = "hs.midi";

static int midi_removed(lua_State *L) {
    return luaL_error(L, "hs.midi has been removed (MIKMIDI dependency dropped)");
}

static const luaL_Reg moduleLib[] = {
    {"new", midi_removed},
    {"newVirtualSource", midi_removed},
    {"devices", midi_removed},
    {"virtualSources", midi_removed},
    {"deviceCallback", midi_removed},
    {NULL, NULL}
};

static const luaL_Reg module_metaLib[] = {
    {NULL, NULL}
};

int luaopen_hs_libmidi(lua_State* L) {
    LuaSkin *skin = [LuaSkin sharedWithState:L];
    [skin registerLibrary:USERDATA_TAG functions:moduleLib metaFunctions:module_metaLib];
    return 1;
}
