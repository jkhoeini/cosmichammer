# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Version control

- Use `jj` (Jujutsu), not `git`, for all repo operations.
- Stage all development on the `dev` bookmark and push there. Do not push to `master` and do not create new feature bookmarks unless the user asks — the workflow here is "advance `dev`, push `dev`."
- The remote is `origin`. Only push when explicitly told to. Use `jj git push --bookmark dev`.

## Shell and tools

- Run commands through `zsh -ic '<cmd>'` so the user's shell setup, PATH, and `mise` shims are loaded.
- Run just tasks as `zsh -ic 'mise exec -- just <recipe>'`.
- In a new jj workspace, if `mise` reports that `mise.toml` is not trusted, run `zsh -ic 'mise trust -y'` once in that workspace.

## Common commands

The project uses `just` as a task runner. `mise` installs `just` (`mise.toml`). There is no Xcode project — the app is built entirely via `swift build` + justfile bundle assembly.

- `just build` — Debug build of `Cosmic Hammer.app` into `build/`. `just build Release` for Release. Orchestrates version numbering (from git tags), docs.json compilation, hs CLI build, SPM build, and post-build Lua/hs-CLI copying. Release builds enable hardened runtime via `--options runtime` in the codesign step.
- `just rebuild` — `clean` + `build`.
- `just test` — Runs the SPM test suite via `swift test` (requires a prior `just build` for Lua resources). Tests live in `Tests/CosmicHammerTests/` as a Swift Testing `.testTarget`.
- `just docs` / `just docs-lint` — Builds/lints the API docs via the Swift tool under `scripts/docs/` (auto-builds the `BuildDocs` binary the first time).
- `scripts/generate-hsextensions.sh` — Regenerates the HSExtensions glue (`HSExtensions+Preload.h`, `HSExtensionsGenerated.swift`) from `extensions.manifest`. Re-run this whenever an extension entry-point is added or removed. The script is idempotent.

To run a single test suite, use `swift test --filter <SuiteName>` (with the private framework linker flag — see `justfile`). To run all tests: `just test`.

## Architecture

Cosmic Hammer is a Lua scripting host for macOS. Three logical layers:

1. **LuaSkin** (`Sources/LuaSkin/`) — Lua 5.4 C runtime + Objective-C bridge.
2. **Core app** (`CosmicHammer/` for resources, `Sources/HSExtensions/CosmicHammer/` for ObjC headers, `Sources/HSSwiftExtensions/{AppDelegate,LuaRuntime,ConsoleWindowController,DockIcon,PreferencesWindowController,MenuIcon,ConfigUtils,VersionUtils}.swift` for Swift) — The `Cosmic Hammer.app` AppKit shell. `AppDelegate.swift` boots the runtime; `LuaRuntime.swift` owns the `lua_State`, sets up `package.path`/`package.cpath`, and bootstraps `setup.lua` → `extensions/_coresetup/_coresetup.lua` → user `init.lua`.
3. **Extensions** (`extensions/<name>/`) — 90+ extensions exposing system APIs to Lua. Each is a folder with a `<name>.lua` (stays in `extensions/`). Compiled Swift sources live in `Sources/HSSwiftExtensions/`, and C/ObjC sources live in `Sources/HSExtensions/<name>/`. They are **statically linked** into the app, not as separate dylibs.

### SPM layout

All SPM code lives in a single root-level `Package.swift` with standard `Sources/<TargetName>/` layout:

```
Package.swift              — root-level manifest
Sources/
  LuaSkin/                 — Lua 5.4 + ObjC bridge
  HSExtensions/            — ObjC/C/C++ extension + core app code
    include/               — public headers (generated glue)
    CosmicHammer/          — core app ObjC headers
    doc/, eventtap/, ...   — extensions with C/ObjC source files
  HSSwiftExtensions/       — all Swift extension + core app Swift sources
  HSApp/                   — thin executable wrapper (main.swift)
  CEditline/               — system library for hs CLI
  hs/                      — standalone hs CLI tool
Tests/
  CosmicHammerTests/       — Swift Testing suite
```

Lua files remain in `extensions/` (copied to the app bundle at build time). App resources (plists, icons) remain in `CosmicHammer/`.

Key pieces of this model — preserve them when adding extensions:

- `extensions.manifest` — Unified TSV manifest (directory, entry-points, lua-files) at the repo root. **Single source of truth** for the generator.
- `scripts/generate-hsextensions.sh` reads entry-point symbols from `extensions.manifest` and emits:
  - `Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h` (forward decls),
  - `Sources/HSSwiftExtensions/HSExtensionsGenerated.swift` (`HSExtensionsRegisterAll(L)` — registers each entry into `package.preload`).
- `LuaRuntime.swift` calls `HSExtensionsRegisterAll(L)` once between creating the global `hs` table and loading `setup.lua`. Because Lua resolves `package.preload[name]` **before** `package.cpath`, no dylib lookup is needed.
- `lsqlite3.c` is compiled as Objective-C via `Sources/HSExtensions/lsqlite3_wrapper.m` that `#include`s `sqlite3/lsqlite3.c`. Do not rename either file without updating the shim.

### Adding a new extension

1. Create `extensions/<name>/<name>.lua` and (optional) Swift file in the extension dir.
2. If Swift: copy the `.swift` file to `Sources/HSSwiftExtensions/`. If ObjC/C: create `Sources/HSExtensions/<name>/` and place `.m`/`.h`/`.c` files there.
3. Add a line to `extensions.manifest`: `<name><TAB><luaopen_hs_lib symbols or "-"><TAB><lua filenames>`.
4. Run `scripts/generate-hsextensions.sh`.
5. `just build`.

Unit tests live in `Tests/CosmicHammerTests/` (a `.testTarget` in `Package.swift`). The `hs` CLI is built as a product in the root `Package.swift` and copied into `Cosmic Hammer.app/Contents/Frameworks/hs/hs` by `just build` (post-build step).

### Other notable bits

- Test isolation: launch with `-MJConfigFile <path>` to point at a non-default Cosmic Hammer config dir; useful for ad-hoc verification runs.
- All compile/link flags are managed by `Package.swift` (target-level `cSettings`, `linkerSettings`) and the `justfile` (SPM `-Xlinker` flags for private frameworks). The brightness/screen/spaces extensions link `CoreDisplay`, `DisplayServices`, and `SkyLight` (private frameworks from `$(SDKROOT)/System/Library/PrivateFrameworks`) — with the macOS 26 deployment floor these are always present (no weak-linking or NULL guards needed).
- The doc-build tool is its own SPM project (`scripts/docs/`); `BuildDocs` parses `///` (ObjC) and `---` (Lua) doc comments into JSON/Markdown/HTML/SQL.
- `.claude-plans/dylib-consolidation.md` is the historical record of the static-linking refactor. Consult it before making large structural changes to the build.
