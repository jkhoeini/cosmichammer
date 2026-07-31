---
id: WF-009
title: Define typed test loading and differential equivalence seams
state: closed
labels:
  - "wayfinder:prototype"
parent: WF-001
assignee: Main
blocked_by:
  - WF-006
  - WF-007
  - WF-008
---

## Question

Replace test-local `@_silgen_name` and raw function-pointer imports with typed module-loading interfaces, then define old-versus-new behavioral comparison. Lock oracles against pre-existing evidence such as conversion-divergence characterization, module stack/type assertions, manifest-loading regressions, and require-all behavior before implementation slices begin; new assertions must be independently authored or approved under the expert-agent protocol.

## Resolution comments

### 2026-07-29 — Generate typed identities; compare through locked observations

Adopt the interface demonstrated by the throwaway [typed-loader package](../prototypes/typed-test-loader/Package.swift): generate an internal `BundledLuaModule: String, CaseIterable` from explicit manifest identities, keep its `Lua.lua_CFunction` mapping private, and expose only `registerBundledLuaModules(in:)` plus `loadBundledLuaModule(_:in:)`. The concrete generated shape is in [GeneratedRegistry.swift](../prototypes/typed-test-loader/Sources/GeneratedRegistry.swift); its source is the deliberately shuffled [prototype manifest](../prototypes/typed-test-loader/prototype.manifest) and [generator](../prototypes/typed-test-loader/generate.zsh).

Production bootstrap and booted test setup call `registerBundledLuaModules(in:)` directly. Registration/isolated functional tests pass a `BundledLuaModule` to `loadBundledLuaModule`; `withModuleLoaded` accepts that typed identity rather than a raw function pointer. Manifest-loading and require-all tests register once and exercise `require(module.rawValue)`, preserving the actual production preload path. Factories remain invisible to callers and tests.

The current test census contains 41 `@_silgen_name` declarations in 20 files: 37 Lua factories plus `HSExtensionsRegisterAll` are owned by this seam; `MJLuaAlloc`, `MJLuaDealloc`, and `objc_tryCatch` remain for the non-module bridge work. Eighty distinct `luaopen_hs_*` identifiers occur across 68 test files; direct references migrate to generated enum cases without preserving symbol-name aliases.

Do not keep old and new production loaders simultaneously. Differential proof is baseline-then-cutover: capture the existing suite before edits, switch callers atomically to the typed identity, then rerun the same observations. The independent oracle owner approved the linked [oracle ledger](../prototypes/typed-test-loader/oracle-ledger.tsv), distinguishing existing locks from architecture-derived assertions and narrowing three traps:

- compare module key sets, Lua types per key, and locked behavioral probes—not table identity across separate factory calls;
- prove the registered factory path with a delegating `package.preload` spy that observes one call and the same table in the delegated result, `require` result, and `package.loaded`;
- remove `.symbol` metadata expectations at cutover because Swift implementation names are no longer loader metadata; retain key presence, uniqueness, ordered/indexed parity, and preload registration.

Conversion-divergence and LuaSwift coexistence suites remain unchanged baseline gates; copies inside the standalone prototype would not be independent evidence. General stack delta `== 1` is approved only for the prototype; production-wide generalization requires capture beyond the existing `hs.hash` lock.

Fresh pre-prototype `just test` evidence passed 1,044 tests in 127 suites, including module registration, manifest loading, require-all, conversion equivalence, and coexistence. The [one-command runner](../prototypes/typed-test-loader/run.zsh) then passed Debug and Release with:

```text
order=hs.libprototype_callback,hs.libprototype_nested,hs.libprototype_simple,hs.libprototype_userdata modules=4/4 legacy=typed=require stack=balanced callback=42:callback;nested=9:nested;simple=42:simple;userdata=userdata:7
```

That run byte-compared two generations, proved exact manifest order, compared result count/type/stack/shape/probes across direct Swift reference, typed direct load, and typed register-plus-require, exercised the delegating preload spy, built Release with dead stripping, and found no `@_cdecl`, `@_silgen_name`, or unmangled C factory export. An independent adversarial reviewer reported no issues and confirmed the prototype answers the design question without production changes.

The prototype and oracle ledger are durable evidence; production implementation belongs to the existing registry-foundation and wave-partition tickets. No new ticket or Fog graduation is required.
