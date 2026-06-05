# Plan: Sharing userdata and typed-item conversion fixes

## Scope

Implement the sharing slice from stale head `onltpntqosrs`
(`wip: device network object conversion audit`).

This slice covers:

- `Sources/HSSwiftExtensions/Sharing.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not touch Razer, serial, StreamDeck, WebView, or generic `LuaHelpers.swift`
in this commit.

## Audit Summary

The stale sharing changes are useful, but need current-helper adaptation:

- Sharing service constructors, delegate callbacks, methods, and metamethods
  still rely on generic `lua_pushany` / `lua_tovalue(... as! HSSharingService)`
  for service userdata.
- Sharing item arrays can contain `hs.image`, `hs.styledtext`, and
  `hs.sharing.URL(...)` tables. Generic table conversion loses the typed native
  values that `NSSharingService` expects.
- Generic `lua_pushany` turns `NSURL` into a plain string. The sharing module
  promises URL tables, so sharing URL results need a module-local URL pusher.
- The stale helper names `lua_pushNSImage` and `lua_pushNSAttributedString` do
  not exist in current head. Use `NSImage_tolua` and
  `NSAttributedString_toLua`.
- `NSImage_tolua` returns `0` without pushing if the image is nil or invalid.
  Image result paths and sharing item-array image pushes must push nil
  explicitly in that case.
- `NSAttributedString_toLua` was audited: it always pushes either styledtext
  userdata or nil and returns `1`, so it does not need the same return-0 guard.

## Implementation

1. In `Sharing.swift`:
   - Add `sharingItemFromLua` / `sharingItemsFromLua` helpers that preserve:
     - `hs.image` userdata via `toNSImage`;
     - `hs.styledtext` userdata via `toNSAttributedString`;
     - URL tables via `toNSURLFromLua`;
     - existing primitive/table behavior via `lua_tovalue`.
   - Add push helpers for sharing items, item arrays, URL arrays, and optional
     images using `NSImage_tolua`, `NSAttributedString_toLua`, and `pushNSURL`.
     The image item case must check `NSImage_tolua`'s return value before
     `lua_rawseti`.
   - Push sharing service userdata through `pushHSSharingService` in
     constructors and delegate callbacks.
   - Pull method/metamethod receivers through `toHSSharingServiceFromLua`.
   - Convert `shareTypesFor`, `shareItems`, and `canShareItems` item tables
     through `sharingItemsFromLua`.
   - Return sharing URLs, attachment URLs, and permanent links as sharing URL
     tables.
   - Return sharing images as `hs.image` userdata or nil.

2. Extend `ObjectConversionRegressionTests`:
   - Add a Lua-level test for `hs.sharing.URL()` returning URL tables and
     `shareTypesFor()` accepting URL/image/styledtext items without conversion
     errors.
   - Add a Lua-level test that creates an available sharing service and verifies
     fluent methods return `hs.sharing` userdata.
   - Add a nil-image result test via `:alternateImage()` on an available service,
     because current host services expose nil alternate images.
   - Add a direct Swift-side helper test that pushes a mixed sharing item array
     and verifies URL tables, image userdata, and styledtext userdata.

3. Update `TODO.org`:
   - Mark the sharing subitem done only after focused tests and build pass.

## Verification

Run:

```sh
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests'
zsh -ic 'mise exec -- just build'
```

Do not use full `just verify` as the deciding signal for this slice; the full
suite baseline is already recorded as failing in unrelated suites.
