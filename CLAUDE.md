# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Version control

- Use `jj` (Jujutsu), not `git`, for all repo operations.
- Stage all development on the `dev` bookmark and push there. Do not push to `master` and do not create new feature bookmarks unless the user asks — the workflow here is "advance `dev`, push `dev`."
- The remote is `origin`. Only push when explicitly told to. Use `jj git push --bookmark dev`.

## Common commands

The project uses `just` as a task runner over `xcodebuild`. `mise` installs `just` and `xcodegen` (`mise.toml`).

- `just build` — Debug build of `Hammerspoon.app` into `build/`. `just build Release` for Release. Orchestrates version numbering (from git tags), docs.json compilation, hs CLI build, xcodebuild, and post-build Lua/hs-CLI copying — no Xcode Run Script phases.
- `just generate` — Regenerates `Hammerspoon.xcodeproj/project.pbxproj` from `project.yml` via XcodeGen. Run after changing targets, dependencies, or build settings.
- `just rebuild` — `clean` + `build`.
- `just test` — Runs the SPM test suite via `swift test` (requires a prior `just build` for Lua resources). Tests live in `Packages/HammerspoonTests/` as a Swift Testing `.testTarget`.
- `just docs` / `just docs-lint` — Builds/lints the API docs via the Swift tool under `scripts/docs/` (auto-builds the `BuildDocs` binary the first time).
- `scripts/generate-hsextensions.sh` — Regenerates the HSExtensions glue (`HSExtensions.m`, `HSExtensions+Preload.h`, `HSExtensionsRegistry.m`) from `Packages/HSExtensions/extensions.manifest`. Re-run this whenever an extension entry-point is added or removed. The script is idempotent.

Builds **must** go through the workspace, not the bare project. `xcodebuild -workspace Hammerspoon.xcworkspace -scheme Hammerspoon ...` (this is what the `justfile` does). Opening `Hammerspoon.xcodeproj` directly will fail because SPM resolution happens at the workspace level.

### Xcode project generation

The `project.pbxproj` is **generated** from `project.yml` (XcodeGen) and gitignored. After cloning or modifying project structure, run `just generate` before opening Xcode or building. The 124-line YAML replaces a ~2900-line binary plist — edit `project.yml`, not the pbxproj.

To run a single test suite, use `swift test --filter <SuiteName>` from `Packages/` (with the private framework linker flag — see `justfile`). To run all tests: `just test`.

## Architecture

Hammerspoon is a Lua scripting host for macOS. Three logical layers:

1. **LuaSkin** (`Packages/LuaSkin/`) — Lua 5.4 C runtime + Objective-C bridge. Embedded Lua sources live under `Sources/LuaSkin/`. Compiled as an SPM target inside the unified `Packages/Package.swift`.
2. **Core app** (`Hammerspoon/`) — The `Hammerspoon.app` AppKit shell. `MJAppDelegate.m` boots the runtime; `MJLua.m` owns the `lua_State`, sets up `package.path`/`package.cpath`, and bootstraps `setup.lua` → `extensions/_coresetup/_coresetup.lua` → user `init.lua`. All `.m` files in this directory are compiled by SPM as part of the HSExtensions target (see below), not by the Xcode app target. The Xcode target's Sources build phase is empty — it only handles resources (XIBs, assets, plists).
3. **Extensions** (`extensions/<name>/`) — 90+ extensions exposing system APIs to Lua. Each is a folder with a `<name>.lua` and optional `lib<name>.m` (Objective-C) sources. They are **statically linked** into the app via the HSExtensions SPM target, not as separate dylibs.

### HSExtensions static-linking model

Historically each extension was its own Xcode dynamic-library target producing a `.dylib` copied into the bundle and loaded via `package.cpath`. That was consolidated into one SPM static library.

All SPM code lives in a single unified package: **`Packages/Package.swift`**. It declares three internal targets (LuaSkin, CocoaHTTPServer, HSExtensions) and one product (`HammerspoonLibs`). The `hs` CLI (`Packages/hs/`) is a separate, independent package built outside Xcode by the justfile.

Key pieces of this model — preserve them when adding extensions:

