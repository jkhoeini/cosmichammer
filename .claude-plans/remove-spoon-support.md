# Plan: Remove Spoon support from Cosmic Hammer

## Goal

Remove the **Spoon** plugin subsystem from Cosmic Hammer entirely: the ability to
load, install, manage, and document Spoons. After this change the app has no
concept of a Spoon — no `hs.spoons` module, no `hs.loadSpoon`, no `spoon` global,
no `~/.cosmic-hammer/Spoons` handling, no `.spoon` document type, and no Spoon
sections in the documentation system.

### Scope boundary (important)

"Spoon" (the plugin system) ≠ "Hammerspoon" (the upstream project this is forked
from). The following are **heritage references and are NOT touched**:

- `README.md` / `CREDITS.md` — "fork of Hammerspoon"
- `Sources/hs/hs.m` — `hammerspoonBundle` constant
- `Tests/.../LuaTestSetup.swift` — `org.hammerspoon.Hammerspoon` stub bundle ID
- `Sources/.../HTTPParser.swift` — "Hammerspoon convention" comment
- "Hammerspoon" literals in `.lp` template titles
- `extensions/drawing/color/drawing_color.lua` — the `hs.drawing.color.hammerspoon`
  named-color constant (matches `spoon` only inside "hammerspoon"; NOT a Spoon)
- `README.md:42` — describes Mjolnir's external-extension model and the "integrated
  experience" goal; not Spoon-specific, leave as-is.

## Design decisions

1. **Hard removal, not deprecation stubs.** `hs.loadSpoon` / `hs.spoons` are
   removed outright. Calling them in a user `init.lua` will be a normal Lua
   nil-index error. Rationale: the request is to remove support; a kept-but-erroring
   stub is a half-removal. (Alternative considered: leave `hs.loadSpoon` as a stub
   that calls `hs.showError("Spoon support has been removed")`. Rejected as scope
   creep, but easy to add if reviewers prefer a softer landing.)

2. **Remove Spoon-awareness from the doc system too**, including the public
   `hs.doc.registerJSONFile(file, isSpoon)` second parameter, the `spoon` node in
   the documentation tree, `hs.doc.preloadSpoonDocs()`, `doc._jsonForSpoons`, and
   the doc-browser "Spoons" tab. Rationale: leaving an always-empty "Spoons" tab
   and a dead `isSpoon` flag contradicts "spoon support removed." `_jsonForModules`
   and the "API" tab are preserved.

3. **Manifest is the source of truth.** `extensions/_coresetup/_loader_metadata.lua`
   and `_loader_copy_map.tsv` are generated. We edit `extensions.manifest` and run
   `scripts/generate-hsextensions.sh`; we never hand-edit the generated files.

4. **`doc_builder.lua` stays** (it documents arbitrary third-party modules). Only
   its Spoon-specific doc-comment prose is reworded; behavior is unchanged.

## Execution order (must follow)

The generator validates that every Lua source listed in `extensions.manifest`
exists on disk (`scripts/generate-hsextensions.sh:216-220`). So:

1. **First** remove the `spoons` line from `extensions.manifest` (§B).
2. **Then** delete the spoon files (§A).
3. **Then** run `scripts/generate-hsextensions.sh` (§C) — now nothing references the
   deleted source. Never run the generator while the manifest still lists a deleted
   source, or it aborts with "missing Lua source".
4. Do the remaining Lua/Swift/plist/test/doc edits (§D–§N) in any order.
5. Verify (see Verification).

## Changes by file

### A. Delete files

- **The entire `extensions/spoons/` directory** — contains BOTH `spoons.lua` (the
  `hs.spoons` module) AND `templates/init.tpl` (the `newSpoon` skeleton template,
  referenced only by `spoons.lua:86`). Delete the directory, not just `spoons.lua`.
- `SPOONS.md` — the Spoon authoring/usage guide.
- `CosmicHammer/Spoon.icns` — the `.spoon` document-type icon.

### B. `extensions.manifest`

- Remove the `spoons` line (currently line 81:
  `spoons\t-\ths.spoons=spoons.lua>spoons.lua\t-`).

### C. Regenerate (after A + B)

- Run `scripts/generate-hsextensions.sh`. Expected diffs (only):
  - `extensions/_coresetup/_loader_metadata.lua`: drop the 3 `hs.spoons` entries
    (`luaModules`, `luaModuleList`, `copyMap`) and the `["spoons"] = true`
    lazy-extension entry.
  - `extensions/_coresetup/_loader_copy_map.tsv`: drop the `spoons.lua` row.
  - `HSExtensions+Preload.h` / `HSExtensionsGenerated.swift`: **no change** (spoons
    had no native symbols).

### D. Lua core

- `extensions/_coresetup/_coresetup.lua`: remove the `hs.loadSpoon` function and
  its doc-comment block (currently lines ~291–377). Nothing else references the
  `spoon` global, so it simply ceases to exist.
- `CosmicHammer/setup.lua`: remove the two `Spoons/?.spoon/init.lua` entries from
  the `package.path` list (currently lines 22 and 28).

