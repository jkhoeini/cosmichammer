# Plan: Final stale-head cleanup

## Goal

Make current `dev` contain every useful change from the remaining stale jj heads,
then abandon only heads whose changes are fully represented in current linear
history.

## Ordered Audit

Oldest to newest stale heads checked with `jj diff -s --no-pager -r <id>` and
per-file `jj diff --git --no-pager -r <id> -- <file>`:

1. `lqmwtrnyzxkm` Spotlight tuple conversion: covered by current
   `Spotlight.swift` and `SpotlightConversionTests`.
2. `puunumwuvrsq` CoreLocation conversion: covered by current
   `Location.swift` and `LocationConversionTests`.
3. `wkwoqqzwvnmu` Canvas value conversion: covered by current
   `CanvasLuaMethods.swift`, `CanvasView.swift`, and
   `CanvasValueConversionTests`.
4. `pklzrzypmpkw` app/window/uielement/image/color/styledtext/pasteboard:
   production changes are covered, but one Lua application/AXUIElement test
   assertion is still useful.
5. `ztmsoytoyrsn` Wi-Fi/CoreWLAN conversion: covered by current `Wifi.swift`
   and `WifiTests`.
6. `onltpntqosrs` device/network object conversion: covered by current
   Bonjour, camera, chooser, IPC, ping, notify, Razer, serial, sharing, sound,
   and StreamDeck code/tests.
7. `lmplzsxrmkwx` WebView conversion: covered by current `Webview*.swift`,
   `WebviewConversionTests`, and `TypedUserdataConversionTests`.
8. `wtwynzxomtyy` app/window subset: production changes are covered, and it
   reinforces the same missing application/AXUIElement test assertion.
9. `uyrsyrpwzkxz` audiodevice metatable registration: production changes are
   covered, but the stale default-device metatable method regression test is
   still useful.
10. `wqrzzyrnnyyy` socket binary conversion: current byte-safe helpers cover
    binary payload behavior and UDP binary send coverage, but the stale TCP
    binary write smoke test and numeric argument hardening are still useful.
11. `uvokrvxsuqsq` Canvas matrix conversion: covered by current
    `CanvasMatrix.swift` and broader `CanvasMatrixTests`.
12. `zstzuukktylm` generic typed userdata helpers: useful dialog/toolbar/chooser
    pieces are covered. Do not replay broad `LuaHelpers.swift` branches for
    `HSCanvasView`, `HSWebViewWindow`, `HSToolbar`, or `HSChooser`; current code
    uses explicit module-local pushers/dispatchers, and no live generic
    `lua_pushany` call path for those objects was found.
13. `mtvxytwuwnzw` console/speech conversion: covered by current
    console/speech helpers and tests.
14. `zmqntpmzskkp` release `flake.nix`: covered by current `v0.5.3` flake
    commit and Nix build verification.

## Actionable Items

1. Add the missing application/AXUIElement Lua regression assertions to
   `extensions/application/test_application.lua`; `Application.testObjectConversions`
   already runs that Lua function.
2. Add back `testDefaultDeviceMethods` in
   `extensions/audiodevice/test_audiodevice.lua` and expose it in
   `Tests/CosmicHammerTests/AudiodeviceTests.swift`.
3. Add `testTcpWriteAcceptsBinaryString` in `extensions/socket/test_socket.lua`
   and expose it in `Tests/CosmicHammerTests/SocketTests.swift`.
4. Harden socket numeric arguments:
   - TCP `connect(host, port)` and `listen(port)`.
   - TCP `read(byteCount)`.
   - UDP `connect(host, port)` and `listen(port)`.
   - Keep existing checked UDP `send(message, host, port)` behavior.
   - Reject out-of-range ports instead of clamping; silently connecting to a
     different endpoint is worse than an argument error.
   - Reject negative TCP read lengths.

## Non-Actions

- Do not reintroduce stale local socket byte helpers; current `LuaHelpers.swift`
  already provides `lua_checkdata`, `lua_todata`, `lua_pushdata`, and
  `lua_tostringValue`.
- Do not reintroduce broad `lua_pushany` branches for canvas/webview/toolbar/
  chooser unless review finds a concrete live call path. Explicit module-local
  conversion is safer and already tested.
- Claude challenged this on possible old LuaSkin `pushNSObject:` container
  conversion. Current source no longer has `pushNSObject:`; the remaining
  `lua_pushany` collection call sites were checked for these module object
  types and no live generic path was found.

## Verification

Run focused gates after implementation:

```sh
zsh -ic 'mise exec -- just test-resources'
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter "Application.testObjectConversions|Audiodevice.testDefaultDeviceMethods|Socket.testTcpWriteAcceptsBinaryString|Socket.testUdpSendAcceptsBinaryString|Socket.testTcpParseAddress|Socket.testSocketRejectsInvalidNumericArguments"'
zsh -ic 'mise exec -- just build'
zsh -ic 'mise exec -- just verify'
```

`just verify` is expected to expose the known broad runtime-suite baseline if it
still fails; record whether any failure is related to these changes. Then run
Claude implementation review on the final diff. If no actionable issues remain,
mark the final TODOs done, commit, move `dev`, abandon the stale heads, and
verify `jj log --no-pager -r "heads(all()) ~ ::@"` is empty.

## Final Cleanup Result

After the 14 ordered stale heads were abandoned, one additional non-current
tagged head and two empty heads remained:

- `syrvnpps` / `ac54e34a` / tag `v0.5.3`:
  `fix: modernize Lua object conversions`.
- `kopvpput` / `1ed9a2ec`: empty.
- `vmynkvun` / `c669ac74`: empty.

`syrvnpps` was audited with `jj diff -s --no-pager -r syrvnpps` and targeted
per-file diffs for `LuaHelpers`, object conversion tests, AppKit object
bridges, socket, canvas, application, uielement, and window behavior. Current
`dev` already contains the useful behavior and tests under newer focused
implementations. The stale broad generic typed-userdata branches remain rejected
because current code uses explicit module-local pushers and no live generic
path was found. The stale socket clamping behavior remains rejected in favor of
the current checked-argument errors.

Claude re-reviewed this remaining-head/tag plan and reported no actionable
issues after asking to verify that the `v0.5.3` tag was local-only. After
`jj git fetch --remote origin`, `jj tag list --all-remotes v0.5.3` still showed
only local / `@git` state and no `@origin` target. The local `v0.5.3` tag was
moved to `dev`, then `syrvnpps`, `kopvpput`, and `vmynkvun` were abandoned.

Final repository-shape verification:

```sh
zsh -ic 'jj log --no-pager -r "heads(all()) ~ ::@"'
zsh -ic 'jj tag list --all-remotes v0.5.3'
zsh -ic 'jj status --no-pager'
```

The remaining-head query prints no heads, `v0.5.3` points at current `dev`, and
the working copy was clean before recording this final TODO/PLAN update.

## Claude Review Focus

Ask Claude to be adversarial on:

- Whether the rejected generic `lua_pushany` branches hide any real missing call
  path.
- Whether socket numeric hardening should reject out-of-range ports instead of
  clamping.
- Whether the restored tests are valuable or duplicate existing coverage.
