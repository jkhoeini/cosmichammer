# Plan: Consolidate Hammerspoon's 91 Extension Dylibs into a Single Statically-Linked SPM Target

## Executive Summary

- **The architecture is trivially consolidatable.** All 94 `luaopen_hs_*` entry points have globally unique names; cross-extension dependencies exist only at the Lua `require()` layer, never in C/ObjC; almost no extension target links its own framework (4 SPM products + Accelerate/CoreAudio for `noises` + `libsqlite3.tbd` cover every special case); `-undefined dynamic_lookup` is already universal so extensions' "framework requirements" are just transitive from the main app.
- **One new SPM package**, `Packages/HSExtensions/`, will hold every extension's C/ObjC sources as a single `cTarget` (mixed-language SPM target with publicHeadersPath), producing a static library `libHSExtensions.a`. The existing `Packages/LuaSkin/` package gains nothing; keeping HSExtensions separate avoids dragging extensions into the LuaSkin product graph.
- **At Lua-state creation**, a generated function `HSExtensionsRegisterAll(lua_State *L)` walks the `package.preload` table and inserts every `luaopen_hs_lib<name>` keyed by `"hs.lib<name>"`. This is hot enough to add before `setup.lua` runs in `MJLua.m:706`. With preload entries present, Lua's `require("hs.libwindow")` never reaches `package.cpath`, so no dlopen ever occurs.
- **Dead-stripping is prevented** by adding a single generated source file `HSExtensionsRegistry.m` to the main app's PBXSourcesBuildPhase. Each `luaopen_*` is named in the static registry array — the linker sees real references and keeps every symbol. This is portable across SPM/xcode toolchains and survives Release builds (Hammerspoon Release uses `-O0` per `Project-Base.xcconfig`, but we don't want to rely on that). `-force_load` is the fallback if symbol-array proves insufficient on some symbol.
- **The xcodeproj keeps doing app-bundle work** (signing, Info.plist, entitlements, resource copying, test hosting, the `hs` CLI tool, version stamping) but drops 91 PBXNativeTarget + 91 PBXTargetDependency entries + the `Frameworks/hs/` copy phase. Result: pbxproj shrinks from ~11,865 lines to roughly 4,500. `swift build` becomes meaningful for the compile-heavy part; `xcodebuild` only assembles the bundle.

---

## Pre-flight Investigation (verify before changing)

Run these checks once at start of work and stop if any premise breaks. They re-verify everything established during planning.

### P1. Symbol uniqueness across all `luaopen_*` entry points
```
cd /Users/mohammadk/Dev/hammerspoon
grep -RhEo '^int luaopen_[a-zA-Z0-9_]+' extensions --include='*.m' --include='*.c' | sort | uniq -c | awk '$1 > 1'
```
Expected: empty output. (94 unique names; 92 are `luaopen_hs_lib*`, plus `luaopen_hs_libaxuielementobserver` and `luaopen_hs_axuielement_axtextmarker` which are sub-modules registered manually inside `libaxuielement.m`.)

### P2. Non-static helper name collisions across extensions
```
grep -RhEo '^[a-zA-Z][a-zA-Z0-9_ \*]*\s+([a-z_][a-zA-Z0-9_]+)\s*\(' \
  extensions --include='*.m' --include='*.c' --include='*.cpp' \
  | grep -v '^static\|^extern' \
  | sed -E 's/.*\b([a-z_][a-zA-Z0-9_]+)[[:space:]]*\(.*/\1/' \
  | sort | uniq -c | sort -rn | awk '$1 > 1'
```
Expected duplicates (`watcherStop`, `screen_gammaReapply`, `erase_menu_items`, `hidled_set`, `sigint_handler`) are all duplicate **declaration + definition within one Xcode target**, not cross-target. Verify nothing changed.

### P3. Non-trivial build phases per extension
```
grep -nE 'COMPILER_FLAGS' Hammerspoon.xcodeproj/project.pbxproj
```
Expected: exactly two — `lsqlite3.c` (`-Wno-float-equal -Wno-unused-macros`) and `libaudiodevice_watcher.m` (`-std=c99`). These need per-file flags in the SPM target.

### P4. Extensions with Swift / ObjC++ / C++ sources
```
find extensions \( -name "*.swift" -o -name "*.mm" -o -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" \)
```
Expected: only `extensions/noises/detectors.cpp`. SPM cTargets support C++ sources alongside ObjC sources transparently as long as `cxxLanguageStandard` is set on the package or the file extension is `.cpp`.

### P5. Per-extension framework links
```
grep 'in Frameworks \*/ =' Hammerspoon.xcodeproj/project.pbxproj | grep -v 'fileRef = .*\.dylib' | grep -v BuildFile
```
Confirm only these explicit links exist:
- `noises` → `Accelerate.framework`, `CoreAudio.framework`
- `sqlite3` (target `lsqlite3`) → `libsqlite3.tbd`
- `httpserver` → `CocoaHTTPServer` (SPM), `CocoaLumberjack` (SPM)
- `serial`, `websocket` → `ORSSerial` (SPM)
- `socket`, `socketudp` → `CocoaAsyncSocket` (SPM)
- `hs` CLI → `libedit.tbd`, `CoreFoundation`, `Foundation`

Everything else relies on the main app's frameworks via `-undefined dynamic_lookup`.

### P6. Vendored C dependencies
- `extensions/doc/` ships a markdown C library (`autolink.c`, `buffer.c`, `houdini_href_e.c`, `houdini_html_e.c`, `html.c`, `markdown.c`, `plaintext.c`, `stack.c`, plus headers). All symbols prefixed `houdini_*`, `bufnew`, etc.
- `extensions/sqlite3/lsqlite3.c` — pure Lua-binding C, dynamically links system sqlite via `-lsqlite3`.
- `extensions/network/ping/SimplePing.[hm]` — Apple sample code, single Obj-C class `SimplePing`.
- `extensions/eventtap/TouchEvents.c`, `IOHIDEventData.h`, `IOHIDEventTypes.h` — reverse-engineered system headers.
- `extensions/utf8/utf8.lua`, `extensions/inspect/inspect.lua` are pure Lua (third-party).

### P7. Duplicate file names across extensions (collision check)
```
find extensions -type f \( -name "*.m" -o -name "*.c" -o -name "*.cpp" \) -exec basename {} \; | sort | uniq -d
```
SPM doesn't care about basenames colliding (it tracks full paths), but it's still worth confirming there are no surprises. Expected: empty (all `lib<name>.m` files are uniquely named).

### P8. Headers intentionally hiding internal symbols
```
grep -rnE 'visibility\("hidden"\)|__private_extern__' extensions Hammerspoon
```
Expected: empty.

