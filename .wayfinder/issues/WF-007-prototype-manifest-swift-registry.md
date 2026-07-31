---
id: WF-007
title: Prototype the manifest-generated direct Swift registry
state: closed
labels:
  - "wayfinder:prototype"
parent: WF-001
assignee: Main
blocked_by:
  - WF-006
---

## Question

Produce a minimal manifest-generated registry implementing the chosen architecture for representative simple, userdata, callback, and nested modules. Prove native-preload parity, aliases, lazy loading, module-table and stack invariants, deterministic order, Release retention, regeneration idempotence, and absence of project-owned underscored ABI attributes. Link the prototype and evidence rather than pasting them into the issue.

## Resolution comments

### 2026-07-29 — Direct manifest registry works across representative module shapes

The throwaway [standalone package](../prototypes/manifest-swift-registry/Package.swift) implements the chosen architecture with a [four-column manifest](../prototypes/manifest-swift-registry/prototype.manifest), a [one-pass generator](../prototypes/manifest-swift-registry/generate.zsh), [direct-reference generated Swift](../prototypes/manifest-swift-registry/Sources/GeneratedRegistry.swift), key-only [Lua loader metadata](../prototypes/manifest-swift-registry/GeneratedMetadata.lua), and a [one-command runner](../prototypes/manifest-swift-registry/run.zsh). LuaSwift is pinned to 1.0.0 in the linked package resolution.

The generated registry has one callable interface, `registerBundledLuaModules(in:)`, and a private ordered descriptor list of `(preloadKey, Lua.lua_CFunction)`. Its manifest is intentionally declared out of order and includes an explicitly non-derived Swift identity, `hs.libprototype_simple=prototypeSimpleFactoryV2`. Generation emits callback, nested, simple, then userdata in `LC_ALL=C` preload-key order. The nested child factory is a direct private Swift call from its parent and is absent from manifest metadata.

Representative runtime coverage is real rather than stubbed:

- simple module returns a table with answer 42;
- userdata module creates userdata with a registered metatable and round-trips value 7;
- callback module synchronously invokes a Lua callback and returns 42;
- nested parent installs a directly called child table with answer 9;
- four Lua facades exercise lazy `hs` lookup, and four preload aliases resolve to the native targets.

Fresh execution of the runner produced, in both Debug and Release:

```text
order=hs.libprototype_callback,hs.libprototype_nested,hs.libprototype_simple,hs.libprototype_userdata preload=4/4 aliases=4/4 lazy=4/4 simple=42 userdata=7 callback=42 nested=9 stack=balanced
```

The same run generated twice and byte-compared both outputs, confirmed exact manifest/Swift/metadata order parity, built Release with `-dead_strip`, ran the Release binary successfully, found no `@_cdecl` or `@_silgen_name` in prototype source, and found no unmangled C factory exports in the linked binary. The second full run compiled without warnings.

This validates the registration mechanism and representative module shapes, not the production cutover of all 93 manifest-backed factories. The existing typed-test and implementation-wave tickets own full production parity, loader-oracle migration, and the require-all gate. No new ticket is required; no production source or generated production artifact changed.
