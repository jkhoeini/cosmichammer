// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Implements HSExtensionsRegisterAll(L), which inserts every bundled
// luaopen_hs_lib<name> into Lua's package.preload keyed by "hs.lib<name>".
// Call after lua_State creation and before setup.lua runs so require()
// resolves bundled modules without ever touching package.cpath.
#import "HSExtensions/HSExtensions.h"
#import "HSExtensions/HSExtensions+Preload.h"

#include <LuaSkin/lauxlib.h>

void HSExtensionsRegisterAll(lua_State *L) {
    static const struct { const char *name; lua_CFunction func; } preload[] = {
        { "hs.libapplication",                     luaopen_hs_libapplication },
        { "hs.libapplicationwatcher",              luaopen_hs_libapplicationwatcher },
        { "hs.libaudiodevice",                     luaopen_hs_libaudiodevice },
        { "hs.libaudiodevicewatcher",              luaopen_hs_libaudiodevicewatcher },
        { "hs.libaxuielement",                     luaopen_hs_libaxuielement },
        { "hs.libbase64",                          luaopen_hs_libbase64 },
        { "hs.libbattery",                         luaopen_hs_libbattery },
        { "hs.libbatterywatcher",                  luaopen_hs_libbatterywatcher },
        { "hs.libbonjour",                         luaopen_hs_libbonjour },
        { "hs.libbonjourservice",                  luaopen_hs_libbonjourservice },
        { "hs.libbrightness",                      luaopen_hs_libbrightness },
        { "hs.libcaffeinate",                      luaopen_hs_libcaffeinate },
        { "hs.libcaffeinatewatcher",               luaopen_hs_libcaffeinatewatcher },
        { "hs.libcamera",                          luaopen_hs_libcamera },
        { "hs.libcanvas",                          luaopen_hs_libcanvas },
        { "hs.libcanvasmatrix",                    luaopen_hs_libcanvasmatrix },
        { "hs.libchooser",                         luaopen_hs_libchooser },
        { "hs.libconsole",                         luaopen_hs_libconsole },
        { "hs.libcrash",                           luaopen_hs_libcrash },
        { "hs.libdialog",                          luaopen_hs_libdialog },
        { "hs.libdistributednotifications",        luaopen_hs_libdistributednotifications },
        { "hs.libdoc",                             luaopen_hs_libdoc },
        { "hs.libdockicon",                        luaopen_hs_libdockicon },
        { "hs.libdrawing_color",                   luaopen_hs_libdrawing_color },
        { "hs.libeventtap",                        luaopen_hs_libeventtap },
        { "hs.libeventtapevent",                   luaopen_hs_libeventtapevent },
        { "hs.libfs",                              luaopen_hs_libfs },
        { "hs.libfsvolume",                        luaopen_hs_libfsvolume },
        { "hs.libfsxattr",                         luaopen_hs_libfsxattr },
        { "hs.libhash",                            luaopen_hs_libhash },
        { "hs.libhid",                             luaopen_hs_libhid },
        { "hs.libhints",                           luaopen_hs_libhints },
        { "hs.libhost",                            luaopen_hs_libhost },
        { "hs.libhost_locale",                     luaopen_hs_libhost_locale },
        { "hs.libhotkey",                          luaopen_hs_libhotkey },
        { "hs.libhttp",                            luaopen_hs_libhttp },
        { "hs.libhttpserver",                      luaopen_hs_libhttpserver },
        { "hs.libimage",                           luaopen_hs_libimage },
        { "hs.libipc",                             luaopen_hs_libipc },
        { "hs.libjson",                            luaopen_hs_libjson },
        { "hs.libkeycodes",                        luaopen_hs_libkeycodes },
        { "hs.liblocation",                        luaopen_hs_liblocation },
        { "hs.liblsqlite3",                        luaopen_hs_liblsqlite3 },
        { "hs.libmarkdown",                        luaopen_hs_libmarkdown },
        { "hs.libmath",                            luaopen_hs_libmath },
        { "hs.libmenubar",                         luaopen_hs_libmenubar },
        { "hs.libmidi",                            luaopen_hs_libmidi },
        { "hs.libmilight",                         luaopen_hs_libmilight },
        { "hs.libmouse",                           luaopen_hs_libmouse },
        { "hs.libnetworkconfiguration",            luaopen_hs_libnetworkconfiguration },
        { "hs.libnetworkhost",                     luaopen_hs_libnetworkhost },
        { "hs.libnetworkping",                     luaopen_hs_libnetworkping },
        { "hs.libnetworkreachability",             luaopen_hs_libnetworkreachability },
        { "hs.libnoises",                          luaopen_hs_libnoises },
        { "hs.libnotify",                          luaopen_hs_libnotify },
        { "hs.libosascript",                       luaopen_hs_libosascript },
        { "hs.libpasteboard",                      luaopen_hs_libpasteboard },
        { "hs.libpasteboardwatcher",               luaopen_hs_libpasteboardwatcher },
        { "hs.libpathwatcher",                     luaopen_hs_libpathwatcher },
        { "hs.libplist",                           luaopen_hs_libplist },
        { "hs.librazer",                           luaopen_hs_librazer },
        { "hs.libscreen",                          luaopen_hs_libscreen },
        { "hs.libscreenwatcher",                   luaopen_hs_libscreenwatcher },
        { "hs.libserial",                          luaopen_hs_libserial },
        { "hs.libsettings",                        luaopen_hs_libsettings },
        { "hs.libsharing",                         luaopen_hs_libsharing },
        { "hs.libshortcuts",                       luaopen_hs_libshortcuts },
        { "hs.libsocket",                          luaopen_hs_libsocket },
        { "hs.libsocketudp",                       luaopen_hs_libsocketudp },
        { "hs.libsound",                           luaopen_hs_libsound },
        { "hs.libspaces",                          luaopen_hs_libspaces },
        { "hs.libspaces_watcher",                  luaopen_hs_libspaces_watcher },
        { "hs.libspeech",                          luaopen_hs_libspeech },
        { "hs.libspeechlistener",                  luaopen_hs_libspeechlistener },
        { "hs.libspotlight",                       luaopen_hs_libspotlight },
        { "hs.libstreamdeck",                      luaopen_hs_libstreamdeck },
        { "hs.libstyledtext",                      luaopen_hs_libstyledtext },
        { "hs.libtask",                            luaopen_hs_libtask },
        { "hs.libtimer",                           luaopen_hs_libtimer },
        { "hs.libuielement",                       luaopen_hs_libuielement },
        { "hs.libuielementwatcher",                luaopen_hs_libuielementwatcher },
        { "hs.liburlevent",                        luaopen_hs_liburlevent },
        { "hs.libusb",                             luaopen_hs_libusb },
        { "hs.libusbwatcher",                      luaopen_hs_libusbwatcher },
        { "hs.libwebsocket",                       luaopen_hs_libwebsocket },
        { "hs.libwebview",                         luaopen_hs_libwebview },
        { "hs.libwebviewdatastore",                luaopen_hs_libwebviewdatastore },
        { "hs.libwebviewtoolbar",                  luaopen_hs_libwebviewtoolbar },
        { "hs.libwebviewusercontent",              luaopen_hs_libwebviewusercontent },
        { "hs.libwifi",                            luaopen_hs_libwifi },
        { "hs.libwifiwatcher",                     luaopen_hs_libwifiwatcher },
        { "hs.libwindow",                          luaopen_hs_libwindow },
        { NULL, NULL }
    };

    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    for (size_t i = 0; preload[i].name; i++) {
        lua_pushcfunction(L, preload[i].func);
        lua_setfield(L, -2, preload[i].name);
    }
    lua_pop(L, 1);  // pop _PRELOAD table
}
