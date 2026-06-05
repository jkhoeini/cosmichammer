# Plan: IPC and network ping object conversion fixes

## Scope

Implement the first small slice from stale head `onltpntqosrs` (`wip: device
network object conversion audit`).

This slice covers:

- `Sources/HSSwiftExtensions/IPC.swift`
- `Sources/HSSwiftExtensions/NetworkPing.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not touch the rest of the broad stale head in this commit.

## Audit Summary

The stale head is useful but too broad to land at once. The first safe slice is
IPC plus network ping:

- `IPC.swift`: constructors, callbacks, methods, tostring, and equality still
  push/read `HSIPCMessagePort` through generic `lua_pushany` / `lua_tovalue`.
- `NetworkPing.swift`: constructors, callbacks, methods, tostring, and equality
  still push/read `PingableObject` through generic conversion.
- `LuaHelpers.swift`: stale additions are obsolete; current head already has
  retained-userdata and typed helper APIs.

## Implementation

1. In `IPC.swift`:
   - Use `pushHSIPCMessagePort` for constructor and callback self pushes.
   - Use `toHSIPCMessagePortFromLua` for method/metamethod object reads.
   - Add `@discardableResult` to the push helper where useful.
   - Preserve current lifecycle/ref-count behavior and callback argument order.

2. In `NetworkPing.swift`:
   - Use `pushPingableObject` for constructor and callback self pushes.
   - Use `toPingableObjectFromLua` for method/metamethod object reads.
   - Add `@discardableResult` to the push helper where useful.
   - Preserve callback event names, argument counts, and stack behavior.

3. Add or extend focused regression tests:
   - `hs.ipc.localPort` and `hs.ipc.remotePort` return userdata with stable
     method access and equality/name behavior.
   - `hs.network.ping.echoRequest` setter methods return the same userdata,
     not fallback strings.

4. Update `TODO.org`:
   - Keep the broad device/network item open until all split slices are done.
   - Add a note that slice 1 landed and record verification/review.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests
zsh -ic 'mise exec -- just build'
```

Do not use full `just verify` as the deciding signal for this slice; the full
suite baseline is already recorded as failing in unrelated suites.
