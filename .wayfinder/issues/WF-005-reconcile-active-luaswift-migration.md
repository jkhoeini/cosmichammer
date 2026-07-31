---
id: WF-005
title: Reconcile @_cdecl removal with the active LuaSwift migration
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by: []
---

## Question

Decide whether this effort lands before, inside, or after the active CLua-to-idiomatic-LuaSwift WP2 and WP4–WP8 pipeline in `TODO.org`. Resolve ownership for overlapping files such as `Keycodes.swift`, `AXUIElementLegacy.swift`, application/window/eventtap clusters, and generated registration so parallel agents do not implement competing entrypoint contracts or duplicate refactors.

## Resolution comments

### 2026-07-29 — Integrate removal behind a registration-first gate

This effort lands **inside** the remaining CLua-to-idiomatic-LuaSwift pipeline, but no WP2 or WP4–WP8 implementation starts under the obsolete exported-entrypoint contract. The observable change in this ticket is execution ownership and ordering only; production behavior and source are out of scope. Verification is that the active plan no longer preserves project-owned C entrypoints, every overlapping source has one owner, and the tracker exposes the registration decision next. This is a reversible planning change.

The gate is:

1. Keep the completed WP0, WP1, and WP3 work as-is.
2. Pause unstarted WP2 and WP4–WP8 implementation while the typed registration architecture, its manifest-generated prototype, typed test-loading seam, and migration gates are resolved.
3. Land one registry-foundation cutover before those WPs resume. Its exclusive owner controls `extensions.manifest` entrypoint metadata, `scripts/generate-hsextensions.sh`, every generated registration artifact, preload/loader tests, and migration of test/benchmark `@_silgen_name` entrypoint imports. The generated registry references Swift function identities directly in deterministic manifest order. It may temporarily reference functions that still carry `@_cdecl`; it creates no second registration path and leaves no project-owned `@_silgen_name` caller.
4. Resume WP2 and WP4–WP8 on that foundation. Each module/cluster owner removes every project-owned `@_cdecl` annotation in its owned Swift files while performing the already-planned LuaSwift body/userdata/ref migration. The function may retain its C-shaped `lua_CFunction`-compatible Swift type; it no longer exports or reimports a C symbol. Module owners do not edit the manifest schema, generator, generated files, or shared loader fixtures.
5. Run annotation-only cleanup waves for files outside the remaining WPs. These include already-migrated `Math.swift`, `Base64.swift`, and `Timer.swift`, raw-CLua modules intentionally excluded from body migration such as SQLite/hardware modules, and other source files not assigned to WP2/WP4–WP8. Removing `@_cdecl` does not require converting a raw CLua body.

File ownership follows the existing WP partition, expanded to the whole file or atomic cross-module cluster:

- WP2 owns all annotations and body work in JSON, Plist, Settings, Hash, and Pasteboard sources.
- WP4 owns CanvasMatrix, Doc, Keycodes, Spaces, UIElement, and UIElementWatcher sources. The Keycodes owner therefore removes `keycodes_cachemap`, `getLayoutName`, `pushSourceIcon`, and its Lua entrypoint together; non-module cleanup must exclude `Keycodes.swift`.
- WP5 owns Image and Styledtext plus every cross-module producer that must flip atomically.
- WP6 owns callback/watcher, Hotkey, Dialog, and URL event sources; WP7 owns networking/async sources.
- WP8 cluster owners own every annotation in their cluster. In particular, Application/Window, Eventtap/EventtapEvent, and AXUIElement/`AXUIElementLegacy.swift` (including nested observer/text-marker factories) are not separate bridge-cleanup assignments.
- The Algorithms owner and app-bootstrap owner remain separate because their decisions and target seams are independent of LuaSwift body migration. Historical header deletion remains with the header-retirement owner, coordinated with—not duplicated by—the Swift-file owner.

Test ownership follows the same seam: registry/loader equivalence belongs to the registry and typed-test owners; module Lua-visible behavior, userdata identity, lifecycle, deterministic simulation, and necessary real-I/O complements belong to the module WP owner. Independent oracle and review agents never edit production files.

The former `TODO.org` rule that entrypoint annotations and generated registration were permanently outside the LuaSwift pipeline is superseded. Existing tickets already cover registration architecture/prototype, typed test seams, migration gates, header/algorithm/bootstrap decisions, and the conflict-free implementation partitions; no new ticket or Fog graduation is required.
