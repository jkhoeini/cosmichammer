---
id: WF-013
title: Choose the app bootstrap and SwiftPM target seam
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by:
  - WF-002
  - WF-004
---

## Question

Decide how `HSApp` calls `launchCosmicHammer` without `@_cdecl` and `@_silgen_name`: direct dependency/import of `HSSwiftExtensions`, a moved Swift entrypoint, or another typed target seam. Produce the intended SwiftPM dependency graph and explain how it keeps the executable thin without relying on hidden transitive linkage.

## Resolution comments

### 2026-07-29 — Make `HSApp` the explicit composition root

Keep the executable target thin and make its dependency honest. `HSApp` directly depends on both `HSExtensions` (to link the Clang/Objective-C extension objects) and `HSSwiftExtensions` (to import the Swift bootstrap interface). Replace the hidden symbol call with:

```swift
import Foundation
import HSSwiftExtensions

exit(AppBootstrap.run())
```

`HSSwiftExtensions` exposes exactly one new cross-target interface in `AppBootstrap.swift`:

```swift
public enum AppBootstrap {
    public static func run() -> Int32
}
```

`run()` retains the current implementation: enter an autorelease pool, obtain `NSApplication.shared`, create and retain `MJAppDelegate` for the duration of `app.run()`, assign it as delegate, run the AppKit event loop, and return `0` after the loop stops. Its interface contract is synchronous, main-process startup; it blocks until `NSApplication.run()` returns. `MJAppDelegate` remains internal.

Remove the old function from `AppDelegate.swift`, including both `@_cdecl("launchCosmicHammer")` and the Swift identity. Remove `@_silgen_name` from `HSApp/main.swift`. Do not leave a free-function alias or compatibility export.

The intended target graph is:

```text
CosmicHammer product -> HSApp
HSApp               -> HSExtensions
HSApp               -> HSSwiftExtensions
HSExtensions         -> HSSwiftExtensions   (existing; unchanged)
HSSwiftExtensions    -> HSDSTCore + package products
```

The duplicate path to `HSSwiftExtensions` is intentional: linking through `HSExtensions` and compiling an `import HSSwiftExtensions` are distinct responsibilities. The direct edge prevents the executable from relying on hidden transitive linkage. This remains acyclic because neither Swift target depends back on `HSApp`.

Reject moving AppKit startup into `HSApp`: that would make the executable import Cocoa and force `MJAppDelegate` public, widening the interface. Reject a new SwiftPM bootstrap target: it would be a shallow one-function adapter and would not remove the need for the executable to link both existing implementation targets. Reject keeping a public free `launchCosmicHammer` function: `AppBootstrap.run()` gives the one genuine cross-target seam a discoverable typed owner without preserving its C ABI name.

#### Ownership and cutover

`Package.swift` remains integration-owner-only under the expert protocol. The integration owner first adds `HSSwiftExtensions` to `HSApp.dependencies`; this redundant direct edge is buildable before callers change. The bootstrap slice then exclusively owns `Sources/HSApp/main.swift`, the entrypoint block in `AppDelegate.swift`, and new `AppBootstrap.swift`; it lands the typed consumer/producer and removes both underscored annotations atomically. Schedule it before any later AppDelegate/native-bridge slice. No registry, generated, header, Lua, or extension-module file changes.

#### Verification contract

1. `swift package describe --type json` shows `HSApp` directly depends on both implementation targets; `main.swift` imports `HSSwiftExtensions` and contains no underscored declaration.
2. Debug and Release app builds link without undefined symbols. Source checks find no bootstrap `@_cdecl`/`@_silgen_name` declaration in `HSApp` or `HSSwiftExtensions`; the CosmicHammer app executable has no exact unmangled `launchCosmicHammer` export. Exclude the standalone `hs` executable and its unrelated private `launchCosmicHammer(auto:)` helper from this check. A normal mangled `AppBootstrap.run()` is expected.
3. Existing app lifecycle, Lua boot lifecycle, URL/open-file, menu/dock, reload/shutdown, and settings tests remain green. No unit test calls `AppBootstrap.run()` because entering a second `NSApplication` loop is not a representative interface test.
4. A real app smoke launches the built bundle with an isolated `-MJConfigFile`; a minimal `init.lua` writes a marker, proving the launch half of the new executable edge reached `MJAppDelegate`, Lua bootstrap, and user config. Observe the marker within a fixed timeout, then terminate the process cleanly. Normal `NSApplication.terminate` exits inside `app.run()`, so the smoke does not claim to observe the `Int32` return path; that return preserves the current type-level convention and is exercised only if the event loop returns.
5. Integration runs `just verify`, then repeats the marker smoke against the Release bundle.

Independent review confirmed the seam and found two acceptance overclaims: the standalone `hs` CLI has an unrelated private helper with the same base name, and normal app termination does not return through `Int32`. Both checks are now scoped accurately. Fresh pre-decision graph evidence from `swift package describe --type json` confirms `HSApp` currently depends only on `HSExtensions`, while that Clang target transitively depends on `HSSwiftExtensions`. LSP and the consumer census find one producer and one cross-target consumer.

Fresh `just build` passed. A fresh full `just test` run exposed two cross-suite shared-Environment failures in `DSTSettingsIntegrationTests`; the isolated suite passed all 15 tests, so this is unrelated baseline interference rather than bootstrap behavior. It is tracked separately by [Eliminate cross-suite global Environment test interference](WF-018-eliminate-global-environment-test-interference.md) and will block final convergence. No production source is changed by this decision session; the existing non-module bridge partition owns the bootstrap implementation slice.
