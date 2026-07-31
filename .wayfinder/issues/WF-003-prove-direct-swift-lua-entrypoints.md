---
id: WF-003
title: Prove direct Swift Lua entrypoints satisfy lua_CFunction
state: closed
labels:
  - "wayfinder:prototype"
parent: WF-001
assignee: Main
blocked_by: []
---

## Question

Build the smallest reversible compile/runtime experiment proving whether a plain same-target Swift function can be referenced directly as Lua’s `lua_CFunction` without `@_cdecl` or a matching `@_silgen_name`. Cover one simple module, package.preload loading, the exact Optional/IUO function type used by production and tests, and Release dead-stripping/retention. Link the prototype and observed evidence as issue assets.

## Resolution comments

### 2026-07-29 — Direct typed entrypoints are viable

A plain same-target Swift function needs neither `@_cdecl` nor `@_silgen_name` to serve as a Lua module entrypoint when the generated registry references the function directly. The [prototype source](../prototypes/direct-swift-lua-entrypoint/Sources/main.swift) defines an unannotated function with the production IUO parameter, assigns it to both the generated registry’s exact `@convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32` shape and LuaSwift’s `Lua.lua_CFunction`, installs it in `package.preload`, and loads it through a real Lua `require` call.

The reversible asset consists of the [standalone package](../prototypes/direct-swift-lua-entrypoint/Package.swift), its pinned LuaSwift 1.0.0 resolution, the source above, and a [one-command Debug/Release runner](../prototypes/direct-swift-lua-entrypoint/run.zsh). It does not modify production targets, manifests, generators, or tests.

Observed evidence:

- Debug compiled and printed `configuration=debug preload=require-ok answer=42`.
- Release compiled with `-O`, whole-module optimization, and `-dead_strip`, then printed `configuration=release preload=require-ok answer=42`; the typed reference retained the entrypoint through optimized dead stripping.
- The prototype tree contains no `@_cdecl` or `@_silgen_name` annotation.
- SourceKit diagnostics reported no errors.
- Repository `just verify` completed with generated files current and 1,044 tests across 127 suites passing.
- Independent review found no proof-invalidating issue; its sole informational concern—confirming the linker actually received `-dead_strip`—was resolved by inspecting the generated Release link command.

This proves the direct same-target function-reference seam. It does not choose the generated registry’s final descriptor shape or address genuine cross-target/C consumers; those remain separate architecture and census decisions.
