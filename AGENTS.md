# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Version control

- Use `jj` (Jujutsu), not `git`, for all repo operations.
- Stage all development on the `dev` bookmark and push there. Do not push to `master` and do not create new feature bookmarks unless the user asks — the workflow here is "advance `dev`, push `dev`."
- The remote is `origin`. Only push when explicitly told to. Use `jj git push --bookmark dev`.

## Common commands

The project uses `just` as a task runner over `xcodebuild`. `mise` installs `just` and `xcodegen` (`mise.toml`).

- `just build` — Debug build of `Cosmic Hammer.app` into `build/`. `just build Release` for Release. Orchestrates version numbering (from git tags), docs.json compilation, hs CLI build, SPM build, and post-build Lua/hs-CLI copying.
- `just generate` — Regenerates `CosmicHammer.xcodeproj/project.pbxproj` from `project.yml` via XcodeGen. Run after changing targets, dependencies, or build settings.
- `just rebuild` — `clean` + `build`.
- `just test` — Runs the SPM test suite via `swift test` (requires a prior `just build` for Lua resources). Tests live in `Tests/CosmicHammerTests/` as a Swift Testing `.testTarget`.
- `just docs` / `just docs-lint` — Builds/lints the API docs via the Swift tool under `scripts/docs/` (auto-builds the `BuildDocs` binary the first time).
- `scripts/generate-hsextensions.sh` — Regenerates the HSExtensions glue (`HSExtensions.m`, `HSExtensions+Preload.h`, `HSExtensionsRegistry.m`) from `extensions.manifest`. Re-run this whenever an extension entry-point is added or removed. The script is idempotent.

### Xcode project generation

The `project.pbxproj` is **generated** from `project.yml` (XcodeGen) and gitignored. After cloning or modifying project structure, run `just generate` before opening Xcode or building. The 124-line YAML replaces a ~2900-line binary plist — edit `project.yml`, not the pbxproj.

To run a single test suite, use `swift test --filter <SuiteName>` (with the private framework linker flag — see `justfile`). To run all tests: `just test`.

## Architecture

Cosmic Hammer is a Lua scripting host for macOS. Three logical layers:

1. **LuaSkin** (`Sources/LuaSkin/`) — Lua 5.4 C runtime + Objective-C bridge.
2. **Core app** (`CosmicHammer/` for resources, `Sources/HSExtensions/CosmicHammer/` for ObjC headers, `Sources/HSSwiftExtensions/MJ*.swift` for Swift) — The `Cosmic Hammer.app` AppKit shell. `MJAppDelegate.swift` boots the runtime; `MJLua.swift` owns the `lua_State`, sets up `package.path`/`package.cpath`, and bootstraps `setup.lua` → `extensions/_coresetup/_coresetup.lua` → user `init.lua`. The Xcode target's Sources build phase is empty — it only handles resources (XIBs, assets, plists).
3. **Extensions** (`extensions/<name>/`) — 90+ extensions exposing system APIs to Lua. Each is a folder with a `<name>.lua` (stays in `extensions/`). Compiled Swift sources live in `Sources/HSSwiftExtensions/`, and C/ObjC sources live in `Sources/HSExtensions/<name>/`. They are **statically linked** into the app, not as separate dylibs.

### SPM layout

All SPM code lives in a single root-level `Package.swift` with standard `Sources/<TargetName>/` layout:

```
Package.swift              — root-level manifest
Sources/
  LuaSkin/                 — Lua 5.4 + ObjC bridge
  CocoaHTTPServer/         — vendored HTTP server
  HSExtensions/            — ObjC/C/C++ extension + core app code
    include/               — public headers (generated glue)
    CosmicHammer/          — core app ObjC headers + HSExtensionsRegistry.m
    doc/, eventtap/, ...   — extensions with C/ObjC source files
  HSSwiftExtensions/       — all Swift extension + core app Swift sources
  HSApp/                   — thin executable wrapper (main.swift)
  CEditline/               — system library for hs CLI
  hs/                      — standalone hs CLI tool
Tests/
  CosmicHammerTests/       — Swift Testing suite
```

Lua files remain in `extensions/` (copied to the app bundle at build time). Xcode resources (XIBs, plists, icons) remain in `CosmicHammer/`.

Key pieces of this model — preserve them when adding extensions:

- `extensions.manifest` — Unified TSV manifest (directory, entry-points, lua-files) at the repo root. **Single source of truth** for the generator.
- `scripts/generate-hsextensions.sh` reads entry-point symbols from `extensions.manifest` and emits:
  - `Sources/HSExtensions/HSExtensions.m` (`HSExtensionsRegisterAll(L)` — walks each entry into `package.preload`),
  - `Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h` (forward decls),
  - `Sources/HSExtensions/CosmicHammer/HSExtensionsRegistry.m` (a `__attribute__((used))` static const function-pointer array — prevents dead-stripping).
- `MJLua.swift` calls `HSExtensionsRegisterAll(L)` once between creating the global `hs` table and loading `setup.lua`. Because Lua resolves `package.preload[name]` **before** `package.cpath`, no dylib lookup is needed.
- `lsqlite3.c` is compiled as Objective-C via `Sources/HSExtensions/lsqlite3_wrapper.m` that `#include`s `sqlite3/lsqlite3.c`. Do not rename either file without updating the shim.
- Because the Xcode app target has an empty Sources build phase, Xcode no longer infers `-fsanitize=address,undefined` and `-fprofile-instr-generate` for the linker. These are set explicitly in `CosmicHammer/Build Configs/CosmicHammer-Base.xcconfig` via `OTHER_LDFLAGS`.

### Adding a new extension

1. Create `extensions/<name>/<name>.lua` and (optional) Swift file in the extension dir.
2. If Swift: copy the `.swift` file to `Sources/HSSwiftExtensions/`. If ObjC/C: create `Sources/HSExtensions/<name>/` and place `.m`/`.h`/`.c` files there.
3. Add a line to `extensions.manifest`: `<name><TAB><luaopen_hs_lib symbols or "-"><TAB><lua filenames>`.
4. Run `scripts/generate-hsextensions.sh`.
5. `just build`.

The Xcode project has 2 targets (`CosmicHammer`, `CosmicHammerUITests`). Unit tests live in `Tests/CosmicHammerTests/` (a `.testTarget` in `Package.swift`). The `hs` CLI is built as a product in the root `Package.swift` and copied into `Cosmic Hammer.app/Contents/Frameworks/hs/hs` by `just build` (post-build step).

### Other notable bits

- Test isolation: launch with `-MJConfigFile <path>` to point at a non-default Cosmic Hammer config dir; useful for ad-hoc verification runs.
- `CosmicHammer/Build Configs/*.xcconfig` holds the compile/link flags. `-undefined dynamic_lookup` has been removed; all symbols resolve at link time. The brightness/screen/spaces extensions link `CoreDisplay`, `DisplayServices`, and `SkyLight` (private frameworks from `$(SDKROOT)/System/Library/PrivateFrameworks`) — with the macOS 26 deployment floor these are always present (no weak-linking or NULL guards needed).
- The doc-build tool is its own SPM project (`scripts/docs/`); `BuildDocs` parses `///` (ObjC) and `---` (Lua) doc comments into JSON/Markdown/HTML/SQL.
- `.claude-plans/dylib-consolidation.md` is the historical record of the static-linking refactor. Consult it before making large structural changes to the build.
