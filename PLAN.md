# Plan: Audiodevice metatable registration fixes

## Scope

Implement the useful parts of stale head `uyrsyrpwzkxz`
(`wip: audiodevice registration`).

This slice covers:

- `Sources/HSSwiftExtensions/Audiodevice.swift`
- `Tests/CosmicHammerTests/AudiodeviceTests.swift`
- `extensions/audiodevice/test_audiodevice.lua`
- `TODO.org`

Do not touch WebView, socket, Canvas, console, speech, generic Lua helpers, or
unrelated audio behavior in this commit.

## Audit Summary

The stale diff is narrow and still useful:

- `audiodevice_isOutputDevice` and `audiodevice_isInputDevice` already exist,
  and Lua tests already exercise `device:isOutputDevice()` /
  `device:isInputDevice()`, but current `audiodevice_metalib` does not register
  those methods on device userdata.
- Both audiodevice userdata metatables are created without `__type`, while
  other migrated modules expose stable userdata type metadata.
- The stale default-device Lua regression is weak because existing tests already
  cover `isInputDevice`, `isOutputDevice`, and default-device `__type`
  behavior. It also misses datasource `__type`.
- Add one focused datasource metadata test instead. It must be hardware-tolerant
  because datasource support varies by host.

No broader audio API refactor is needed.

## Implementation

1. In `Audiodevice.swift`:
   - Add `isOutputDevice` and `isInputDevice` entries to
     `audiodevice_metalib`, next to the existing device query methods.
   - Set `__type` to `USERDATA_TAG` after assigning `__index` on the
     `hs.audiodevice` metatable.
   - Set `__type` to `USERDATA_DATASOURCE_TAG` after assigning `__index` on the
     `hs.audiodevice.datasource` metatable.

2. In `extensions/audiodevice/test_audiodevice.lua`:
   - Add `testDataSourceTypeMetadata`.
   - Iterate available devices and inspect the first input or output datasource
     table that exists.
   - Assert a found datasource is userdata of type
     `hs.audiodevice.datasource`.
   - Return success when no datasource-capable device is present.

3. In `AudiodeviceTests.swift`:
   - Add a Swift Testing wrapper for `testDataSourceTypeMetadata`.

4. Update `TODO.org` after build, focused audiodevice tests, and review.

## Verification

Run:

```sh
mise exec -- just build
```

Then focused tests:

```sh
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter "Audiodevice.testIsOutputDevice|Audiodevice.testIsInputDevice|Audiodevice.testGetDefaultOutput|Audiodevice.testDataSourceTypeMetadata"
```

If useful, run the full audiodevice test filter after the focused test passes.
