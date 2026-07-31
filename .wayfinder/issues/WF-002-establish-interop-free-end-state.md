---
id: WF-002
title: Establish the interop-free end-state contract
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by: []
---

## Question

Define exactly what “remove every project-owned `@_cdecl` annotation” means: whether project-owned `@_silgen_name` counterparts and orphan C headers also leave, which genuine C/Objective-C/system ABI seams remain allowed, and which public Lua behavior, module names, visibility rules, clean-cutover rules, and deterministic registration-order invariants cannot change. Leave registration mechanism choices to the architecture ticket.

## Resolution comments

### 2026-07-29 — End-state contract

The migration ends with zero project-owned `@_cdecl` annotations and zero `@_silgen_name` declarations used to link project-owned symbols. Orphan C headers, generated symbol-import glue, and compatibility exports leave with their callers. `@_silgen_name` remains permitted only for external macOS/private-framework symbols unavailable through supported Swift modules; genuine Objective-C implementations such as `objc_tryCatch` remain explicit native seams without Swift `@_cdecl`.

The change is strictly behavior-preserving across every public `hs.*` module, alias, function, method, return/error convention, module-loading path and order, user `init.lua`, CLI, AppleScript, console, reload/shutdown, callback, object-identity, userdata/GC, and telemetry surface. A native C-symbol ABI is not public unless the consumer census proves a real external consumer.

Rollout may be incremental across modules, but every landed slice is an atomic cutover of its owned declarations, callers, tests, and registration. Different modules may temporarily use old and new internal patterns; no module may have dual registration, fallback shims, aliases, or duplicate implementations. Every slice remains independently buildable and behaviorally verified, and final convergence removes the remaining annotations and internal symbol bridges.

Swift declarations use the least visibility required. Same-target entrypoints and helpers become `internal`; tests use `@testable import`; `public` is reserved for typed APIs required by declared SwiftPM target dependencies. Historical headers, symbol names, tests, and hypothetical future consumers do not justify public visibility. Manifest-derived preload membership and the current deterministic registration order remain invariant unless a separate decision explicitly changes them.

The concrete registration mechanism is intentionally left to the module-registration architecture decision.