### P9. Extensions that dlopen other dylibs
```
grep -RnE 'package\.loadlib|dlopen|dlsym' Hammerspoon extensions --include="*.lua" --include="*.m" --include="*.c"
```
The only matches that load **Hammerspoon dylibs**: zero. `extensions/brightness/brightness.lua` and `extensions/screen/screen.lua` call `package.loadlib` on `/System/Library/PrivateFrameworks/DisplayServices.framework/...` — that's a macOS private framework, not a Hammerspoon extension. `extensions/screen/libscreen.m:18` uses `dlsym(RTLD_DEFAULT, "CGDisplayCreateImageForRect")` — also fine, that's looking up a system symbol. **Leave Lua's `package.cpath` machinery intact** so `hs.doc.locateJSONFile` (extensions/doc/doc.lua:187) and any third-party `package.loadlib` calls keep working.

### P10. Files to read in full before starting
- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon/MJLua.m` (esp. lines 687–767, the Lua state lifecycle)
- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon/setup.lua` (whole file, 67 lines)
- `/Users/mohammadk/Dev/hammerspoon/extensions/_coresetup/_coresetup.lua` (lines 436–464 and 651–660 in particular)
- `/Users/mohammadk/Dev/hammerspoon/Packages/LuaSkin/Package.swift`
- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon/Build Configs/Extensions-Base.xcconfig` and `Extensions-Ideal.xcconfig`
- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon/Build Configs/Project-Base.xcconfig`
- `/Users/mohammadk/Dev/hammerspoon/blueprint.org` lines 1–110 for context

---

## Architecture: target shape after consolidation

### New package: `Packages/HSExtensions/`

```
Packages/HSExtensions/
├── Package.swift                  # one target, ~94 cSettings entries
└── Sources/
    └── HSExtensions/
        ├── include/
        │   └── HSExtensions/
        │       └── HSExtensions.h     # declares HSExtensionsRegisterAll
        ├── HSExtensions.m              # implements HSExtensionsRegisterAll (generated)
        ├── HSExtensions+Preload.h      # generated forward-declares all luaopen_* (generated)
        ├── application/                # symlink to ../../../../extensions/application/
        ├── audiodevice/                # symlink
        ├── ...                         # one symlink per extension directory
        └── _vendor/                    # if needed, ws code that's not strictly an extension
```

Use **symlinks** (not file copies) so the extension source-of-truth stays in `extensions/<name>/`. The implementation agent's first commit moves zero files. Use `ln -s` relative paths so the repo remains portable. SPM follows symlinks for source enumeration.

Alternative if symlinks cause SPM scanning headaches in CI: use `swiftSettings.headerSearchPath` + an explicit `sources:` list pointing at relative paths under the repo root via `..`. SPM allows `../` in path-relative source enumeration. **Try the symlink approach first** — it's the cleanest.

### Generated artifacts (regenerated by a script, not hand-edited)

Two files are generated from a single source of truth — the list of `luaopen_hs_*` symbols discovered by grep:

1. `Packages/HSExtensions/Sources/HSExtensions/HSExtensions+Preload.h` — forward declarations.
2. `Packages/HSExtensions/Sources/HSExtensions/HSExtensions.m` — the registration function.
3. `Hammerspoon/HSExtensionsRegistry.m` — the keep-alive array in the **main app target** (the static-archive linker resolves keep-alive via this).

Concretely, `scripts/generate-hsextensions.sh` (a new script — but the implementation agent can keep it in-tree without invoking it from xcodebuild; manual regeneration is fine for a low-churn list):

```bash
#!/usr/bin/env bash
# Regenerates HSExtensions glue. Re-run after adding/removing an extension's
# luaopen_* entry point.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_H="Packages/HSExtensions/Sources/HSExtensions/HSExtensions+Preload.h"
OUT_M="Packages/HSExtensions/Sources/HSExtensions/HSExtensions.m"
OUT_REG="Hammerspoon/HSExtensionsRegistry.m"

# Discover every luaopen_hs_* entry point in the extensions tree.
symbols=$(grep -RhEo 'int luaopen_hs_[a-zA-Z0-9_]+' extensions --include='*.m' --include='*.c' \
  | awk '{print $NF}' | sort -u)

# Compute module name for require() key by stripping "luaopen_hs_" prefix.
# e.g. luaopen_hs_libwindow → hs.libwindow
# Special cases: luaopen_hs_axuielement_axtextmarker → hs.axuielement.axtextmarker
#                (but this one is registered internally by libaxuielement.m
#                 and is NOT exposed via package.preload; it lives at module.axtextmarker.
#                 The script must EXCLUDE these "internally registered" symbols
#                 — keep an explicit exclusion list below.)

INTERNAL_ONLY=(
  luaopen_hs_libaxuielementobserver      # registered by libaxuielement.m
  luaopen_hs_axuielement_axtextmarker    # registered by libaxuielement.m
)
```

The script then emits the three files (snippets below).

### Generated: `HSExtensions+Preload.h`
```c
// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
#pragma once
#include <lua/lua.h>

#ifdef __cplusplus
extern "C" {
#endif

int luaopen_hs_libapplication(lua_State *L);
int luaopen_hs_libapplicationwatcher(lua_State *L);
int luaopen_hs_libaudiodevice(lua_State *L);
int luaopen_hs_libaudiodevicewatcher(lua_State *L);
int luaopen_hs_libaxuielement(lua_State *L);
int luaopen_hs_libbase64(lua_State *L);
/* ... ~88 more, one per extension symbol that should be preloaded ... */
int luaopen_hs_libwindow(lua_State *L);

#ifdef __cplusplus
}
#endif
```

### Generated: `HSExtensions.m`
```objective-c
// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
#import "HSExtensions.h"
#import "HSExtensions+Preload.h"

void HSExtensionsRegisterAll(lua_State *L) {
    static const struct { const char *name; lua_CFunction func; } preload[] = {
        { "hs.libapplication",         luaopen_hs_libapplication },
        { "hs.libapplicationwatcher",  luaopen_hs_libapplicationwatcher },
        { "hs.libaudiodevice",         luaopen_hs_libaudiodevice },
        { "hs.libaudiodevicewatcher",  luaopen_hs_libaudiodevicewatcher },
        { "hs.libaxuielement",         luaopen_hs_libaxuielement },
        { "hs.libbase64",              luaopen_hs_libbase64 },
        /* ... ~88 more entries ... */
        { "hs.libwindow",              luaopen_hs_libwindow },
        { NULL, NULL }
    };

    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    for (size_t i = 0; preload[i].name; i++) {
        lua_pushcfunction(L, preload[i].func);
        lua_setfield(L, -2, preload[i].name);
    }
    lua_pop(L, 1);  // pop _PRELOAD table
}
```

