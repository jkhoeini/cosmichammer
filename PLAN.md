# Plan: Chooser userdata and typed-choice conversion fixes

## Scope

Implement the chooser slice from stale head `onltpntqosrs`
(`wip: device network object conversion audit`).

This slice covers:

- `Sources/HSSwiftExtensions/Chooser.swift`
- `Sources/HSSwiftExtensions/ChooserLegacy.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not touch sharing, Razer, serial, StreamDeck, WebView, or generic
`LuaHelpers.swift` in this commit.

## Audit Summary

The stale chooser changes are still useful, but must be adapted before replay:

- Chooser constructors, callbacks, methods, and metamethods still rely on
  generic `lua_pushany` / `lua_tovalue(... as! HSChooser)` in several paths.
  Those are broken for retained Swift userdata after the LuaSkin migration.
- Static and callback choices can contain `hs.image` and `hs.styledtext`
  userdata. Generic table conversion loses those values; chooser needs
  explicit per-choice conversion.
- The stale helper names `lua_pushNSImage` and `lua_pushNSAttributedString` do
  not exist in current head. Use `NSImage_tolua` and
  `NSAttributedString_toLua`.
- The stale table conversion leaked the key on the Lua stack if a choice value
  was unsupported. The current implementation must pop both key and value on
  failure before returning nil.
- `pushHSChooser` is already available to toolbar code in current head. Keep
  `toHSChooserFromLua` private unless a current caller outside
  `ChooserLegacy.swift` actually needs it.

## Implementation

1. In `Chooser.swift`:
   - Push `self` through `pushHSChooser` in global `willOpen` and `didClose`
     callbacks.
   - Push clicked, invalid, completion, and default query choices through
     `pushChooserChoice`.
   - Convert dynamic choices callback results through `lua_toChooserChoices`.

2. In `ChooserLegacy.swift`:
   - Push `chooser.new(...)` results through `pushHSChooser`.
   - Pull chooser method/metamethod receivers through `toHSChooserFromLua`.
   - Convert static choices through `lua_toChooserChoices`.
   - Add chooser-choice helpers that:
     - preserve `hs.image` via `toNSImage` / `NSImage_tolua`;
     - preserve `hs.styledtext` via `toNSAttributedString` /
       `NSAttributedString_toLua`;
     - preserve primitive/table values through the existing generic helpers;
     - keep stack cleanup balanced on failed table conversion.
   - Convert `fgColor` and `subTextColor` setter tables through
     `tableToNSColor`, and getter values through `lua_pushNSColor` with nil
     fallback.
   - Push `selectedRowContents` through `pushChooserChoice`.

3. Extend `ObjectConversionRegressionTests`:
   - Add a Lua-level chooser test that verifies constructors and setter methods
     return `hs.chooser` userdata and route static `choices()` through the new
     conversion path.
   - Add a Lua-level dynamic choices callback test that exercises the
     `lua_toChooserChoices` path without showing the chooser window.
   - Add a direct Swift-side conversion test for choice dictionaries containing
     `NSImage` and `NSAttributedString`, because `selectedRowContents()` depends
     on visible table-view row state.

4. Update `TODO.org`:
   - Mark the chooser subitem done only after focused tests and build pass.

## Verification

Run:

```sh
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests'
zsh -ic 'mise exec -- just build'
```

Do not use full `just verify` as the deciding signal for this slice; the full
suite baseline is already recorded as failing in unrelated suites.
