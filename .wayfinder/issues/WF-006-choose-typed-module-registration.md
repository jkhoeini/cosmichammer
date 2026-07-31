---
id: WF-006
title: Choose the typed Lua module registration architecture
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by:
  - WF-002
  - WF-003
  - WF-004
  - WF-005
---

## Question

Choose the registration shape that replaces string-based Swift symbol export/reimport: same-target direct function references with C-shaped signatures, LuaSwift closure registration, or a typed descriptor registry. Define function visibility, `extensions.manifest` semantics, treatment of genuine C modules, generated artifacts, package.preload behavior, Release retention, and the mechanism that preserves deterministic registration order.

## Resolution comments

### 2026-07-29 — Generate a direct-reference registry behind one deep interface

Choose **same-target direct Swift function references stored in a generated private descriptor table**. The module presented to production and tests has one interface:

```swift
internal func registerBundledLuaModules(in state: LuaState)
```

Its generated implementation owns a private descriptor shape equivalent to `(preloadKey: String, factory: Lua.lua_CFunction)` and the ordered descriptor list. The descriptor representation is not an interface for unrelated callers. Module factories remain ordinary C-shaped Swift functions because that is exactly the function type Lua requires; they are not C exports. `LuaState` and `lua_CFunction` come from LuaSwift, while the implementation may use the small raw CLua sequence needed to populate Lua’s `_PRELOAD` registry.

Reject LuaSwift closure registration for module factories. `push(_ closure:)` allocates a `LuaClosureWrapper`, installs housekeeping upvalues, initializes LuaSwift state, and adds throw-to-Lua-error trampoline semantics. Existing factories already have the exact noncapturing `lua_CFunction` shape, the direct-reference prototype proves it survives Release dead stripping, and changing their call/error semantics provides no leverage. Also reject an exposed general-purpose registry interface: the generated descriptor table is useful implementation data, but callers need only “register all bundled modules.”

### Manifest contract and order

The second `extensions.manifest` column changes semantics from `native-preloads` containing `package-key=C-symbol` to `native-factories` containing `package-key=Swift-factory-identifier`. The package key is explicit and remains the public Lua loading identity; the value is a Swift source identifier, not an ABI symbol and is never dynamically looked up. The existing four-column layout, Lua-module entries, aliases, bundle paths, and `-` sentinel remain unchanged.

The generator validates legal Swift identifiers plus duplicate factory identifiers and preload keys. The application row records its real Swift identity (`hs.libapplication=luaopen_hs_libapplication_new`); it is the only current manifest factory whose Swift identity differs from the old exported symbol. Registration is emitted in `LC_ALL=C` preload-key order. A census of all 93 manifest-backed entries confirmed that this order is byte-for-byte the current C-symbol-sorted registration order, so the rule becomes clearer without changing runtime order. The two AXUIElement nested factories are not package preloads and remain direct calls owned by their parent module.

### Visibility and cross-target consumers

Factories are `internal` by default. `LuaRuntime` calls the internal registrar directly; tests use `@testable import HSSwiftExtensions` and call the same interface or internal factory identity. The registrar loses both `@_cdecl("HSExtensionsRegisterAll")` and the test-local `@_silgen_name` import.

`public` is allowed only for a declared cross-target typed consumer. Today that is the OpenTelemetry benchmark. Its cutover exposes one deliberately named public Swift module-factory function and calls it through the normal `HSSwiftExtensions` dependency; it does not preserve the legacy C name as public ABI. No other factory becomes public for tests, headers, or hypothetical consumers.

### Generated artifacts and Lua behavior

- Keep `Sources/HSSwiftExtensions/HSExtensionsGenerated.swift`, but emit direct factory references, the private descriptors, and the internal registrar. Emit no `@_silgen_name`, `@_cdecl`, or C forward declaration.
- Stop generating `Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h` and remove its umbrella include from `HSExtensions.h`. The consumer census found no compiled C/Objective-C caller; the registration owner, not the historical-header owner, owns this generated-header deletion.
- Keep `_loader_metadata.lua`, but represent native modules only by preload keys: an indexed key set and an ordered key list. Remove `.symbol` fields because Swift implementation names are not Lua loader metadata. Keep Lua-module, alias, lazy-extension, and copy-map metadata unchanged.
- Update `check-generated-files.sh` to compare manifest keys and Swift factory identifiers with generated direct references, reject duplicates, verify exact ordered parity rather than sorted-set parity alone, and retain regeneration/idempotence checks.
- Preserve the current `luaL_getsubtable(..., "_PRELOAD")`, `lua_pushcclosure`, and `lua_setfield` behavior, stack balance, keys, aliases, lazy loading, and startup timing. There is one registration path and no fallback or compatibility shim.

All 93 manifest-backed factories are presently Swift implementations in `HSSwiftExtensions`; the generated claim that lsqlite3 is a C implementation is stale. Do not add a sum type or C-symbol branch for a nonexistent case. A future genuine C module must enter through an explicit Swift adapter in a dependency direction that avoids the current `HSExtensions` → `HSSwiftExtensions` edge, or trigger a new architecture decision.

Release retention comes solely from the generated static function references—no `@_used`, `-all_load` assumption, `dlsym`, or exported symbol. The manifest-registry prototype must prove the real generated shape in Debug and Release with dead stripping, require every preload, assert exact order and stack/module-table invariants, regenerate twice identically, confirm generated/project source contains no project-owned underscored ABI attributes, and confirm the linked artifact exports none of the removed project symbol names. Existing prototype, typed-test, and implementation-wave tickets cover that proof and cutover; no new ticket or Fog graduation is required.
