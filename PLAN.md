# Plan: Bonjour object conversion fixes

## Scope

Implement the Bonjour slice from stale head `onltpntqosrs` (`wip: device
network object conversion audit`).

This slice covers:

- `Sources/HSSwiftExtensions/Bonjour.swift`
- `Sources/HSSwiftExtensions/BonjourService.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not touch notify, sound, sharing, camera, chooser, Razer, serial,
streamdeck, or stale `LuaHelpers.swift` in this commit.

## Audit Summary

The stale Bonjour changes are useful, but should be landed as a narrow typed
userdata conversion slice:

- `Bonjour.swift` still pushes `HSNetServiceBrowser` through generic
  `lua_pushany` in constructors and callbacks, and reads it through generic
  `lua_tovalue` in methods and equality.
- Browser callbacks can pass `NetService` instances in `"service"` callback
  payloads. Those need `pushNSNetService` from `BonjourService.swift`, not
  generic object conversion.
- `BonjourService.swift` still pushes `HSNetServiceWrapper` through generic
  conversion in constructors, callbacks, and `pushNSNetService`, and reads it
  through generic conversion in most methods and metamethods.
- The stale hunk that makes `pushNSNetService` non-private is justified because
  `Bonjour.swift` needs to push callback `NetService` values as
  `hs.bonjour.service` userdata.
- `hs.bonjour` loads `hs.libbonjourservice`, but direct `hs.libbonjour` use can
  invoke browser callbacks before the service module has initialized
  `serviceUDRecords` or the `hs.bonjour.service` metatable. The implementation
  must guard or lazily initialize the service module before pushing a
  `NetService`.
- Stale generic `LuaHelpers.swift` changes remain out of scope; current head has
  explicit typed helpers and retained-userdata plumbing.

## Implementation

1. In `BonjourService.swift`:
   - Add a callback argument pusher that converts `NetService` with
     `pushNSNetService` and leaves scalar/table values on existing conversion.
   - Use `pushHSNetServiceWrapper` for wrapper self pushes and constructors.
   - Use `toHSNetServiceWrapperFromLua` for methods/metamethod object reads.
   - Add missing `luaL_checkudata` guards before typed pulls in
     `service_TXTRecordData` and `service_startMonitoring`.
   - Make `pushNSNetService` internal to the file module and mark typed push
     helpers `@discardableResult`.
   - Add a small initialization helper so `pushNSNetService` safely initializes
     the service registry/metatable if called from `Bonjour.swift` before
     `hs.libbonjourservice` has been explicitly required.
   - Preserve `serviceUDRecords`, `selfRef`, and callback argument ordering.

2. In `Bonjour.swift`:
   - Add a callback argument pusher that converts `NetService` via
     `pushNSNetService`.
   - Use `pushHSNetServiceBrowser` for constructor and callback self pushes.
   - Use `toHSNetServiceBrowserFromLua` for methods and equality.
   - Preserve callback event names, argument order, and browser stop behavior.

3. Extend `ObjectConversionRegressionTests`:
   - Assert `hs.libbonjour.new()` returns userdata and setter methods return the
     same browser userdata.
   - Assert `hs.libbonjourservice.new(...)` and `.remote(...)` return userdata
     and common getter/setter methods operate through typed service userdata.
   - Add a Swift-side Lua-state test for `pushNSNetService(NetService(...))`
     before requiring `hs.libbonjourservice`; it should push service userdata and
     repeated pushes of the same `NetService` should compare equal.
   - Avoid network-dependent browse/resolve/publish timing in this slice; the
     tests should verify constructor/method conversion deterministically.

4. Update `TODO.org`:
   - Add a completed subitem under the broad device/network TODO after
     verification and Claude review.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests'
zsh -ic 'mise exec -- just build'
```

Do not use full `just verify` as the deciding signal for this slice; the full
suite baseline is already recorded as failing in unrelated suites.
