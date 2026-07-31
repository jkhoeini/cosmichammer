---
id: WF-004
title: Complete the dynamic and generated symbol consumer census
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by: []
---

## Question

Establish whether scripts, documentation tooling, benchmarks, packaging, symbolication, generated files, dlsym/nm/otool usage, tests, vendored sources, or external build inputs consume stable `@_cdecl` symbol names or generated C headers. Classify every one of the 195 exports by its actual caller and replacement seam, recording uncertainty where static source search cannot prove absence.

## Resolution comments

### 2026-07-29 — Complete consumer census

The row-level result is the [195-symbol consumer census](../assets/cdecl-consumer-census.tsv). Each row records the exported C name, Swift identity, declaration, actual callers, consumer class, replacement seam, evidence, and bounded uncertainty. A fresh invariant check matched its 195 unique rows exactly to the 195 unique active `Sources/**/*.swift` `@_cdecl` declarations; all required fields are populated. Independent review returned no issues after checking the full symbol set and representative callers in every category.

Findings:

- Of 95 Lua entrypoints, 93 are consumed through the manifest-generated `@_silgen_name` registry and `package.preload`; the two AXUIElement submodules are called directly by their parent Swift module factory. Lua facades consume package keys, not C symbol names. Tests and the OpenTelemetry benchmark add typed/direct imports that must migrate with the registry.
- All 40 algorithm C ABIs are statically unconsumed. Six implementations—CRC32 and SHA256 init/append/finish—remain reachable only through Swift-identity tests; the other 34 identities have no active-tree caller. Production hashing uses separate typed `Hash.swift` callbacks. Ownership remains with the dedicated Algorithms decision.
- Of 58 native bridge exports, 26 have same-target Swift callers, 23 additionally have test-only Swift callers, one is test-only, and eight are unconsumed/header-only. No active in-repo C/Objective-C caller requires their C ABI.
- `launchCosmicHammer` is the sole non-test cross-SPM-target consumer. It is Swift-to-Swift linkage hidden behind `@_silgen_name`, so its replacement is a public typed app-bootstrap interface plus a direct SwiftPM dependency.
- `HSExtensionsRegisterAll` is called directly inside the production target and through `@_silgen_name` by test bootstrap. It becomes a typed registry/bootstrap hook shared by production and tests.
- The manifest, generator, generated preload header, metadata, copy map, checker, hooks, packaging scripts, and documentation mention or reproduce symbol strings but are definitions, checks, packaging inputs, or prose—not independent runtime callers. No project-owned symbol is passed to `dlsym`/`dlopen`; active packaging contains no `nm`, `otool`, symbolication, or external build hook consumer.

Static absence is deliberately not claimed as global absence. User/site `.dylib` and `.so` modules admitted by `package.cpath`, downstream clients of the static product/header, installed binaries, computed names, and ignored external inputs remain bounded uncertainty. Under the established end-state contract, unsupported hypothetical consumers do not retain a C ABI. Final convergence must still inspect built artifacts for all 195 names, regenerate/check manifest parity, run the preload/require sweep and direct bridge/algorithm/bootstrap paths, and audit any configured external module paths.

The existing registration, header-retirement, Algorithms ownership, test-equivalence, and convergence tickets already own the surfaced follow-up work; no new ticket is required.