### E. Doc system — Lua (`extensions/doc/doc.lua`) — PRIMARY CORRECTNESS RISK

`_jsonForModules` (drives the doc-browser API tab) currently shares one `__index`
branch with `_jsonForSpoons` and is built by filtering registered files on
`file.spoon` (lines ~271–300). This must be rewritten cleanly, not half-stripped:

- Remove the `_jsonForSpoons` forward declaration (line ~58) and its reset inside
  the `_changeCountWatcher` callback (line ~63).
- Remove `module.preloadSpoonDocs` (function + doc comment, lines ~216–248).
- Rewrite the `__index` branch so it triggers only on `key == "_jsonForModules"`,
  iterates **all** registered files (drop the `if not file.spoon` filter entirely —
  there are no spoon files anymore), keeps the existing `lua`/`lua.`-name exclusion,
  caches into `_jsonForModules`, and returns it. No `_jsonForSpoons` codepath remains.
- In the `hs.doc.help` doc comment, drop the `hs.doc.preloadSpoonDocs` reference.

After this, confirm every `_jsonForSpoons` / `spoonDocumentation` reference is gone
from the consumers in §G (`common.lp:11`, `init.lua:94-95`, `index.lp:103-129`,
`module.lp:12-152`) — a leftover reference there will index a now-nil value.

### F. Doc system — Swift (`Sources/HSSwiftExtensions/Doc.swift`)

- `processRegisteredFile`: drop the `isSpoon`/`root` spoon routing; always use
  `documentationTree` as the root.
- `doc_help`: remove the `typeStr == "spoons"` branch.
- `doc_registerJSONFile`: remove the `isSpoon` parameter, the
  `["spoon"] = NSNumber(...)` storage, and the `isSpoon` mention in the doc comment.
- `doc_unregisterJSONFile` and `luaopen_hs_libdoc`: remove the
  `"spoon": NSMutableDictionary(... "spoons")` entry from the `documentationTree`
  initializer (both copies).

### G. Doc browser templates (`extensions/doc/hsdocs/`)

- `init.lua`: remove the `doc._jsonForSpoons` loop in `makeModuleListForMenu`.
- `common.lp`: remove `spoonDocumentation = doc._jsonForSpoons`.
- `index.lp`: drop `"Spoons"` from the tab list and remove the entire
  `<div id="Spoons">` block.
- `module.lp`: remove the `spoonDocumentation` loop populating `modNames`; remove
  all `isSpoon` handling (search only `documentation`); fix the header link and
  submodule links to drop the `spoon.` prefix and `?q=Spoons`.
- `index.md`: remove the "Spoon Plugin Documentation" and "Official Spoon
  repository" link rows.

### H. App lifecycle (Swift)

- `Sources/HSSwiftExtensions/AppLifecycle.swift`:
  - Remove `spoonsDir` from `AppLifecycleDirectories` and `currentDirectories()`.
  - Remove the `createSpoonsDirectory` parameter and the entire Spoons-dir
    creation/validation block from `prepareConfigDirectories`; it becomes just
    `try MJEnsureDirectoryExistsOrThrow(MJConfigDir() as String)`.
  - `AppLifecycleError.pathExistsButIsNotDirectory` is now unused → remove **only**
    that case (its only thrower was the Spoons check at `AppLifecycle.swift:77-78`).
    Keep `AppLifecycleError.changeDirectoryFailed` — still thrown by
    `changeToConfigDirectory` (`AppLifecycle.swift:87-91`).
- `Sources/HSSwiftExtensions/AppDelegate.swift`:
  - Remove the `org.cosmic-hammer.cosmichammer.spoon` branch in
    `application(_:openFile:)`.
  - Remove the `shouldPrepareSpoonsDirectory` variable and its three assignments;
    call `AppLifecycle.prepareConfigDirectories()` with no argument.

### I. Info.plist (`CosmicHammer/CosmicHammer-Info.plist`)

- Remove the `CFBundleDocumentTypes` dict for the Spoon type (extension `spoon`,
  `LSItemContentTypes` = `org.cosmic-hammer.CosmicHammer.Spoon`).
- Remove the `UTExportedTypeDeclarations` key and its array (only contained the
  Spoon UTI).

### J. Build script (`scripts/build/copy-resources.sh`)

- Remove the `copy_required ... Spoon.icns` line.
- (`smoke-resources.sh` does not list Spoon.icns, and dropping one top-level Lua
  file keeps the count well above its `>= 50` floor — no change needed there.)

### K. Tests (`Tests/CosmicHammerTests/AppLifecycleTests.swift`)

- Remove `prepareConfigDirectoriesThrowsWhenSpoonsPathIsAFile` and
  `prepareConfigDirectoriesCanSkipSpoonsForTestLaunches` (both Spoon-specific). The
  generic config-dir test (`prepareConfigDirectories()` with a blocking file at the
  config path) stays.

