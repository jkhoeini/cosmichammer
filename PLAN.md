# Plan: Wi-Fi CoreWLAN conversion fixes

## Scope

Integrate the useful parts of stale change `ztmsoytoyrsn` (`wip: wifi
conversion`) without applying it blindly.

This slice covers:

- `Sources/HSSwiftExtensions/Wifi.swift`
- `Tests/CosmicHammerTests/WifiTests.swift`
- `TODO.org`

Do not touch `WifiWatcher.swift` unless review finds raw CoreWLAN objects
escaping there; the current watcher paths push strings/event names.

## Audit Summary

Current head still routes several CoreWLAN objects through generic `lua_pushany`,
which turns unknown objects into debug strings. The stale head is still useful
because it introduces Wi-Fi-local conversion for `CWInterface`, `CWNetwork`,
`CWChannel`, `CWConfiguration`, `CWNetworkProfile`, and CoreWLAN collections.

The stale head needs tightening before landing:

- `wifi.interfaces()` should preserve `CWWiFiClient.interfaceNames()` ordering
  instead of wrapping names in an `NSSet`.
- Ordered arrays should use stable numeric indexes rather than `luaL_len + 1`.
- `NSNull` should map to Lua `nil`.
- Background scan callback conversion should be covered, not only
  `interfaceDetails`.
- `CWNetwork` security/PHY mode tables should include newer WPA3/OWE and 11ax/be
  values where current CoreWLAN APIs expose them.

## Implementation

1. Add Wi-Fi-local conversion helpers in `Wifi.swift`:
   - `pushWifiValue(L, value, depth:)` with a recursion cap.
   - Explicit branches for `CWInterface`, `CWNetwork`, `CWChannel`,
     `CWConfiguration`, `CWNetworkProfile`, `Set<CWNetwork>`,
     `Set<CWChannel>`, `Set<CWNetworkProfile>`, `NSSet`, `NSArray`, `[Any]`,
     `NSDictionary`, `[String: Any]`, and `NSNull`.
   - Sequence helpers should push dense arrays using an explicit `lua_Integer`
     counter, not `luaL_len + 1`.
   - Dictionary helpers should push keys through generic `lua_pushany` and values
     through `pushWifiValue`.

2. Replace only Wi-Fi CoreWLAN/object collection call sites:
   - Background scan callback: `Set<CWNetwork>` and `NSSet` results go through
     `pushWifiValue`; errors still push strings.
   - `wifi_interfaces`: remove the existing `NSSet(array: names)` wrapper and
     push the `names` collection directly so the helper preserves API order.
   - `interfaceDetails`: push `CWInterface` through `pushCWInterface`.
   - Nested interface fields: `wlanChannel`, `supportedChannels`,
     `configuration`, `cachedScanResults`.
   - Configuration `networkProfiles`.
   - Network `wlanChannel`.
   - `pushCWNetwork` inline array builders for `security`, `PHYModes`, and
     `informationElementData` should use explicit counters rather than
     `luaL_len + 1`.
   - Update `pushCWNetwork` security and PHY mode arrays to include newer
     WPA3/OWE and 11ax/11be cases where available, matching the coverage already
     present in `pushCWInterface` and `pushCWNetworkProfile`.

3. Keep scalar/Foundation leaves unchanged:
   - Strings, numbers, booleans, `NSData`, and simple arrays/dictionaries may use
     existing generic helpers when they are not CoreWLAN objects.
   - Do not broaden `LuaHelpers.swift` for CoreWLAN types in this slice.

4. Add tests in `WifiTests.swift`:
   - `wifi.interfaces()` returns nil or a Lua table.
   - `wifi.interfaceDetails()` returns nil or a table whose CoreWLAN nested
     fields are tables, not strings/userdata.
   - Add a direct Swift unit test for the background-scan callback conversion
     helper path if it can be made deterministic without real asynchronous
     scanning. Otherwise defer the asynchronous `wifi.backgroundScan()` Lua
     callback test and record that it is hardware/timing dependent.
   - Mark tests with `.skipInHeadless` because they depend on Wi-Fi hardware and
     macOS CoreWLAN behavior.

5. Update `TODO.org`:
   - Mark `Integrate remaining Wi-Fi CoreWLAN conversion fixes` done.
   - Record the file-by-file stale-head audit, Claude plan/code review notes,
     verification commands, and any hardware-gated skips/failures.

## Risks And Checks

- CoreWLAN collections are unordered sets in some APIs; tests should validate
  shape, not ordering, except `interfaceNames()` where the API returns names.
- Some machines have no Wi-Fi interface. Tests must accept `nil` from
  `interfaceDetails` and `interfaces`.
- Background scans can fail or be unavailable; callback tests should accept an
  error string but must verify successful network entries are tables. Do not add
  a synchronous Lua `backgroundScan` test unless it explicitly spins the run loop
  and has a reliable timeout.
- Keep the helper local to Wi-Fi. A generic CoreWLAN branch in `LuaHelpers.swift`
  would widen behavior outside this module.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter WifiTests
zsh -ic 'mise exec -- just build'
```

If `WifiTests` skip in the local environment, record the skip and rely on build
plus Claude review for the hardware-gated portion. Do not run full `just verify`
as the deciding signal for this item because the current full-suite baseline is
already recorded as failing in unrelated UI/hardware/socket/task suites.
