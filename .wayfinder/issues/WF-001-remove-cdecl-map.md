---
id: WF-001
title: Remove @_cdecl through idiomatic Swift and LuaSwift seams
state: open
labels:
  - "wayfinder:map"
parent: null
assignee: null
blocked_by: []
---

## Notes

Domain: Cosmic Hammer Swift/Lua interop, generated module registration, and SwiftPM target architecture.

Every session must consult `AGENTS.md`, `skill://codebase-design`, `skill://domain-modeling`, `tigerbeetle-philosophies.md`, `tigerbeetle-deterministic-testing.md`, and the active CLua-to-LuaSwift work packages in `TODO.org`. Implementation sessions must also consult `skill://implement`, `skill://test-driven-development`, `skill://requesting-code-review`, `skill://verification-before-completion`, and `skill://jujutsu`.

Current inventory: 195 unique project-owned `@_cdecl` annotations across 111 files. Roughly 95 are same-target Lua entrypoints; about 40 are duplicated algorithm exports; the remaining historical Swift/C bridge annotations have only one confirmed live cross-target consumer, `launchCosmicHammer`. These are investigation facts, not architecture decisions.

Standing constraints: remove every project-owned `@_cdecl` annotation through typed Swift/LuaSwift interfaces; preserve public Lua behavior and deterministic manifest-derived registration order; use clean cutovers without aliases or compatibility shims; keep generated code manifest-driven; ground behavioral oracles in pre-migration evidence; control time, randomness, I/O, scheduling, UUIDs, and faults in deterministic tests; exercise the same production logic under simulation; retain per-slice real-I/O complements where simulation cannot prove the boundary.

Parallel implementation is required, but shared interfaces, ownership, independent oracle review, adversarial review, deterministic evidence, and integration responsibilities must be decided before fan-out. Agents skip project-wide validation during concurrent edits; integration owns the final `just verify` gate.

## Decisions so far

- [Establish the interop-free end-state contract](WF-002-establish-interop-free-end-state.md) — Remove project-owned C-symbol coupling with behavior-preserving, atomic module cutovers and least-visibility typed Swift seams.
- [Prove direct Swift Lua entrypoints satisfy lua_CFunction](WF-003-prove-direct-swift-lua-entrypoints.md) — A generated same-target registry can pass unannotated Swift entrypoints directly as `lua_CFunction`, including optimized Release builds.
- [Complete the dynamic and generated symbol consumer census](WF-004-complete-symbol-consumer-census.md) — All 195 exports are classified by caller and replacement seam; no active in-repo C/Objective-C or dynamic consumer requires their stable C ABI.
- [Reconcile `@_cdecl` removal with the active LuaSwift migration](WF-005-reconcile-active-luaswift-migration.md) — Put a direct-registry gate before remaining WPs, then give each module owner every annotation in its files while reserving generated registration for one owner.
- [Choose the typed Lua module registration architecture](WF-006-choose-typed-module-registration.md) — Generate direct Swift factory descriptors behind one internal registrar, with explicit manifest identities and preload-key order; remove symbol glue and closure wrappers.
- [Prototype the manifest-generated direct Swift registry](WF-007-prototype-manifest-swift-registry.md) — A generated private descriptor registry passed Debug/Release, parity, ordering, alias, lazy-load, userdata, callback, nested-module, stack, idempotence, and no-C-export checks.
- [Define the expert-agent execution and independent review protocol](WF-008-define-expert-agent-protocol.md) — Separate slice implementation, oracle ownership, adversarial review, and integration behind explicit artifacts, disjoint ownership, bounded coordination, and deterministic plus real-I/O gates.
- [Define typed test loading and differential equivalence seams](WF-009-define-typed-test-equivalence-seams.md) — Generate typed manifest identities over private factories; migrate tests through typed direct or production `require` paths and prove cutover against an independently approved oracle ledger.
- [Define TigerStyle and deterministic migration gates](WF-010-define-deterministic-migration-gates.md) — Replay explicit seed/epoch/identity inputs, enforce visible finite progress budgets, and select fault, assertion-pair, and real-I/O evidence by changed seam.
- [Restore deterministic replay and liveness prerequisites](WF-011-restore-replay-liveness-prerequisites.md) — Preserve timer-then-event-loop phases behind explicit replay inputs and a shared finite budget with actionable quiesced, exhausted, and stalled receipts.
- [Decide Algorithms.swift ownership and deletion](WF-012-decide-algorithms-ownership.md) — Delete the 40 unconsumed C-shaped duplicate exports; keep private `Hash.swift` callbacks behind public `hs.hash` behavior and a complete known-answer matrix.
- [Choose the app bootstrap and SwiftPM target seam](WF-013-choose-app-bootstrap-seam.md) — Make `HSApp` explicitly depend on both implementation targets and call one public `AppBootstrap.run()` interface; remove the hidden C-symbol bridge.

## Fog

- Module-specific ABI, userdata, callback, or lifecycle anomalies that only become visible after the typed registration prototype exists.
- Residual reflection- or symbol-name-based consumers that static source census cannot reveal and that surface only during removal or release verification.
- Whether a future Objective-C translation unit could need the currently unused `HSLogger.h` C-extern pattern; no present consumer exists.
- Final cleanup and documentation changes after the migrated system demonstrably works.
