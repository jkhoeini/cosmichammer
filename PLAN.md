# Plan: generic typed-userdata helper prerequisites

## Scope

Integrate the useful prerequisite subset from stale change `zstzuukktylm` without
reverting to its old raw helper shape.

This slice covers:

- `Sources/HSSwiftExtensions/ChooserLegacy.swift`
- `Sources/HSSwiftExtensions/Dialog.swift`
- `Sources/HSSwiftExtensions/WebviewToolbar.swift`
- `Tests/CosmicHammerTests/TypedUserdataConversionTests.swift`
- `TODO.org`

Do not blindly apply the stale `LuaHelpers.swift` hunk. Current head already has
`LuaUserdataConvertible` plus `lua_pushretainedUserdata`, which is the preferred
shared userdata seam.

## Audit Summary

Stale change `zstzuukktylm` changes four files and adds one test file:

- `ChooserLegacy.swift`: still useful as a visibility/API dependency for
  toolbar window-context pushes.
- `Dialog.swift`: still useful because `webviewAlert` currently force-casts
  `lua_tovalue(... as! NSWindow)`, but webview userdata is not converted by
  `lua_tovalue`.
- `LuaHelpers.swift`: concept is useful, implementation shape is obsolete.
  Prefer current retained-userdata APIs and specific module helpers instead of
  adding old direct branches for every object type.
- `WebviewToolbar.swift`: still useful because toolbar callbacks and methods use
  generic `lua_pushany` and `lua_tovalue(... as! HSToolbar)` on toolbar userdata.
- `TypedUserdataConversionTests.swift`: useful, but should be adjusted to current
  helper names and retained-userdata behavior.

## Implementation

1. Fix the broken toolbar userdata reads first:
   - Replace every `lua_tovalue(L, at: 1) as! HSToolbar` and toolbar
     metamethod equivalent with `getToolbar`.
   - Keep argument validation in place with `luaL_checkudata` where methods
     already have it.
   - Use `toolbar_pushHSToolbar` for places returning toolbar objects, including
     copied toolbars and detached old toolbars.

2. Expose narrowly scoped helpers:
   - Widen `pushHSChooser` enough for toolbar code to push chooser window
     context as `hs.chooser` userdata.
   - Add `dialog_webviewWindowFromLua(L:at:)` using `luaL_testudata` and
     `wv_getWindowFromUD` so `hs.dialog.webviewAlert` can extract webview
     userdata safely.
   - Widen toolbar helpers as needed: `getToolbar`, `toolbar_pushHSToolbar`, and
     `toolbar_pushWindowContext`.

3. Replace unsafe toolbar callback/window-context pushes:
   - Toolbar callbacks should push `capturedSelf` with `toolbar_pushHSToolbar`.
   - Toolbar window context should return `"console"`, `hs.webview` userdata,
     `hs.chooser` userdata, or a fallback value in a single helper.
   - The fallback value is only for unknown window/controller types; known
     webview and chooser contexts must not go through generic `lua_pushany`.

4. Keep `LuaHelpers.swift` mostly unchanged for this slice:
   - Do not add stale direct branches for `HSWebViewWindow`, `HSCanvasView`,
     `HSToolbar`, and `HSChooser` until each type has a current, tested retained
     userdata strategy.
   - If `HSToolbar` can conform cleanly to `LuaUserdataConvertible` without
     changing self-ref semantics, do that; otherwise use explicit toolbar
     helpers only.

5. Add focused tests:
   - `dialog_webviewWindowFromLua` extracts the same `HSWebViewWindow` pushed by
     `wv_HSWebViewWindow_toLua`.
   - `toolbar_pushHSToolbar` produces `hs.webview.toolbar` userdata and
     `lua_toAnyObject` returns the original toolbar.
   - `toolbar_pushWindowContext` preserves `hs.webview` userdata for webview
     windows.
   - Add a Lua-level toolbar method smoke test that constructs a toolbar and
     calls simple methods such as `identifier`, `isAttached`, `visible`, and
     `copy` without crashing or returning fallback strings.

6. Update `TODO.org`:
   - Mark `Inspect generic typed-userdata helper dependencies early` done with
     the file-by-file audit.
   - If this implementation lands, also record that the prerequisite subset of
     `Integrate remaining generic typed-userdata helper fixes` has been handled,
     while leaving broader generic-helper cleanup for later stale heads if still
     useful.

## Risks And Checks

- `wv_getWindowFromUD` assumes the userdata tag is correct; keep the
  `luaL_testudata` guard before calling it.
- `pushHSChooser` and `pushHSToolbar` have different lifetime patterns from the
  newer retained-userdata helper; do not mix lifecycles unless tests prove it is
  safe.
- Toolbar callback stack shape is externally visible. Preserve callback argument
  count and order exactly.
- Do not treat every `lua_pushany` in toolbar as a bug; many push plain strings,
  arrays, dictionaries, item definitions, or images.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter TypedUserdataConversion
zsh -ic 'mise exec -- just build'
```

Also run a focused toolbar/webview/dialog filter if existing test suites expose
one. Record any broad-suite baseline failures in `TODO.org` rather than hiding
them.
