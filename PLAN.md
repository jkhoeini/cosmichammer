# Plan: Canvas matrix typed conversion fixes

## Scope

Implement the still-useful Canvas matrix slice from stale head `uvokrvxsuqsq`
(`wip: canvas matrix conversion`).

This slice covers:

- `Sources/HSSwiftExtensions/CanvasMatrix.swift`
- `Tests/CosmicHammerTests/CanvasMatrixTests.swift`
- `TODO.org`

Do not touch broad Canvas element conversion, WebView, socket, console, speech,
or generic `LuaHelpers.swift` in this commit.

## Audit Summary

The stale diff is narrow and still useful:

- `CanvasMatrix.swift` still pushes `NSAffineTransform` through generic
  `lua_pushany`, but `LuaHelpers.swift` does not special-case
  `NSAffineTransform`.
- Matrix methods still pull matrix tables through `lua_tovalue(... as!
  NSAffineTransform)`. Current `lua_tovalue` converts Lua tables to generic
  dictionaries, so chained matrix methods can fail instead of receiving an
  `NSAffineTransform`.
- `CanvasLuaMethods.swift` already has local transform table push/parse helpers,
  and current Canvas element value conversion already handles transformation
  tables. This slice should fix only the standalone matrix module.
- `extensions/canvas/canvas_matrix.lua` registers the `hs.canvas.matrix`
  metatable in the Lua registry after loading `hs.libcanvasmatrix`, so native
  functions called through `require("hs.canvas.matrix")` can return chainable
  typed tables.

Not useful to replay:

- Do not add a generic `NSAffineTransform` branch to `LuaHelpers.swift`; matrix
  values are Canvas-specific typed tables and the existing Canvas-local helpers
  are the right boundary.
- Do not refactor the broader Canvas value conversion that already landed.
- Do not change matrix arithmetic semantics or add new public API.

## Implementation

1. In `CanvasMatrix.swift`:
   - Return all constructor/method results through `pushNSAffineTransform`
     instead of `lua_pushany`.
   - Pull all matrix receiver/argument tables through
     `toNSAffineTransformFromLua`.
   - Make `toNSAffineTransformFromLua` return `NSAffineTransform` instead of
     `Any!` so call sites are typed.
   - Preserve current tolerant field behavior: missing/non-number fields log and
     retain the default identity field rather than raising a new Lua error.

2. In `CanvasMatrixTests.swift`:
   - Add a focused Lua test that requires `hs.canvas.matrix`, constructs a
     matrix, chains `translate`, `scale`, and `append(identity)`, and asserts the
     result is a table with `hs.canvas.matrix` metatable, chainable methods, and
     expected transform fields.
   - Add append/prepend coverage with plain six-field Lua tables, proving matrix
     methods accept tables that have the right shape even before a metatable is
     attached.
   - Add coverage for partial/missing fields defaulting to identity values and
     returned metatable `__type`.

3. Update `TODO.org` after plan review, implementation review, build, and
   focused tests.

## Verification

Run focused tests:

```sh
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter CanvasMatrixTests
```

Run adjacent Canvas conversion tests:

```sh
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter CanvasValueConversionTests
```

Then run:

```sh
mise exec -- just build
```
