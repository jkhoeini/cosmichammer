// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Registers all bundled extension entry points into Lua's package.preload table.
// Call after lua_State creation and before setup.lua runs.
//
// Every entry point is imported via @_silgen_name so the Swift function name
// is decoupled from the C symbol name (handles both @_cdecl Swift funcs and
// C-implemented funcs like lsqlite3).
import CLua

// MARK: - Forward declarations (C symbol imports)

@_silgen_name("luaopen_hs_libapplication")
private func _import_luaopen_hs_libapplication(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libapplicationwatcher")
private func _import_luaopen_hs_libapplicationwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libaudiodevice")
private func _import_luaopen_hs_libaudiodevice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libaudiodevicewatcher")
private func _import_luaopen_hs_libaudiodevicewatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libaxuielement")
private func _import_luaopen_hs_libaxuielement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libbase64")
private func _import_luaopen_hs_libbase64(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libbattery")
private func _import_luaopen_hs_libbattery(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libbatterywatcher")
private func _import_luaopen_hs_libbatterywatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libbonjour")
private func _import_luaopen_hs_libbonjour(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libbonjourservice")
private func _import_luaopen_hs_libbonjourservice(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libbrightness")
private func _import_luaopen_hs_libbrightness(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libcaffeinate")
private func _import_luaopen_hs_libcaffeinate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libcaffeinatewatcher")
private func _import_luaopen_hs_libcaffeinatewatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libcamera")
private func _import_luaopen_hs_libcamera(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libcanvas")
private func _import_luaopen_hs_libcanvas(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libcanvasmatrix")
private func _import_luaopen_hs_libcanvasmatrix(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libchooser")
private func _import_luaopen_hs_libchooser(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libconsole")
private func _import_luaopen_hs_libconsole(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libcrash")
private func _import_luaopen_hs_libcrash(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libdialog")
private func _import_luaopen_hs_libdialog(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libdistributednotifications")
private func _import_luaopen_hs_libdistributednotifications(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libdoc")
private func _import_luaopen_hs_libdoc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libdockicon")
private func _import_luaopen_hs_libdockicon(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libdrawing_color")
private func _import_luaopen_hs_libdrawing_color(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libeventtap")
private func _import_luaopen_hs_libeventtap(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libeventtapevent")
private func _import_luaopen_hs_libeventtapevent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libfs")
private func _import_luaopen_hs_libfs(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libfsvolume")
private func _import_luaopen_hs_libfsvolume(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libfsxattr")
private func _import_luaopen_hs_libfsxattr(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhash")
private func _import_luaopen_hs_libhash(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhid")
private func _import_luaopen_hs_libhid(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhints")
private func _import_luaopen_hs_libhints(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhost")
private func _import_luaopen_hs_libhost(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhost_locale")
private func _import_luaopen_hs_libhost_locale(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhotkey")
private func _import_luaopen_hs_libhotkey(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhttp")
private func _import_luaopen_hs_libhttp(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libhttpserver")
private func _import_luaopen_hs_libhttpserver(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libimage")
private func _import_luaopen_hs_libimage(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libipc")
private func _import_luaopen_hs_libipc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libjson")
private func _import_luaopen_hs_libjson(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libkeycodes")
private func _import_luaopen_hs_libkeycodes(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_liblocation")
private func _import_luaopen_hs_liblocation(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_liblsqlite3")
private func _import_luaopen_hs_liblsqlite3(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libmarkdown")
private func _import_luaopen_hs_libmarkdown(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libmath")
private func _import_luaopen_hs_libmath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libmenubar")
private func _import_luaopen_hs_libmenubar(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libmidi")
private func _import_luaopen_hs_libmidi(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libmilight")
private func _import_luaopen_hs_libmilight(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libmouse")
private func _import_luaopen_hs_libmouse(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libnetworkconfiguration")
private func _import_luaopen_hs_libnetworkconfiguration(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libnetworkhost")
private func _import_luaopen_hs_libnetworkhost(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libnetworkping")
private func _import_luaopen_hs_libnetworkping(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libnetworkreachability")
private func _import_luaopen_hs_libnetworkreachability(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libnoises")
private func _import_luaopen_hs_libnoises(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libnotify")
private func _import_luaopen_hs_libnotify(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libosascript")
private func _import_luaopen_hs_libosascript(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libpasteboard")
private func _import_luaopen_hs_libpasteboard(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libpasteboardwatcher")
private func _import_luaopen_hs_libpasteboardwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libpathwatcher")
private func _import_luaopen_hs_libpathwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libplist")
private func _import_luaopen_hs_libplist(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_librazer")
private func _import_luaopen_hs_librazer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libscreen")
private func _import_luaopen_hs_libscreen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libscreenwatcher")
private func _import_luaopen_hs_libscreenwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libserial")
private func _import_luaopen_hs_libserial(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libsettings")
private func _import_luaopen_hs_libsettings(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libsharing")
private func _import_luaopen_hs_libsharing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libshortcuts")
private func _import_luaopen_hs_libshortcuts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libsocket")
private func _import_luaopen_hs_libsocket(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libsocketudp")
private func _import_luaopen_hs_libsocketudp(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libsound")
private func _import_luaopen_hs_libsound(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libspaces")
private func _import_luaopen_hs_libspaces(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libspaces_watcher")
private func _import_luaopen_hs_libspaces_watcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libspeech")
private func _import_luaopen_hs_libspeech(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libspeechlistener")
private func _import_luaopen_hs_libspeechlistener(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libspotlight")
private func _import_luaopen_hs_libspotlight(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libstreamdeck")
private func _import_luaopen_hs_libstreamdeck(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libstyledtext")
private func _import_luaopen_hs_libstyledtext(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libtask")
private func _import_luaopen_hs_libtask(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libtimer")
private func _import_luaopen_hs_libtimer(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libuielement")
private func _import_luaopen_hs_libuielement(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libuielementwatcher")
private func _import_luaopen_hs_libuielementwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_liburlevent")
private func _import_luaopen_hs_liburlevent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libusb")
private func _import_luaopen_hs_libusb(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libusbwatcher")
private func _import_luaopen_hs_libusbwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwebsocket")
private func _import_luaopen_hs_libwebsocket(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwebview")
private func _import_luaopen_hs_libwebview(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwebviewdatastore")
private func _import_luaopen_hs_libwebviewdatastore(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwebviewtoolbar")
private func _import_luaopen_hs_libwebviewtoolbar(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwebviewusercontent")
private func _import_luaopen_hs_libwebviewusercontent(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwifi")
private func _import_luaopen_hs_libwifi(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwifiwatcher")
private func _import_luaopen_hs_libwifiwatcher(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

@_silgen_name("luaopen_hs_libwindow")
private func _import_luaopen_hs_libwindow(_ L: UnsafeMutablePointer<lua_State>!) -> Int32

// MARK: - Registration

/// Registers every bundled hs.lib<name> entry point with package.preload.
/// Call after lua_State creation and before setup.lua runs.
@_cdecl("HSExtensionsRegisterAll")
func hsExtensionsRegisterAll(_ L: UnsafeMutablePointer<lua_State>!) {
    let preload: [(String, @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32)] = [
        ("hs.libapplication", _import_luaopen_hs_libapplication),
        ("hs.libapplicationwatcher", _import_luaopen_hs_libapplicationwatcher),
        ("hs.libaudiodevice", _import_luaopen_hs_libaudiodevice),
        ("hs.libaudiodevicewatcher", _import_luaopen_hs_libaudiodevicewatcher),
        ("hs.libaxuielement", _import_luaopen_hs_libaxuielement),
        ("hs.libbase64", _import_luaopen_hs_libbase64),
        ("hs.libbattery", _import_luaopen_hs_libbattery),
        ("hs.libbatterywatcher", _import_luaopen_hs_libbatterywatcher),
        ("hs.libbonjour", _import_luaopen_hs_libbonjour),
        ("hs.libbonjourservice", _import_luaopen_hs_libbonjourservice),
        ("hs.libbrightness", _import_luaopen_hs_libbrightness),
        ("hs.libcaffeinate", _import_luaopen_hs_libcaffeinate),
        ("hs.libcaffeinatewatcher", _import_luaopen_hs_libcaffeinatewatcher),
        ("hs.libcamera", _import_luaopen_hs_libcamera),
        ("hs.libcanvas", _import_luaopen_hs_libcanvas),
        ("hs.libcanvasmatrix", _import_luaopen_hs_libcanvasmatrix),
        ("hs.libchooser", _import_luaopen_hs_libchooser),
        ("hs.libconsole", _import_luaopen_hs_libconsole),
        ("hs.libcrash", _import_luaopen_hs_libcrash),
        ("hs.libdialog", _import_luaopen_hs_libdialog),
        ("hs.libdistributednotifications", _import_luaopen_hs_libdistributednotifications),
        ("hs.libdoc", _import_luaopen_hs_libdoc),
        ("hs.libdockicon", _import_luaopen_hs_libdockicon),
        ("hs.libdrawing_color", _import_luaopen_hs_libdrawing_color),
        ("hs.libeventtap", _import_luaopen_hs_libeventtap),
        ("hs.libeventtapevent", _import_luaopen_hs_libeventtapevent),
        ("hs.libfs", _import_luaopen_hs_libfs),
        ("hs.libfsvolume", _import_luaopen_hs_libfsvolume),
        ("hs.libfsxattr", _import_luaopen_hs_libfsxattr),
        ("hs.libhash", _import_luaopen_hs_libhash),
        ("hs.libhid", _import_luaopen_hs_libhid),
        ("hs.libhints", _import_luaopen_hs_libhints),
        ("hs.libhost", _import_luaopen_hs_libhost),
        ("hs.libhost_locale", _import_luaopen_hs_libhost_locale),
        ("hs.libhotkey", _import_luaopen_hs_libhotkey),
        ("hs.libhttp", _import_luaopen_hs_libhttp),
        ("hs.libhttpserver", _import_luaopen_hs_libhttpserver),
        ("hs.libimage", _import_luaopen_hs_libimage),
        ("hs.libipc", _import_luaopen_hs_libipc),
        ("hs.libjson", _import_luaopen_hs_libjson),
        ("hs.libkeycodes", _import_luaopen_hs_libkeycodes),
        ("hs.liblocation", _import_luaopen_hs_liblocation),
        ("hs.liblsqlite3", _import_luaopen_hs_liblsqlite3),
        ("hs.libmarkdown", _import_luaopen_hs_libmarkdown),
        ("hs.libmath", _import_luaopen_hs_libmath),
        ("hs.libmenubar", _import_luaopen_hs_libmenubar),
        ("hs.libmidi", _import_luaopen_hs_libmidi),
        ("hs.libmilight", _import_luaopen_hs_libmilight),
        ("hs.libmouse", _import_luaopen_hs_libmouse),
        ("hs.libnetworkconfiguration", _import_luaopen_hs_libnetworkconfiguration),
        ("hs.libnetworkhost", _import_luaopen_hs_libnetworkhost),
        ("hs.libnetworkping", _import_luaopen_hs_libnetworkping),
        ("hs.libnetworkreachability", _import_luaopen_hs_libnetworkreachability),
        ("hs.libnoises", _import_luaopen_hs_libnoises),
        ("hs.libnotify", _import_luaopen_hs_libnotify),
        ("hs.libosascript", _import_luaopen_hs_libosascript),
        ("hs.libpasteboard", _import_luaopen_hs_libpasteboard),
        ("hs.libpasteboardwatcher", _import_luaopen_hs_libpasteboardwatcher),
        ("hs.libpathwatcher", _import_luaopen_hs_libpathwatcher),
        ("hs.libplist", _import_luaopen_hs_libplist),
        ("hs.librazer", _import_luaopen_hs_librazer),
        ("hs.libscreen", _import_luaopen_hs_libscreen),
        ("hs.libscreenwatcher", _import_luaopen_hs_libscreenwatcher),
        ("hs.libserial", _import_luaopen_hs_libserial),
        ("hs.libsettings", _import_luaopen_hs_libsettings),
        ("hs.libsharing", _import_luaopen_hs_libsharing),
        ("hs.libshortcuts", _import_luaopen_hs_libshortcuts),
        ("hs.libsocket", _import_luaopen_hs_libsocket),
        ("hs.libsocketudp", _import_luaopen_hs_libsocketudp),
        ("hs.libsound", _import_luaopen_hs_libsound),
        ("hs.libspaces", _import_luaopen_hs_libspaces),
        ("hs.libspaces_watcher", _import_luaopen_hs_libspaces_watcher),
        ("hs.libspeech", _import_luaopen_hs_libspeech),
        ("hs.libspeechlistener", _import_luaopen_hs_libspeechlistener),
        ("hs.libspotlight", _import_luaopen_hs_libspotlight),
        ("hs.libstreamdeck", _import_luaopen_hs_libstreamdeck),
        ("hs.libstyledtext", _import_luaopen_hs_libstyledtext),
        ("hs.libtask", _import_luaopen_hs_libtask),
        ("hs.libtimer", _import_luaopen_hs_libtimer),
        ("hs.libuielement", _import_luaopen_hs_libuielement),
        ("hs.libuielementwatcher", _import_luaopen_hs_libuielementwatcher),
        ("hs.liburlevent", _import_luaopen_hs_liburlevent),
        ("hs.libusb", _import_luaopen_hs_libusb),
        ("hs.libusbwatcher", _import_luaopen_hs_libusbwatcher),
        ("hs.libwebsocket", _import_luaopen_hs_libwebsocket),
        ("hs.libwebview", _import_luaopen_hs_libwebview),
        ("hs.libwebviewdatastore", _import_luaopen_hs_libwebviewdatastore),
        ("hs.libwebviewtoolbar", _import_luaopen_hs_libwebviewtoolbar),
        ("hs.libwebviewusercontent", _import_luaopen_hs_libwebviewusercontent),
        ("hs.libwifi", _import_luaopen_hs_libwifi),
        ("hs.libwifiwatcher", _import_luaopen_hs_libwifiwatcher),
        ("hs.libwindow", _import_luaopen_hs_libwindow),
    ]

    luaL_getsubtable(L, LUA_REGISTRYINDEX_VALUE, "_PRELOAD")
    for (name, fn) in preload {
        lua_pushcclosure(L, fn, 0)
        lua_setfield(L, -2, name)
    }
    lua_pop(L, 1)
}
