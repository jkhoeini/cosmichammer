# Plan: Camera userdata conversion fixes

## Scope

Implement the camera slice from stale head `onltpntqosrs` (`wip: device
network object conversion audit`).

This slice covers:

- `Sources/HSSwiftExtensions/Camera.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not touch chooser, sharing, Razer, serial, streamdeck, WebView, or generic
`LuaHelpers.swift` in this commit.

## Audit Summary

The stale camera changes are still useful, but incomplete:

- `hs.camera.allCameras()` currently pushes `[HSCamera]` through generic
  `lua_pushany`, which no longer preserves Swift userdata.
- Camera device watcher and property watcher callbacks still push `HSCamera`
  through generic conversion.
- Camera methods and metamethods still pull `HSCamera` userdata through
  `lua_tovalue(... as! HSCamera)`, which is broken now that generic userdata
  conversion returns nil.
- `pushHSCamera` uses `Unmanaged.passRetained`, but `hsCamera_gc` only clears
  the metatable and does not release the retained object. Increasing typed
  pushes without fixing GC would make the leak worse.

## Implementation

1. In `Camera.swift`:
   - Push cameras through `pushHSCamera` in `allCameras`,
     `deviceWatcherDoCallback`, and property watcher callbacks.
   - Pull camera method/metamethod receivers through `toHSCameraFromLua`.
   - Mark `pushHSCamera` `@discardableResult`.
   - Update `hsCamera_gc` to take the retained `HSCamera` value and nil the
     stored pointer, then clear the metatable. Keep it tolerant of nil pointers.
   - Preserve watcher callback argument order and existing canary checks.

2. Extend `ObjectConversionRegressionTests`:
   - Add an availability-tolerant `hs.camera.allCameras()` Lua test: it should
     always return a table; if the table is non-empty, the first element should
     be userdata and basic methods should return the expected Lua types.
   - Add a direct Swift-side Lua-state test for `pushHSCamera`/`hsCamera_gc` only
     if a camera is available through the public module; avoid fabricating invalid
     `CMIODeviceID` values because camera initializers query CoreMediaIO.
   - Do not start device or property watchers in tests; those require hardware
     and run-loop timing.

3. Update `TODO.org`:
   - Mark the camera subitem done only after focused tests and build pass.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests'
zsh -ic 'mise exec -- just build'
```

Do not use full `just verify` as the deciding signal for this slice; the full
suite baseline is already recorded as failing in unrelated suites.
