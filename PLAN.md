# Plan: Generic typed-userdata helper audit

## Scope

Resolve the remaining TODO for stale head `zstzuukktylm`
(`wip: typed userdata conversion helpers`).

This slice covers:

- `PLAN.md`
- `TODO.org`

No production code should change unless review finds a concrete missing current
behavior.

## Audit Summary

Most of `zstzuukktylm` has already landed in better-scoped commits:

- `ChooserLegacy.swift`: `pushHSChooser` is already module-visible.
- `Dialog.swift`: `dialog_webviewWindowFromLua` already extracts typed WebView
  userdata for `hs.dialog.webviewAlert`.
- `WebviewToolbar.swift`: toolbar callbacks, window context, method receivers,
  copying, equality, and tostring already use typed toolbar/window/chooser
  helpers.
- `TypedUserdataConversionTests.swift`: current head already has focused tests
  for dialog WebView extraction, toolbar userdata push, WebView/chooser toolbar
  window context, and toolbar Lua method smoke coverage.

The only stale hunk not replayed is the broad `LuaHelpers.swift` branch that
would make generic `lua_pushany` dispatch `HSWebViewWindow`, `HSCanvasView`,
`HSToolbar`, and `HSChooser` through module-specific push helpers.

Do not replay that broad hunk:

- Later WebView, Canvas, Canvas matrix, toolbar, and chooser integrations now
  route user-visible values through local typed pushers/dispatchers at the
  module boundary.
- Broad generic dispatch couples `LuaHelpers.swift` to module metatable
  registration order. Some stale pushers assume their metatable already exists,
  unlike the newer `LuaUserdataConvertible` retained-userdata helper which
  returns false if the metatable is absent.
- There is no remaining socket, WebView, Canvas, toolbar, chooser, or dialog
  call site that needs the generic branch after the landed scoped conversions.

## Implementation

1. Leave production code unchanged.
2. Mark the TODO done with the audit details and verification results.

## Verification

Run:

```sh
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter TypedUserdataConversionTests
```

Also rely on the already-passing adjacent suites from the previous slices:

- `WebviewConversionTests`
- `CanvasValueConversionTests`
- `CanvasMatrixTests`