### Generated: `Hammerspoon/HSExtensionsRegistry.m` (in the main app target)
```objective-c
// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Purpose: prevent the static linker from dead-stripping the luaopen_hs_*
// entry points out of libHSExtensions.a. Each symbol is referenced from a
// __used array so the linker keeps the archive object alive.
#import "HSExtensions+Preload.h"

__attribute__((used))
static void * const _HSExtensionsKeepAlive[] = {
    (void *)&luaopen_hs_libapplication,
    (void *)&luaopen_hs_libapplicationwatcher,
    /* ... one per symbol, same list as HSExtensions.m ... */
    (void *)&luaopen_hs_libwindow,
};
```

The `__attribute__((used))` on the array tells the compiler to emit it; each function-pointer reference forces the linker to pull that object file from the archive. This is the safest dead-strip prevention for static libraries on Apple's `ld`. (`-force_load` is the fallback in `OTHER_LDFLAGS` if anything still gets stripped — see Section 6.)

### `Packages/HSExtensions/Package.swift`
```swift
// swift-tools-version:5.9
import PackageDescription

let extensionSourcePaths: [String] = [
    "application/libapplication.m",
    "application/libapplication_watcher.m",
    "audiodevice/libaudiodevice.m",
    "audiodevice/libaudiodevice_watcher.m",
    "axuielement/libaxuielement.m",
    "axuielement/common.m",
    "axuielement/observer.m",
    "axuielement/axtextmarker.m",
    "base64/libbase64.m",
    "battery/libbattery.m",
    "battery/libbattery_watcher.m",
    "bonjour/libbonjoir.m",                 // typo in the source filename, NOT the symbol
    "bonjour/libbonjour_service.m",
    "brightness/libbrightness.m",
    "caffeinate/libcaffeinate.m",
    "caffeinate/libcaffeinate_watcher.m",
    "camera/libcamera.m",
    "canvas/libcanvas.m",
    "canvas/libcanvas_matrix.m",
    "canvas/imageAdditions.m",
    "chooser/libchooser.m",
    "chooser/HSChooser.m",
    "chooser/HSChooserCell.m",
    "chooser/HSChooserRootView.m",
    "chooser/HSChooserTableView.m",
    "chooser/HSChooserVerticallyCenteringTextFieldCell.m",
    "chooser/HSChooserWindow.m",
    "console/libconsole.m",
    "crash/libcrash.m",
    "dialog/libdialog.m",
    "distributednotifications/libdistributednotifications.m",
    "doc/libdoc.m",
    "doc/markdown.m",
    "doc/autolink.c",
    "doc/buffer.c",
    "doc/houdini_href_e.c",
    "doc/houdini_html_e.c",
    "doc/html.c",
    "doc/markdown.c",
    "doc/plaintext.c",
    "doc/stack.c",
    "dockicon/libdockicon.m",
    "drawing/color/libdrawing_color.m",
    "eventtap/libeventtap.m",
    "eventtap/libeventtap_event.m",
    "eventtap/TouchEvents.c",
    "fs/libfs.m",
    "fs/libfs_volume.m",
    "fs/libfs_xattr.m",
    "hash/libhash.m",
    "hash/algorithms.m",
    "hash/sha3.m",
    "hid/libhid.m",
    "hid/led.m",
    "hints/internal.m",
    "host/libhost.m",
    "host/locale/libhost_locale.m",
    "hotkey/libhotkey.m",
    "http/libhttp.m",
    "httpserver/libhttpserver.m",
    "httpserver/MYAnonymousIdentity.m",
    "image/libimage.m",
    "ipc/libipc.m",                          // NOTE: do NOT include extensions/ipc/cli/hs.m
    "json/libjson.m",
    "keycodes/libkeycodes.m",
    "location/liblocation.m",
    "location/EDSunriseSet.m",
    "math/libmath.m",
    "menubar/libmenubar.m",
    "midi/libmidi.m",
    "milight/libmilight.m",
    "mouse/libmouse.m",
    "network/libnetwork_configuration.m",
    "network/libnetwork_host.m",
    "network/libnetwork_reachability.m",
    "network/ping/libnetwork_ping.m",
    "network/ping/SimplePing.m",
    "noises/libnoises.m",
    "noises/detectors.cpp",
    "notify/libnotify.m",
    "osascript/libosascript.m",
    "osascript/NSAppleEventDescriptor+Parsing.m",
    "pasteboard/libpasteboard.m",
    "pasteboard/libpasteboard_watcher.m",
    "pathwatcher/libpathwatcher.m",
    "plist/libplist.m",
    "razer/librazer.m",
    "razer/HSRazerDevice.m",
    "razer/HSRazerManager.m",
    "razer/HSRazerTartarusV2Device.m",
    "screen/libscreen.m",
    "screen/libscreen_watcher.m",
    "serial/libserial.m",
    "settings/libsettings.m",
    "sharing/libsharing.m",
    "shortcuts/libshortcuts.m",
    "socket/libsocket.m",
    "socket/libsocket_udp.m",
    "sound/libsound.m",
    "spaces/libspaces.m",
    "spaces/libspaces_watcher.m",
    "speech/libspeech.m",
    "speech/libspeech_listener.m",
    "spotlight/libspotlight.m",
    "sqlite3/lsqlite3.c",
    "streamdeck/libstreamdeck.m",
    "streamdeck/HSStreamDeckDevice.m",
    "streamdeck/HSStreamDeckDeviceMini.m",
    "streamdeck/HSStreamDeckDeviceMk2.m",
    "streamdeck/HSStreamDeckDeviceOriginal.m",
    "streamdeck/HSStreamDeckDeviceOriginalV2.m",
    "streamdeck/HSStreamDeckDevicePedal.m",
    "streamdeck/HSStreamDeckDevicePlus.m",
    "streamdeck/HSStreamDeckDeviceXL.m",
    "streamdeck/HSStreamDeckManager.m",
    "streamdeck/NSImage+BMP.m",
    "streamdeck/NSImage+Flipped.m",
    "streamdeck/NSImage+JPEG.m",
    "streamdeck/NSImage+Rotated.m",
    "styledtext/libstyledtext.m",
    "task/libtask.m",
    "timer/libtimer.m",
    "uielement/libuielement.m",
    "uielement/libuielement_watcher.m",
    "urlevent/liburlevent.m",
    "usb/libusb.m",
    "usb/libusb_watcher.m",
    "webview/libwebview.m",
    "webview/libwebview_datastore.m",
    "webview/libwebview_toolbar.m",
    "webview/libwebview_usercontent.m",
    "websocket/libwebsocket.m",
    "wifi/libwifi.m",
    "wifi/libwifi_watcher.m",
    "window/libwindow.m",
    "HSExtensions.m",
]

let package = Package(
    name: "HSExtensions",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HSExtensions", type: .static, targets: ["HSExtensions"]),
    ],
    dependencies: [
        .package(path: "../LuaSkin"),
        .package(url: "https://github.com/robbiehanson/CocoaAsyncSocket", from: "7.0.0"),
        .package(url: "https://github.com/armadsen/ORSSerialPort", from: "2.0.0"),
        .package(path: "../CocoaHTTPServer"),
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack", from: "3.8.0"),
    ],
    targets: [
        .target(
            name: "HSExtensions",
            dependencies: [
                "LuaSkin",
                "CocoaAsyncSocket",
                .product(name: "ORSSerial", package: "ORSSerialPort"),
                "CocoaHTTPServer",
                "CocoaLumberjack",
            ],
            path: "Sources/HSExtensions",
            sources: extensionSourcePaths,
            publicHeadersPath: "include",
            cSettings: [
                .define("LUA_USE_MACOSX"),
                .define("LUA_COMPAT_5_3"),
                .headerSearchPath("axuielement"),
                .headerSearchPath("canvas"),
                .headerSearchPath("chooser"),
                .headerSearchPath("doc"),
                .headerSearchPath("eventtap"),
                .headerSearchPath("fs"),
                .headerSearchPath("hash"),
                .headerSearchPath("httpserver"),
                .headerSearchPath("location"),
                .headerSearchPath("network/ping"),
                .headerSearchPath("noises"),
                .headerSearchPath("osascript"),
                .headerSearchPath("razer"),
                .headerSearchPath("shortcuts"),
                .headerSearchPath("socket"),
                .headerSearchPath("spaces"),
                .headerSearchPath("streamdeck"),
                .headerSearchPath("webview"),
                .unsafeFlags([
                    "-Wno-float-equal",
                    "-Wno-unused-macros",
                    "-Wno-everything",
                ]),
            ],
            cxxSettings: [
                .define("LUA_USE_MACOSX"),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Quartz"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreSpotlight"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("DiscRecording"),
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
                .linkedFramework("Intents"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
```

