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
- `scripts/generate-hsextensions.sh` — Regenerates the HSExtensions glue (`HSExtensions.m`, `HSExtensions+Preload.h`, `HSExtensionsRegistry.m`) from `Packages/HSExtensions/extensions.list`. Re-run this whenever an extension entry-point is added or removed. The script is idempotent.
- `scripts/generate-lua-files-xcfilelists.sh` — Regenerates `scripts/lua-files.inputs.xcfilelist` and `scripts/lua-files.outputs.xcfilelist` from `Packages/HSExtensions/lua-files.list`. Re-run this whenever a Lua file is added or removed from the bundled set. The script is idempotent.

Builds **must** go through the workspace, not the bare project. `xcodebuild -workspace Hammerspoon.xcworkspace -scheme Hammerspoon ...` (this is what the `justfile` does). Opening `Hammerspoon.xcodeproj` directly will fail because SPM resolution happens at the workspace level.

To run a single Lua-side test, use Xcode's test navigator on the `Hammerspoon Tests` target — there is no per-extension test runner on the CLI.

## Architecture

Hammerspoon is a Lua scripting host for macOS. Three logical layers:

1. **LuaSkin** (`Packages/LuaSkin/`) — SPM package, the Lua C runtime + Objective-C bridge framework. Embedded Lua 5.4 sources live under `Sources/LuaSkin/`.
2. **Core app** (`Hammerspoon/`) — The `Hammerspoon.app` AppKit shell. `MJAppDelegate.m` boots the runtime; `MJLua.m` owns the `lua_State`, sets up `package.path`/`package.cpath`, and bootstraps `setup.lua` → `extensions/_coresetup/_coresetup.lua` → user `init.lua`.
3. **Extensions** (`extensions/<name>/`) — 90+ extensions exposing system APIs to Lua. Each is a folder with a `<name>.lua` and optional `lib<name>.m` (Objective-C) sources. They are **statically linked** into the app via a single SPM package (see below), not as separate dylibs.

### HSExtensions static-linking model

Historically each extension was its own Xcode dynamic-library target producing a `.dylib` copied into the bundle and loaded via `package.cpath`. That was consolidated into one SPM static library: **`Packages/HSExtensions/`**.

Key pieces of this model — preserve them when adding extensions:

- `Packages/HSExtensions/Package.swift` — Single `.target` named `HSExtensions` whose `sources:` is a flat list of `extensions/<name>/<file>.{m,c}` paths. Extension folders under `extensions/` are **symlinked** into `Packages/HSExtensions/Sources/HSExtensions/` so SPM (which forbids `..` in source paths) can see them while the source-of-truth stays at `extensions/<name>/`.
- `Packages/HSExtensions/extensions.list` — One `luaopen_hs_lib*` symbol per line. **Single source of truth** for the generator.
- `scripts/generate-hsextensions.sh` reads `extensions.list` and emits:
  - `HSExtensions.m` (`HSExtensionsRegisterAll(L)` — walks each entry into `package.preload`),
  - `HSExtensions+Preload.h` (forward decls),
  - `Hammerspoon/HSExtensionsRegistry.m` (a `__attribute__((used))` static const function-pointer array in the main app target — this prevents the static linker from dead-stripping any `luaopen_*` symbol out of `libHSExtensions.a`).
- `MJLua.m` calls `HSExtensionsRegisterAll(L)` once between creating the global `hs` table and loading `setup.lua`. Because Lua resolves `package.preload[name]` **before** `package.cpath`, no dylib lookup is needed.
- Some C files needed targeted fixes when moving from `-undefined dynamic_lookup` dylibs to static linking: `static inline` on helpers in `extensions/eventtap/eventtap_event.h`, and `static` on `luaByteToObjCharMap` in `extensions/speech/libspeech.m` and `extensions/styledtext/libstyledtext.m`. Watch for duplicate-symbol errors when adding new extensions and prefer those same patterns.
- `lsqlite3.c` is a `.c` file that transitively imports Cocoa via LuaSkin; it is compiled as Objective-C via an `lsqlite3_wrapper.m` shim that `#include`s it. Do not rename either file without updating the shim.

### Adding a new extension

1. Create `extensions/<name>/<name>.lua` and (optional) `extensions/<name>/lib<name>.m`.
2. Symlink the directory into `Packages/HSExtensions/Sources/HSExtensions/<name>` if it isn't already.
3. Add the source path(s) to `extensionSourcePaths` in `Packages/HSExtensions/Package.swift`.
4. Add the `luaopen_hs_lib<name>` symbol to `Packages/HSExtensions/extensions.list`.
5. Run `scripts/generate-hsextensions.sh`.
6. Add the `.lua` file's repo-relative path to `Packages/HSExtensions/lua-files.list` (drives the "Copy Extension Lua files (manifest)" Run Script build phase). Re-run `scripts/generate-lua-files-xcfilelists.sh` to refresh the xcfilelists.
7. `just build`.

The Xcode project no longer needs per-extension targets — there are 4 targets total (`Hammerspoon`, `Hammerspoon Tests`, `HammerspoonUITests`, `hs` CLI). The "Copy hs CLI" build phase deploys the `hs` command-line tool into the app bundle.

### Other notable bits

- Test isolation: launch with `-MJConfigFile <path>` to point at a non-default Hammerspoon config dir; useful for ad-hoc verification runs.
- `Hammerspoon/Build Configs/*.xcconfig` holds the compile/link flags. `-undefined dynamic_lookup` is intentionally retained for compatibility with extension code that references late-bound symbols.
- The doc-build tool is its own SPM project (`scripts/docs/`); `BuildDocs` parses `///` (ObjC) and `---` (Lua) doc comments into JSON/Markdown/HTML/SQL.
- `.claude-plans/dylib-consolidation.md` is the historical record of the static-linking refactor. Consult it before making large structural changes to the build.
