# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Version control

- Use `jj` (Jujutsu), not `git`, for all repo operations.
- Stage all development on the `dev` bookmark and push there. Do not push to `master` and do not create new feature bookmarks unless the user asks — the workflow here is "advance `dev`, push `dev`."
- The remote is `origin`. Only push when explicitly told to. Use `jj git push --bookmark dev`.

## Common commands

The project uses `just` as a task runner over `xcodebuild`. `mise` installs `just` (`mise.toml`).

- `just build` — Debug build of `Hammerspoon.app` into `build/`. `just build Release` for Release.
- `just rebuild` — `clean` + `build`.
- `just test` — Runs the Xcode test bundle (requires a prior `build`). Test results go to `build/TestResults`.
- `just docs` / `just docs-lint` — Builds/lints the API docs via the Swift tool under `scripts/docs/` (auto-builds the `BuildDocs` binary the first time).
- `scripts/generate-hsextensions.sh` — Regenerates the HSExtensions glue (`HSExtensions.m`, `HSExtensions+Preload.h`, `HSExtensionsRegistry.m`) from `Packages/HSExtensions/extensions.manifest`. Re-run this whenever an extension entry-point is added or removed. The script is idempotent.
- `scripts/generate-lua-files-xcfilelists.sh` — Regenerates `scripts/lua-files.inputs.xcfilelist` and `scripts/lua-files.outputs.xcfilelist` from `Packages/HSExtensions/extensions.manifest`. Re-run this whenever a Lua file is added or removed from the bundled set. The script is idempotent.

Builds **must** go through the workspace, not the bare project. `xcodebuild -workspace Hammerspoon.xcworkspace -scheme Hammerspoon ...` (this is what the `justfile` does). Opening `Hammerspoon.xcodeproj` directly will fail because SPM resolution happens at the workspace level.

To run a single Lua-side test, use Xcode's test navigator on the `Hammerspoon Tests` target — there is no per-extension test runner on the CLI.

## Architecture

Hammerspoon is a Lua scripting host for macOS. Three logical layers:

1. **LuaSkin** (`Packages/LuaSkin/`) — SPM package, the Lua C runtime + Objective-C bridge framework. Embedded Lua 5.4 sources live under `Sources/LuaSkin/`.
2. **Core app** (`Hammerspoon/`) — The `Hammerspoon.app` AppKit shell. `MJAppDelegate.m` boots the runtime; `MJLua.m` owns the `lua_State`, sets up `package.path`/`package.cpath`, and bootstraps `setup.lua` → `extensions/_coresetup/_coresetup.lua` → user `init.lua`. All `.m` files in this directory are compiled by SPM as part of the HSExtensions target (see below), not by the Xcode app target. The Xcode target's Sources build phase is empty — it only handles resources (XIBs, assets, plists) and run-script phases.
3. **Extensions** (`extensions/<name>/`) — 90+ extensions exposing system APIs to Lua. Each is a folder with a `<name>.lua` and optional `lib<name>.m` (Objective-C) sources. They are **statically linked** into the app via a single SPM package (see below), not as separate dylibs.

### HSExtensions static-linking model

Historically each extension was its own Xcode dynamic-library target producing a `.dylib` copied into the bundle and loaded via `package.cpath`. That was consolidated into one SPM static library: **`Packages/HSExtensions/`**.

Key pieces of this model — preserve them when adding extensions:

- `Packages/HSExtensions/Package.swift` — Single `.target` named `HSExtensions`. SPM **auto-discovers** sources by following symlinks from `Sources/HSExtensions/<name>/` into `extensions/<name>/` and from `Sources/HSExtensions/Hammerspoon/` into the core app source tree. Non-source files inside `Hammerspoon/` (XIBs, plists, xcassets, entitlements, etc.) are individually excluded. `ipc/cli` (the standalone `hs` CLI) and `sqlite3/lsqlite3.c` (compiled indirectly via `lsqlite3_wrapper.m`) are also excluded. No need to edit Package.swift when adding extensions.
- `Packages/HSExtensions/extensions.manifest` — Unified TSV manifest (directory, entry-points, lua-files). **Single source of truth** for both generators.
- `scripts/generate-hsextensions.sh` reads entry-point symbols from `extensions.manifest` and emits:
  - `HSExtensions.m` (`HSExtensionsRegisterAll(L)` — walks each entry into `package.preload`),
  - `HSExtensions+Preload.h` (forward decls),
  - `Hammerspoon/HSExtensionsRegistry.m` (a `__attribute__((used))` static const function-pointer array — compiled as part of HSExtensions, in the same linkage unit as the `luaopen_*` symbols, preventing dead-stripping).