**Note on `unsafeFlags`**: SPM forbids `unsafeFlags` in a package consumed by another package as a dependency unless the consumer pins to an exact version. Since this is a local path-based package, `unsafeFlags` is allowed. If we need cleaner output, split `lsqlite3.c` into its own sub-target with its own `cSettings`, depending on LuaSkin for headers. The implementation agent should attempt the single-target form first.

**Note on framework list**: the list above is intentionally broad — it's roughly the union of every framework any extension touches via `@import`. SPM will simply link these into the static archive's link directives (`LC_LINKER_OPTION`); the main app only "uses" frameworks actually referenced by code. Linking unused frameworks is cheap and avoids per-extension bookkeeping.

---

## Implementation phases (sequenced)

| Phase | What | LoC touched | Files | Effort |
|---|---|---|---|---|
| 0 | jj setup, baseline build, snapshot reference test outputs | ~0 | 0 | 30 min |
| 1 | Create empty SPM scaffold, generator script | ~250 | 4 new files | 1 hour |
| 2 | POC: 3 extensions (`math`, `base64`, `window`) end-to-end | ~150 | 5 modified | 3 hours |
| 3 | Bulk: add remaining ~88 to Package.swift, regenerate glue | ~50 (mostly auto) | 3 generated | 1 hour |
| 4 | Wire HSExtensions into main app target in xcodeproj | ~30 | 1 (pbxproj) | 1 hour |
| 5 | Verify full Debug build links and runs | iterative | iterative | 1–3 hours |
| 6 | Remove 91 dylib targets + Copy Extension Dylibs phase | ~5,000 deletions | 1 (pbxproj) | 2 hours |
| 7 | Remove Extensions-Base.xcconfig if unused | ~30 | 1 deleted | 15 min |
| 8 | Update setup.lua to remove dead cpath entries | ~3 | 1 | 5 min |
| 9 | Full test suite, regression checklist | — | — | 1 hour |

**Total: ~10–12 hours of focused work.** Stage as 5–7 jj commits.

---

## Phase 0: Setup

1. `cd /Users/mohammadk/Dev/hammerspoon`
2. Confirm clean working state: `jj st`
3. Run a baseline build to confirm the project compiles **before** changes: `just build Debug` (timeout this generously — first build takes minutes).
4. Confirm tests pass on baseline: `just test Debug`.
5. Snapshot what's currently in the built `Hammerspoon.app/Contents/Frameworks/hs/`:
   ```
   ls build/Build/Products/Debug/Hammerspoon.app/Contents/Frameworks/hs/ | sort > /tmp/hs-dylibs-before.txt
   ```
6. Create a new jj commit for the work, e.g. `jj new -m "WIP: consolidate dylibs to SPM static lib"`.

If baseline build fails, **stop and report**. Everything downstream assumes the project builds cleanly on this machine.

---

## Phase 1: SPM scaffold

Create the new package skeleton with **no extension sources yet** — verify SPM can resolve LuaSkin and the SPM dependencies.

1. `mkdir -p Packages/HSExtensions/Sources/HSExtensions/include/HSExtensions`
2. Create `Packages/HSExtensions/Sources/HSExtensions/include/HSExtensions/HSExtensions.h`:
   ```c
   #pragma once
   #include <lua/lua.h>
   #ifdef __cplusplus
   extern "C" {
   #endif
   /// Registers every bundled hs.lib<name> entry point with package.preload.
   /// Call after lua_State creation and before setup.lua runs.
   void HSExtensionsRegisterAll(lua_State *L);
   #ifdef __cplusplus
   }
   #endif
   ```
3. Create `Packages/HSExtensions/Sources/HSExtensions/HSExtensions+Preload.h` as a stub (no symbols yet).
4. Create `Packages/HSExtensions/Sources/HSExtensions/HSExtensions.m` with a no-op `HSExtensionsRegisterAll` body.
5. Create `Packages/HSExtensions/Package.swift` with the minimal `extensionSourcePaths = ["HSExtensions.m"]` (just the registry function for now).
6. Create `scripts/generate-hsextensions.sh` per the spec above.
7. `chmod +x scripts/generate-hsextensions.sh`.
8. Test SPM resolution: `cd Packages/HSExtensions && swift build`.
9. **Expected**: success, produces an empty `libHSExtensions.a` (or near-empty). If this fails, fix module-map / header paths before moving on.

**Commit**: `jj new -m "Add empty HSExtensions SPM package scaffold"`.

---

## Phase 2: Proof of concept (3 extensions)

Pick 3 extensions of varying complexity:

- **`base64`** (1 source file, only `libbase64.m`, links `Security.framework`)
- **`math`** (1 source file, no special dependencies)
- **`window`** (1 source file, but heavily used — links Cocoa, ApplicationServices, Carbon transitively; will surface most "missing framework" issues if any)

### Steps

1. **Symlink the three extension directories** into the package's source tree:
   ```
   cd Packages/HSExtensions/Sources/HSExtensions
   ln -s ../../../../extensions/base64 base64
   ln -s ../../../../extensions/math math
   ln -s ../../../../extensions/window window
   ```