### L. Docs tool (`scripts/docs/Sources/BuildDocsCore/DocProcessor.swift`)

- Remove the "Spoon Plugin Documentation" and "Official Spoon repository" entries
  from the `links` array.

### M. Doc-comment prose (`extensions/doc/doc_builder.lua`)

- Reword the `=== hs.doc.builder ===` description and the `genJSON` notes to drop
  "Spoon bundles" framing, keeping the third-party-module capability. Doc-comment
  only; no behavior change.

### N. `TODO.org`

- Lines ~1033 and ~1037 describe the Spoons-path-derivation and
  "skipping Spoons creation for XCTest/UI-test config paths" behavior that §H
  removes. Update that note so it no longer describes a removed code path (drop the
  Spoons-specific wording; keep the surrounding config-directory note). Not
  build-affecting, but it would otherwise document behavior that no longer exists.

## Verification

Run in order (matches `just verify`):

1. `scripts/generate-hsextensions.sh` then `just check-generated` — confirms the
   regenerated metadata matches the manifest and no hand-editing drifted.
2. `just docs-lint` — doc comments still parse after edits.
3. `just build` (Debug) — Swift + bundle assembly, incl. `plutil -lint` on the
   edited Info.plist and the resource smoke check.
4. `just test` — full SPM suite; the two removed tests should be gone and the rest green.
5. Runtime smoke (ad-hoc): launch the built app against a temp config
   (`-MJConfigFile`) and confirm in the console that `hs.loadSpoon`, `hs.spoons`,
   and `spoon` are all `nil`, `require("hs.spoons")` errors, and `hs.doc.help()` /
   the doc browser still work (API tab present, no Spoons tab).

## Residual-reference sweep (acceptance gate)

After implementing, this must return only Hammerspoon-heritage hits (Section
"Scope boundary") and nothing about the Spoon plugin system. Exclude `build/`
(and VCS dirs): it is gitignored, untracked, generated output that still holds
stale Spoon artifacts (`build/html/hs.spoons.html`, `build/markdown/hs.spoons.md`,
bundled `spoons.lua` copies) until a fresh `just rebuild` regenerates it clean.

```
grep -rin "spoon" --include=*.lua --include=*.swift --include=*.m --include=*.h \
  --include=*.c --include=*.md --include=*.plist --include=*.tsv --include=*.manifest \
  --include=*.lp --include=*.sh --include=*.tpl --include=*.org \
  --exclude-dir=build --exclude-dir=.git --exclude-dir=.jj . \
  | grep -vi hammerspoon
```

The added `*.tpl`/`*.org` globs catch the `init.tpl` template and `TODO.org` notes;
the `--exclude-dir` flags drop stale generated output and VCS internals. Run a
`just rebuild` as part of verification so `build/` no longer carries Spoon artifacts.

## Risks / watch-items

- The `doc.lua` `__index` refactor must preserve `_jsonForModules` (drives the API
  tab); only the Spoon half is removed.
- `module.lp`/`index.lp` are fragile string templates — verify the doc browser
  renders after edits (runtime smoke).
- Removing `AppLifecycleError.pathExistsButIsNotDirectory` must not leave dangling
  references (grep first).
- Confirm no checked-in generated docs (`docs.json`, HTML) are committed that would
  embed Spoon entries; docs are built fresh, so this should be a non-issue.

## Implementation outcome (2026-06-09)

Implemented as planned (§A–§N), 24 files changed (+266 / −982). Independent Codex
review ran twice on the plan (converged after folding in the `init.tpl` deletion,
the `doc.lua _jsonForModules` rewrite emphasis, the manifest-first ordering, and the
`build/`-excluded acceptance grep) and once on the implementation diff (no P1
findings; two P2 cleanups applied: clamp `index.lp` `defaultTarget` to `"API"`, and
drop the now-dead `AppLifecycleDirectories.configDirAbsolute`).

Verification:
- `just check-generated`, `docs-lint`, `swift build`, resource copy + smoke check
  (without `Spoon.icns`, 111 Lua files) — all green.
- Logic suites exercising the change all pass: `AppLifecycleTests`, `Coresetup`,
  `LuaBootLifecycle`, `LuaRegSafety`, `ModuleLoadRegression` (39 tests, 6 suites).
- Residual-reference sweep: clean (only Hammerspoon-heritage hits remain).

Pre-existing environmental test failures (NOT caused by this change): the
hardware/permission/subprocess-bound suites fail in this sandbox (Audiodevice,
Brightness, Hotkey, Appfinder, Application, FS, Distributednotifications, Math,
Noises, Screen, Serial, Socket, Task). The diff touches none of their source. In the
full run, an early hardware-suite failure corrupts shared Lua state and cascades into
a crash at `LuaRegSafety/testModuleMetatablesSurviveReRequire` (which passes in
isolation and in a full run with the hardware suites skipped) — an environmental
cascade, independent of Spoon removal.

Not test-covered (verified by reading + careful edit): the `hsdocs` `.lp` browser
templates render only when the doc webserver runs (needs a GUI session).
