# Plan: Razer, Serial, and StreamDeck typed push leftovers

## Scope

Implement the hardware-oriented slice from stale head `onltpntqosrs`
(`wip: device network object conversion audit`).

This slice covers:

- `Sources/HSSwiftExtensions/Razer.swift`
- `Sources/HSSwiftExtensions/Serial.swift`
- `Sources/HSSwiftExtensions/StreamDeck.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not touch WebView, audiodevice, socket, Canvas matrix, console, speech, or
generic `LuaHelpers.swift` in this commit.

## Audit Summary

Boyle audited the stale hunks against current head. Useful changes are narrow:

- Razer, Serial, and StreamDeck callbacks/constructors/device lookups still push
  device objects through generic `lua_pushany`, which no longer preserves typed
  userdata.
- Current head already uses `lua_checkUserdataObject` /
  `lua_testUserdataObject` for method and metamethod receivers. Those are better
  than the stale `toHS...FromLua(...) as!` replacements, so do not replay those
  hunks.
- Current Razer/StreamDeck color paths already use `tableToNSColor`.
- Current Serial `sendData` already uses `lua_checkdata(L, at: 2)`, which is
  better than the stale manual `lua_tolstring` hunk.
- Fake HID devices are not viable for tests: `IOHIDDeviceCreate(..., 0)` returns
  nil. Hardware-dependent callback behavior cannot be made deterministic here.

## Implementation

1. In `Razer.swift`:
   - Push button callback `self`, discovery callback devices, and
     `getDevice(...)` results through `pushHSRazerDevice`.
   - Mark `pushHSRazerDevice` `@discardableResult`.
   - Leave receiver extraction and color hunks unchanged.

2. In `Serial.swift`:
   - Push delegate callback `self` and `newFromName` / `newFromPath` results
     through `pushHSSerialPort`.
   - Mark `pushHSSerialPort` `@discardableResult` and make it internal for
     focused test coverage.
   - Leave method receiver extraction and `sendData` unchanged.

3. In `StreamDeck.swift`:
   - Push button, encoder, screen, discovery, and `getDevice(...)` device values
     through `pushHSStreamDeckDevice`.
   - Mark `pushHSStreamDeckDevice` `@discardableResult`.
   - Leave receiver extraction, image extraction, and color hunks unchanged.

4. Extend `ObjectConversionRegressionTests`:
   - Add a direct no-hardware Serial push-helper test, because
     `hs.serial.newFromPath` rejects pseudo-terminal paths before open on this
     host.
   - Add hardware-tolerant Razer and StreamDeck smoke tests: load module,
     initialize without callbacks, assert `numDevices()` is a number, and if
     `getDevice(1)` exists assert it is userdata.

5. Update `TODO.org`:
   - Mark the Razer/Serial/StreamDeck audit done only after focused tests and
     build pass.

## Verification

Run:

```sh
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests'
zsh -ic 'mise exec -- just build'
```

Do not use full `just verify` as the deciding signal for this slice; the full
suite baseline is already recorded as failing in unrelated suites.