2. **Add their `.m` paths to `extensionSourcePaths`** in `Package.swift`:
   ```swift
   "base64/libbase64.m",
   "math/libmath.m",
   "window/libwindow.m",
   ```
3. **Build**: `cd Packages/HSExtensions && swift build 2>&1 | tee /tmp/spm-poc.log`. Expect failures — these will be header-path issues and missing `LuaSkin` resolution. Fix them by:
   - Confirming `LuaSkin` package dependency builds first (`cd ../LuaSkin && swift build`).
   - Adding any `@import` headers transitively. (`@import LuaSkin;` and `@import Cocoa;` should both work — both are clang modules.)
   - If `lua.h`, `lauxlib.h`, etc. aren't found, add `.headerSearchPath` entries pointing at `../LuaSkin/Sources/LuaSkin/include`. They should be auto-found via the LuaSkin dependency's `publicHeadersPath`.
4. **Run the generator script** to populate `HSExtensions+Preload.h` and `HSExtensions.m`:
   ```
   ./scripts/generate-hsextensions.sh
   ```
   With only 3 extensions present in the extension list scanned, you'll get just the 3 entries. **The generator scans `extensions/` not the package source list**, so even though only 3 are linked into the SPM target, all 91 entries will appear in the generated `HSExtensions.m`. That's wrong for the POC — symbols referenced but not linked will fail. **For the POC only**, manually edit the generated `HSExtensions.m` to include only the 3 POC entries. Or add a CLI flag to the generator: `--filter base64,math,window`. The cleanest answer: have the generator read its list from a file (`Packages/HSExtensions/extensions.list`) that the implementation agent maintains. For Phase 2, that file has 3 lines; in Phase 3, it has 91.
5. **Build again**: `swift build` in HSExtensions. Expect success this time.
6. **Wire the registry call into MJLua.m** (a minimal-impact edit):
   - At top of `Hammerspoon/MJLua.m`, after the existing `#import` block, add:
     ```c
     #import <HSExtensions/HSExtensions.h>
     ```
   - In `MJLuaInit()`, after `lua_setglobal(L, "hs");` (currently line 714) and before `luaL_loadfile(L, ... "setup" ...)` (currently line 716), insert:
     ```c
     HSExtensionsRegisterAll(L);
     ```
7. **Wire HSExtensions into the main app via xcodeproj.** This is the most fragile step. Two approaches:
   - **(Preferred)** Use Xcode UI manually: File → Add Package Dependencies → Add Local → choose `Packages/HSExtensions`. Then in the Hammerspoon target → General → Frameworks/Libraries, add `HSExtensions`. Xcode rewrites pbxproj cleanly. Verify pbxproj changes look like:
     - New `XCLocalSwiftPackageReference` block for HSExtensions (mirror existing `LuaSkin` block at line 11776).
     - New entry in `packageReferences` of the project root (around line 6708).
     - New entry in `packageProductDependencies` of the Hammerspoon target (around line 6211, alongside `LuaSkin`).
     - New entry in `Hammerspoon /* Frameworks */` build phase (around line 2548).
   - **(Fallback if Xcode UI is unavailable)** Hand-edit pbxproj following the `LuaSkin` pattern exactly. Use UUIDs from `uuidgen | tr -d '-' | cut -c1-24`.
8. **Add the dead-strip-prevention file to the main app target**: in Xcode UI, drag `Hammerspoon/HSExtensionsRegistry.m` into the `Hammerspoon` group, ensuring it's added to the `Hammerspoon` target (not Tests). (Alternative: hand-edit pbxproj to add a PBXBuildFile entry referencing it in the Sources phase at line 7528.) Until phase 3, this file should only reference the 3 POC symbols.
9. **Build the app**: `just build Debug`. Expect success.
10. **Sanity-check the binary**:
    ```
    nm -gU build/Build/Products/Debug/Hammerspoon.app/Contents/MacOS/Hammerspoon | grep luaopen_hs_lib
    ```
    Should list `luaopen_hs_libbase64`, `luaopen_hs_libmath`, `luaopen_hs_libwindow` as exported (or at least defined) symbols.
11. **Move the 3 POC dylibs out of `Frameworks/hs/`** to force the new path to be exercised. Either:
    - Temporarily remove the 3 dylibs from the "Copy Extension Dylibs" phase (drag-remove in Xcode); OR
    - After build, manually `rm build/Build/Products/Debug/Hammerspoon.app/Contents/Frameworks/hs/lib{base64,math,window}.dylib`.
12. **Launch the built app** and open the Hammerspoon console (Cmd-Shift-D or via menubar):
    ```
    print(hs.window.focusedWindow():title())
    print(hs.math.minFloat)
    print(hs.base64.encode("hello"))
    -- Confirm preload table contains our 3 entries:
    for k in pairs(package.preload) do print(k) end
    -- Should include hs.libbase64, hs.libmath, hs.libwindow
    ```
13. **Verify there's no dlopen** (informative; relies on Activity Monitor → Open Files & Ports for the running Hammerspoon process).

**Commit**: `jj new -m "POC: link base64/math/window statically via HSExtensions"`.

If the POC fails, **iterate on the SPM Package.swift configuration**; do not proceed.

---

## Phase 3: Bulk conversion

Once the POC works for 3 extensions, mechanically expand to all of them.

1. **Symlink the remaining extension directories**:
   ```
   cd Packages/HSExtensions/Sources/HSExtensions
   for d in /Users/mohammadk/Dev/hammerspoon/extensions/*/; do
     name=$(basename "$d")
     [ "$name" = "_coresetup" ] && continue          # pure Lua, no native sources
     [ -e "$name" ] && continue                       # already symlinked from POC
     # Skip extensions with no native sources (alert, appfinder, inspect, etc.)
     if find "$d" -maxdepth 2 \( -name "*.m" -o -name "*.c" -o -name "*.cpp" \) | grep -q .; then
       ln -s "../../../../extensions/$name" "$name"
     fi
   done
   ```

2. **Populate `Packages/HSExtensions/extensions.list`** with one symbol per line — extracted via:
   ```
   grep -RhEo 'int luaopen_hs_[a-zA-Z0-9_]+' \
     /Users/mohammadk/Dev/hammerspoon/extensions \
     --include='*.m' --include='*.c' \
     | awk '{print $NF}' | sort -u \
     | grep -v '^luaopen_hs_libaxuielementobserver$' \
     | grep -v '^luaopen_hs_axuielement_axtextmarker$' \
     > Packages/HSExtensions/extensions.list
   ```

3. **Run the generator**: `./scripts/generate-hsextensions.sh`. Verify the three output files now have ~91 entries each.

4. **Replace `extensionSourcePaths` in `Package.swift`** with the full list (per the Package.swift skeleton above).