- `scripts/generate-lua-files-xcfilelists.sh` reads lua-file paths from `extensions.manifest` and emits the xcfilelists for the "Copy Extension Lua files (manifest)" build phase.
- `MJLua.m` calls `HSExtensionsRegisterAll(L)` once between creating the global `hs` table and loading `setup.lua`. Because Lua resolves `package.preload[name]` **before** `package.cpath`, no dylib lookup is needed.
- Some C files needed targeted fixes when moving from `-undefined dynamic_lookup` dylibs to static linking: `static inline` on helpers in `extensions/eventtap/eventtap_event.h`, and `static` on `luaByteToObjCharMap` in `extensions/speech/libspeech.m` and `extensions/styledtext/libstyledtext.m`. Watch for duplicate-symbol errors when adding new extensions and prefer those same patterns.
- `lsqlite3.c` is a `.c` file that transitively imports Cocoa via LuaSkin; it is compiled as Objective-C via an `lsqlite3_wrapper.m` shim that `#include`s it. Do not rename either file without updating the shim.
- `Hammerspoon/HSExecuteLuaIntent.h` and `HSExecuteLuaIntent.m` are pre-generated from `Intents.intentdefinition` (originally Xcode generated these at build time, but SPM cannot drive intent code generation). If the intent definition changes, regenerate them: open the workspace in Xcode, build once with the `.intentdefinition` in the Sources phase, then copy the generated files from DerivedData back into `Hammerspoon/`.
- Because the Xcode app target has an empty Sources build phase, Xcode no longer infers `-fsanitize=address,undefined` and `-fprofile-instr-generate` for the linker. These are set explicitly in `Hammerspoon/Build Configs/Hammerspoon-Base.xcconfig` via `OTHER_LDFLAGS`.

### Adding a new extension

1. Create `extensions/<name>/<name>.lua` and (optional) `extensions/<name>/lib<name>.m`.
2. Symlink the directory into `Packages/HSExtensions/Sources/HSExtensions/<name>` if it isn't already.
3. Add a line to `Packages/HSExtensions/extensions.manifest`: `<name><TAB><luaopen_hs_lib symbols or "-"><TAB><lua filenames>`.
4. Run `scripts/generate-hsextensions.sh` and `scripts/generate-lua-files-xcfilelists.sh`.
5. `just build`.

The Xcode project no longer needs per-extension targets — there are 3 targets total (`Hammerspoon`, `Hammerspoon Tests`, `HammerspoonUITests`). The `hs` CLI is built by SPM (`Packages/hs/`) and copied into `Hammerspoon.app/Contents/Frameworks/hs/hs` by the "Copy hs CLI" Run Script phase.

### Other notable bits

- Test isolation: launch with `-MJConfigFile <path>` to point at a non-default Hammerspoon config dir; useful for ad-hoc verification runs.
- `Hammerspoon/Build Configs/*.xcconfig` holds the compile/link flags. `-undefined dynamic_lookup` has been removed; all symbols resolve at link time. The brightness/screen/spaces extensions weak-link `CoreDisplay`, `DisplayServices`, and `SkyLight` (the latter two from `$(SDKROOT)/System/Library/PrivateFrameworks`) — call sites null-check via `weak_import`.
- The doc-build tool is its own SPM project (`scripts/docs/`); `BuildDocs` parses `///` (ObjC) and `---` (Lua) doc comments into JSON/Markdown/HTML/SQL.
- `.claude-plans/dylib-consolidation.md` is the historical record of the static-linking refactor. Consult it before making large structural changes to the build.