- `Packages/Package.swift` — Unified package. The `HSExtensions` target auto-discovers sources by following symlinks from `HSExtensions/Sources/HSExtensions/<name>/` into `extensions/<name>/` and from `HSExtensions/Sources/HSExtensions/Hammerspoon/` into the core app source tree. Non-source files inside `Hammerspoon/` (XIBs, plists, xcassets, entitlements, etc.) are individually excluded. `ipc/cli` (the standalone `hs` CLI) and `sqlite3/lsqlite3.c` (compiled indirectly via `lsqlite3_wrapper.m`) are also excluded. No need to edit Package.swift when adding extensions.
- `Packages/HSExtensions/extensions.manifest` — Unified TSV manifest (directory, entry-points, lua-files). **Single source of truth** for the generator.
- `scripts/generate-hsextensions.sh` reads entry-point symbols from `extensions.manifest` and emits:
  - `HSExtensions.m` (`HSExtensionsRegisterAll(L)` — walks each entry into `package.preload`),
  - `HSExtensions+Preload.h` (forward decls),
  - `Hammerspoon/HSExtensionsRegistry.m` (a `__attribute__((used))` static const function-pointer array — compiled as part of HSExtensions, in the same linkage unit as the `luaopen_*` symbols, preventing dead-stripping).
- `MJLua.m` calls `HSExtensionsRegisterAll(L)` once between creating the global `hs` table and loading `setup.lua`. Because Lua resolves `package.preload[name]` **before** `package.cpath`, no dylib lookup is needed.
- Some C files needed targeted fixes when moving from `-undefined dynamic_lookup` dylibs to static linking: `static inline` on helpers in `extensions/eventtap/eventtap_event.h`, and `static` on `luaByteToObjCharMap` in `extensions/speech/libspeech.m` and `extensions/styledtext/libstyledtext.m`. Watch for duplicate-symbol errors when adding new extensions and prefer those same patterns.
- `lsqlite3.c` is a `.c` file that transitively imports Cocoa via LuaSkin; it is compiled as Objective-C via an `lsqlite3_wrapper.m` shim that `#include`s it. Do not rename either file without updating the shim.
- `Hammerspoon/HSExecuteLuaIntent.h` and `HSExecuteLuaIntent.m` are pre-generated from `Intents.intentdefinition` (originally Xcode generated these at build time, but SPM cannot drive intent code generation). If the intent definition changes, regenerate them: open the workspace in Xcode, build once with the `.intentdefinition` in the Sources phase, then copy the generated files from DerivedData back into `Hammerspoon/`.
- Because the Xcode app target has an empty Sources build phase, Xcode no longer infers `-fsanitize=address,undefined` and `-fprofile-instr-generate` for the linker. These are set explicitly in `Hammerspoon/Build Configs/Hammerspoon-Base.xcconfig` via `OTHER_LDFLAGS`.

### Adding a new extension

1. Create `extensions/<name>/<name>.lua` and (optional) `extensions/<name>/lib<name>.m`.
2. Symlink the directory into `Packages/HSExtensions/Sources/HSExtensions/<name>` if it isn't already.
3. Add a line to `Packages/HSExtensions/extensions.manifest`: `<name><TAB><luaopen_hs_lib symbols or "-"><TAB><lua filenames>`.
4. Run `scripts/generate-hsextensions.sh`.
5. `just build`.

The Xcode project no longer needs per-extension targets — there are 2 Xcode targets (`Hammerspoon`, `HammerspoonUITests`). Unit tests live in the SPM package as `HammerspoonTests` (a `.testTarget` in `Packages/Package.swift`). The `hs` CLI is built by SPM (`Packages/hs/`) and copied into `Hammerspoon.app/Contents/Frameworks/hs/hs` by `just build` (post-build step).

### Other notable bits

- Test isolation: launch with `-MJConfigFile <path>` to point at a non-default Hammerspoon config dir; useful for ad-hoc verification runs.
- `Hammerspoon/Build Configs/*.xcconfig` holds the compile/link flags. `-undefined dynamic_lookup` has been removed; all symbols resolve at link time. The brightness/screen/spaces extensions link `CoreDisplay`, `DisplayServices`, and `SkyLight` (private frameworks from `$(SDKROOT)/System/Library/PrivateFrameworks`) — with the macOS 26 deployment floor these are always present (no weak-linking or NULL guards needed).
- The doc-build tool is its own SPM project (`scripts/docs/`); `BuildDocs` parses `///` (ObjC) and `---` (Lua) doc comments into JSON/Markdown/HTML/SQL.
- `.claude-plans/dylib-consolidation.md` is the historical record of the static-linking refactor. Consult it before making large structural changes to the build.