5. **Build the SPM package alone**: `cd Packages/HSExtensions && swift build 2>&1 | tee /tmp/spm-bulk.log`. **Expect failures** the first time around. Likely categories:
   - **Header-not-found**: an extension expects `#import "extension_x/SomeHeader.h"` to be findable. Fix by adding `.headerSearchPath("extension_x")` to `cSettings`.
   - **Unknown identifier**: an extension uses a system framework like `IOKit/hid/IOHIDKeys.h`. Add `.linkedFramework("IOKit")` to `linkerSettings`.
   - **Duplicate symbol**: two `.m` files define the same non-static function. File an inline fix (mark one `static` or rename) in the offending extension file and commit it separately.
   - **`@import` doesn't resolve**: `@import LuaSkin` or `@import Cocoa` etc. The `LuaSkin` dependency on the SPM target should fix the LuaSkin case; for system frameworks `@import` should always work in SPM ObjC targets.
   - **Per-file compiler flags**: `lsqlite3.c` wants `-Wno-float-equal -Wno-unused-macros`; `libaudiodevice_watcher.m` wants `-std=c99`. SPM doesn't support per-file flags. Try without first.

6. **Once SPM builds**, rebuild the app: `just build Debug`. Iterate on errors.

7. **At the main-app link step**, watch for two common failures:
   - **Undefined symbol** for any `luaopen_*` that the registry array references but isn't in `libHSExtensions.a`. Fix: ensure the corresponding `.m` is in `extensionSourcePaths`.
   - **Duplicate definition** of a global symbol if two extensions used to coexist via `-undefined dynamic_lookup` and now actually conflict. Fix: per-case (rename, `static`, or extract to a vendor sub-target).

8. **Verify all symbols are present in the binary**:
   ```
   nm -U build/Build/Products/Debug/Hammerspoon.app/Contents/MacOS/Hammerspoon \
     | grep -c '_luaopen_hs_lib'
   ```
   Expected: 91 (or whatever the generated count is — confirm against `wc -l < Packages/HSExtensions/extensions.list`).

**Commit**: `jj new -m "Link all 91 extensions statically into Hammerspoon binary"`.

At this point the app still **also** copies the 91 dylibs into `Frameworks/hs/`. Both code paths coexist. Test thoroughly here — see Phase 5 — **before** deleting the dylib targets.

---

## Phase 4: Wire into main app (already partially done in Phase 2)

Already covered in Phase 2 step 7. By end of Phase 3 this should be complete. If you split Phase 2 into a separate commit, Phase 4 is just verification.

---

## Phase 5: Verification (before removing dylib targets)

Run the verification checklist from Section 7 below. **Do not** proceed to Phase 6 until all checks pass. If any check fails, the dylibs in `Frameworks/hs/` are still being used and the bug is masked.

The critical test: temporarily remove all 91 dylibs from the built bundle and confirm Hammerspoon still runs every extension:

```
rm build/Build/Products/Debug/Hammerspoon.app/Contents/Frameworks/hs/*.dylib
ls build/Build/Products/Debug/Hammerspoon.app/Contents/Frameworks/hs/  # leave hs CLI tool only
open build/Build/Products/Debug/Hammerspoon.app
# In the console, run the regression checklist (Section 7).
```

If this passes, the consolidation is complete — Phase 6 is just cleanup.

**Commit**: `jj new -m "Verify static-linked extensions work without dylib fallback"`.

---

## Phase 6: xcodeproj cleanup

Mechanically remove dead Xcode infrastructure. This is the largest line-count delete in the project (~5,000+ lines from pbxproj).

### Strategy
Use Xcode UI for the removals when possible — Xcode handles the cross-references (PBXBuildFile, PBXFileReference, PBXTargetDependency, PBXContainerItemProxy, XCBuildConfiguration, XCConfigurationList). Hand-editing pbxproj at this scale is error-prone.

In Xcode:
1. Select all 91 extension targets in the project navigator (Cmd-click each in the target list, or filter by product type "Dynamic Library" if Xcode supports it).
2. Right-click → Delete → "Remove References". This removes the targets but **keeps the source files** in the project. The `.m` files now belong only to the Hammerspoon Tests target (for HSTestCase fixtures) or no target at all — that's fine, they're still on disk and SPM picks them up via the symlinks.
3. Open the Hammerspoon target → Build Phases → "Copy Extension Dylibs" → click the X. Remove the entire phase.
4. Same target → Build Phases → "Copy Extension Lua files" — **DO NOT REMOVE**. Lua files still need to be bundled.
5. In `Hammerspoon-Base.xcconfig` (the `OTHER_LDFLAGS = -undefined dynamic_lookup` line in `Project-Base.xcconfig`): consider tightening, but **leave for now** — removing this may surface latent issues in legitimate dependencies. Tackle in a follow-up.

### Manual pbxproj checks after Xcode UI delete

```
grep -c 'productType = "com.apple.product-type.library.dynamic"' Hammerspoon.xcodeproj/project.pbxproj
# Expected: 0 (was 92 before; the hs CLI tool is type "tool", not "library.dynamic")
grep -c 'isa = PBXTargetDependency' Hammerspoon.xcodeproj/project.pbxproj
# Expected: ~4 (was 95; remaining ones are LuaSkin → app, Tests → app, etc.)
```

### Test the slimmed project

```
just clean
just build Debug
```

Build should succeed. The pbxproj should be approximately 4,500 lines (was 11,865).

**Commit**: `jj new -m "Remove 91 dylib targets and Frameworks/hs copy phase from xcodeproj"`.

---

## Phase 7: Drop unused xcconfig files

```
grep -l 'Extensions-Base.xcconfig\|Extensions-Ideal.xcconfig' Hammerspoon.xcodeproj/project.pbxproj
```

If these xcconfig files are no longer referenced from `baseConfigurationReference` anywhere (they shouldn't be after Phase 6 — Xcode UI delete removed those refs), delete them.

**Commit**: `jj new -m "Remove unused Extensions-Base.xcconfig and Extensions-Ideal.xcconfig"`.

---

## Phase 8: Trim setup.lua

In `Hammerspoon/setup.lua`, the `cpaths` table currently includes:
```lua
local cpaths = {
  configdir .. "/?.dylib",
  configdir .. "/?.so",
  package.cpath,
  frameworkspath .. "/?.dylib",          -- THIS ENTRY no longer resolves anything
  userruntime .. "/lib/?.dylib",
  userruntime .. "/lib/?.so",
}
```

Since `Frameworks/hs/` will no longer exist in the bundle, the `frameworkspath .. "/?.dylib"` entry can be deleted. **Leave the others** — third-party Spoons and user-installed extensions still rely on cpath search.

**Commit**: `jj new -m "Drop frameworks/hs/?.dylib from package.cpath now that all extensions are static"`.

---

## Section 6: Dead-stripping prevention (the critical detail)

The risk: SPM produces a static archive `libHSExtensions.a`. When `ld` links the main Hammerspoon binary against it, only object files containing referenced symbols are pulled out of the archive. Our `luaopen_*` functions are only called by name **at runtime** via `lua_pushcfunction(L, luaopen_hs_libwindow)` — but that call is in `HSExtensions.m`, which **is** in `libHSExtensions.a`, which means the linker won't pull `HSExtensions.m` out unless someone outside the archive references it. And `HSExtensionsRegisterAll` is called from `MJLua.m` (outside the archive), so `HSExtensions.m` gets pulled in. So far so good — but does pulling in `HSExtensions.m` pull in `libwindow.m`'s object? **No**, because `HSExtensions.m` only references the `luaopen_hs_libwindow` symbol; `ld` chases that, pulls in `libwindow.o`, and reads only that object.

Each `luaopen_*` reference in the `HSExtensions.m` array forces the linker to pull in the corresponding object.

**The actual risk** is more subtle: each `.m` file in `libHSExtensions.a` might define helper functions (e.g., the file-scope `screen_gammaReapply` in `libscreen.m`) that are called by other functions in the same `.m` file but never by `luaopen_*` directly. When `ld` pulls in `libscreen.o`, it gets `screen_gammaReapply` for free (same object file). So that's fine.

The **actual** risk is what happens with extensions that have multiple `.m` files in the same Xcode target. For example, `axuielement` has 4 `.m` files. `libaxuielement.m` defines `luaopen_hs_libaxuielement`, which is referenced from the registry — that pulls in `libaxuielement.o`. But `libaxuielement.m` references `luaopen_hs_libaxuielementobserver` (from `observer.m`) via `extern int luaopen_hs_libaxuielementobserver(lua_State *L);` and a direct call, which pulls in `observer.o`. **Same for `axtextmarker.m` and `common.m`** — they're pulled in by extern references from `libaxuielement.m`. So that works.

**Where this could fail**: in the unlikely case that a `.m` file in an extension has zero external references from any of its sibling files. E.g., if some Objective-C class registers itself via `+load`, and nothing else references the class. ObjC's `+load` is run only when its containing class's object file is loaded — and ld's static-archive selection considers ObjC class symbols. **The safe rule**: keep all-objects loaded for `HSExtensions`.

**Recommended technique** (belt-and-suspenders): combine the keep-alive array (`HSExtensionsRegistry.m`) with `-Wl,-force_load,<path-to-libHSExtensions.a>` in the main app's `OTHER_LDFLAGS`. The keep-alive array gives the linker explicit references to every `luaopen_*`. `-force_load` is the brute-force fallback that pulls in every object file unconditionally; the runtime cost is zero (the static archive's objects all end up in the binary either way; force_load just removes the dead-code-elimination opportunity).

How to add `-force_load`:
1. In Xcode UI, select the Hammerspoon target → Build Settings → `OTHER_LDFLAGS`.
2. Add (for Debug, Release, Profile configurations): `-Wl,-force_load,$(BUILT_PRODUCTS_DIR)/PackageFrameworks/HSExtensions.framework/HSExtensions`. **Note**: SPM products show up under `$(BUILT_PRODUCTS_DIR)/PackageFrameworks/<name>.framework/<name>` when built as `.library(type: .static, ...)`. Verify this path empirically by looking inside `build/Build/Products/Debug/` after a build.

The exact format may need adjustment. An alternative tested form:
```
OTHER_LDFLAGS = $(inherited) -Wl,-force_load,$(BUILT_PRODUCTS_DIR)/libHSExtensions.a
```

The implementation agent should pick whichever works empirically and commit it.

---

## Section 7: Verification checklist

Run each check. The plan **must pass each** before merging.

### Build-time checks

1. **SPM builds cleanly in isolation**:
   ```
   cd Packages/HSExtensions && swift build && swift build -c release
   ```
2. **Xcode Debug + Release builds succeed**:
   ```
   just clean
   just build Debug
   just build Release
   ```
3. **No `Frameworks/hs/*.dylib` in the bundle**:
   ```
   find build/Build/Products/Debug/Hammerspoon.app -name '*.dylib' -path '*/hs/*'
   # Expected: empty.
   ```
4. **`nm` shows all preload symbols**:
   ```
   nm -U build/Build/Products/Debug/Hammerspoon.app/Contents/MacOS/Hammerspoon \
     | grep -c '_luaopen_hs_lib'
   # Expected: == wc -l < Packages/HSExtensions/extensions.list
   ```
5. **Binary size is in expected range**: the new binary should be ~30–80 MB larger than before (static linking pulls in all the ObjC class metadata that was previously per-dylib). If it's only a few MB bigger, something is being dead-stripped.
6. **`Hammerspoon Tests` target builds**: `just test Debug` runs the LuaSkin-based test suite.

### Runtime checks (launch the built app)

7. **Preload table contains all extensions**. In the Hammerspoon console:
   ```lua
   local count = 0
   for k, _ in pairs(package.preload) do
     if k:match('^hs%.lib') then count = count + 1 end
   end
   print('preload count: ' .. count)
   -- Expected: 91 (matches extensions.list line count)
   ```
8. **Each loadable extension instantiates**:
   ```lua
   for k, _ in pairs(package.preload) do
     if k:match('^hs%.lib') then
       local ok, err = pcall(require, k)
       if not ok then print('FAIL ' .. k .. ': ' .. tostring(err)) end
     end
   end
   ```
   Expected: no output (every preload returns a table successfully).

### Spot-test one Lua snippet per extension

Run each in the Hammerspoon console. Each should return a sensible value (or no error). If any errors, investigate the extension's static-link issue specifically.

(See full Lua spot-test snippets in section appended to plan during execution.)

### Automated test suite

```
just test Debug
```

The Hammerspoon test suite exercises LuaSkin and many extension boundaries. Expect all tests that passed before to pass after. New failures point at extension behaviour the consolidation broke.

---

## Section 8: Rollback strategy (jj-based)

The plan is sequenced so each phase is a discrete jj commit, and any phase can be abandoned with `jj abandon <change-id>` without losing earlier work.

Recommended commit sequence (one per phase, plus a few inline fixes):
1. `Add empty HSExtensions SPM package scaffold` (Phase 1)
2. `POC: link base64/math/window statically via HSExtensions` (Phase 2)
3. `Link all 91 extensions statically into Hammerspoon binary` (Phase 3)
4. `Verify static-linked extensions work without dylib fallback` (Phase 5)
5. `Remove 91 dylib targets and Frameworks/hs copy phase from xcodeproj` (Phase 6)
6. `Remove unused Extensions-Base.xcconfig and Extensions-Ideal.xcconfig` (Phase 7)
7. `Drop frameworks/hs/?.dylib from package.cpath now that all extensions are static` (Phase 8)

**Rollback scenarios**:
- **Stuck in Phase 5 (verification)**: abandon commits 4 onward; you're back to a working state with dylibs intact, the SPM package and static binding still present. The app is shipping with both code paths.
- **Stuck in Phase 6 (xcodeproj cleanup)**: abandon commit 5. The dylibs are still being built and copied; they just aren't required by Lua because preload wins.
- **Stuck in Phase 3 (bulk extension addition)**: abandon commit 3. POC still works. Iterate on individual extensions one-at-a-time and re-attempt bulk.
- **A specific extension keeps failing to static-link**: temporarily exclude it from `extensionSourcePaths` AND from `extensions.list`; the rest of the app builds and that extension's `lib<name>.dylib` continues to be loaded via the legacy dlopen path (since `Frameworks/hs/` still exists pre-Phase 6).

Use `jj op log` to find specific operation points for finer-grained rollback, and `jj op restore` to undo cross-cutting changes.

---

## Section 9: Known unknowns (things the implementation agent will discover)

### U1. Compile-time per-file flag differences

`extensions/audiodevice/libaudiodevice_watcher.m` is currently compiled with `-std=c99`. The rest of the codebase compiles with `gnu99`. When unified in SPM, `libaudiodevice_watcher.m` will be compiled with whatever `cSettings` specifies (let's say `gnu99`). It may emit warnings or errors it didn't before. **If it fails**: examine the actual compile errors. The fix is likely to put the file in its own sub-target with `cSettings: [.unsafeFlags(["-std=c99"])]`.

### U2. Static-linker hidden symbol clash

I checked common cases but couldn't exhaust every `.m` file. The most likely place for surprise: vendored C code in `extensions/doc/` (which has `markdown.c`, `houdini_*.c`, `buffer.c`, `stack.c`). If anything inside these collides with a system `libmd` or `libsqlite3` symbol when statically linked, the agent will see a duplicate-symbol error from `ld` and need to either prefix-rename the offending function or wrap it in a `static` inline.

### U3. Categories on Cocoa classes loaded twice

Several extensions add Objective-C categories on `NSImage`, `NSAppleEventDescriptor`, etc. (e.g., `extensions/streamdeck/NSImage+BMP.m`). With dylibs, each category lives in its own image and the ObjC runtime merges them deterministically by load order. With a single static binary, categories from multiple sources are loaded all-at-once at app launch. **Risk**: two extensions declare the same category-method selector on the same class. **Likelihood**: low. **Detection**: at app launch, look for stderr warnings.

### U4. `-undefined dynamic_lookup` actually masking real undefined symbols

Today, dylibs are linked with `-undefined dynamic_lookup`, which is essentially "trust me, the symbol will resolve at runtime". This is permissive: any typo or missing import compiles. With static linking into a single binary, `ld` requires every symbol to be resolved at link time. **Risk**: a long-tail of extensions reference functions or constants that no framework actually provides, but the dylib build happily produces them because `-undefined dynamic_lookup` lets them slide. They'd crash at runtime in the dylib world too — but only when the bad code path runs, so they may have lurked for years. **Detection**: link-time `Undefined symbols` errors during Phase 3. **Fix**: case by case. Either add the missing framework or fix the call site.

### U5. SPM's `unsafeFlags` doesn't propagate to dependents

The flag `-Wno-everything` is needed because every extension was built with `-Weverything -Werror`-style flags but with selective `-Wno-*`. Replicating that exactly in SPM is hard. The pragmatic fix is `-Wno-everything` package-wide and accept lower warning hygiene during transition.

---

## How this plan could fail in practice, and what to do

1. **SPM symlink-followed sources don't reach the LuaSkin headers** — clang complains it can't find `lua/lua.h`. **Diagnosis**: run `swift build --verbose` in `Packages/HSExtensions/` and look at the actual `-I` flags clang gets. **Fix**: in `Package.swift`, add explicit `.headerSearchPath("../LuaSkin/Sources/LuaSkin/include")` entries. The relative path from `Packages/HSExtensions/Sources/HSExtensions/` to LuaSkin's headers is `../../../LuaSkin/Sources/LuaSkin/include`. SPM normally autowires this via the dependency, but symlinked source trees confuse the heuristic.
2. **`-force_load` references a non-existent path** — Xcode warns/errors that `$(BUILT_PRODUCTS_DIR)/libHSExtensions.a` doesn't exist. **Diagnosis**: after a build, run `find build -name '*HSExtensions*'` to find where SPM actually wrote the archive. **Fix**: substitute the actual path into `OTHER_LDFLAGS`. Likely candidates: `$(BUILT_PRODUCTS_DIR)/PackageFrameworks/HSExtensions.framework/HSExtensions`, `$(BUILT_PRODUCTS_DIR)/PackageProducts/libHSExtensions.a`, or `$(OBJROOT)/Build/Intermediates.noindex/.../HSExtensions.build/HSExtensions.a`. If the keep-alive array is doing its job, `-force_load` is unnecessary and can be dropped.
3. **An extension's runtime behaviour diverges** despite the API working — e.g., `hs.hotkey.bind(...)` registers but never fires. **Diagnosis**: this could be the `+load` / `+initialize` ordering issue (U3 above). **Fix**: check macOS Console.app for `objc[pid]:` warnings at Hammerspoon launch. If a category is being silently replaced, rename the conflicting method.
4. **Static binary is large enough to hit Mach-O segment limits** (very unlikely — Hammerspoon is well under 1 GB). **Diagnosis**: `ld` error about LC_SEGMENT size or DYLD_RPATH overflow. **Fix**: split off a couple of heavyweight extensions into a second SPM static library, each still preloaded the same way.
5. **`Hammerspoon Tests` target stops finding extensions** — tests use `BUNDLE_LOADER = $(TEST_HOST)`, which means they run in-process within Hammerspoon.app. As long as the app has preload entries set up correctly, tests inherit them. **Diagnosis**: a specific test like `HSwindowTests` fails with "module hs.libwindow not found". **Fix**: confirm `HSExtensionsRegisterAll` is called by `MJLuaInit`, and `MJLuaInit` runs before any test code that requires modules.

---

## Critical Files for Implementation

- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon/MJLua.m` — needs one `#import` and one call to `HSExtensionsRegisterAll` at lines 706–716.
- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon/setup.lua` — drop the `frameworkspath .. "/?.dylib"` line at line 21.
- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon.xcodeproj/project.pbxproj` — add HSExtensions SPM package reference; delete 91 PBXNativeTarget entries, 91 PBXTargetDependency entries, and the Copy Extension Dylibs phase.
- `/Users/mohammadk/Dev/hammerspoon/Packages/LuaSkin/Package.swift` — reference pattern for the new `Packages/HSExtensions/Package.swift`.
- `/Users/mohammadk/Dev/hammerspoon/Hammerspoon/Build Configs/Extensions-Base.xcconfig` — represents the per-extension build settings being absorbed into the SPM target's `cSettings` and `linkerSettings`.
