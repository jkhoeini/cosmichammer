# Plan: Socket binary string conversion fixes

## Scope

Implement the still-useful socket slice from stale head `wqrzzyrnnyyy`
(`wip: socket conversion`), while checking the overlap note from
`zstzuukktylm`.

This slice covers:

- `Sources/HSSwiftExtensions/Socket.swift`
- `Sources/HSSwiftExtensions/SocketUdp.swift`
- `Tests/CosmicHammerTests/SocketTests.swift`
- `extensions/socket/test_udpsocket.lua`
- `TODO.org`

Do not touch WebView, Canvas, console, speech, or generic `LuaHelpers.swift` in
this commit.

## Audit Summary

The stale socket diff is partly useful, but its local helper functions are stale
because current head already has shared, length-aware helpers:

- `lua_pushdata`
- `lua_todata`
- `lua_checkdata`
- `lua_tostringValue`
- registry-ref helpers

Still-useful changes:

- Push TCP/UDP callback tags with `lua_pushinteger` instead of generic
  `lua_pushany`.
- Push TCP read callback payloads with `lua_pushdata` instead of generic
  `NSData` dispatch.
- Push UDP read callback payload and sockaddr bytes with `lua_pushdata`.
  Current UDP payload conversion decodes `Data` as UTF-8 and pushes nil for
  invalid byte sequences.
- Read TCP parse-address bytes and TCP read delimiters with `lua_checkdata`.
  Current delimiter conversion round-trips through Swift `String`, so invalid
  UTF-8 delimiters are corrupted before matching.
- Read unconnected UDP `send` host/port arguments with checked APIs. The
  invalid-byte UDP payload regression exposed a current crash in the stale
  `lua_tovalue(... as! String)` host extraction path.

Not useful to replay:

- Do not add stale local `luaDataAt`, `luaStringAt`, or `luaPushData` helpers in
  socket files. Use the shared helpers already in `LuaHelpers.swift`.
- Do not rewrite socket host/path/peer-name/port extraction in this slice.
  Current `lua_tovalue` string conversion is already length-aware through
  `lua_tostringValue`, and those arguments are not binary socket payloads.
  The exception is unconnected UDP `send`, where the binary payload regression
  exposed a real crash.
- Do not treat `zstzuukktylm` as a socket dependency. Its changed files are
  chooser, dialog, generic Lua helpers, WebView toolbar, and typed-userdata
  tests; it does not change socket files.
- Do not add TCP or UDP async receive regressions in this slice. Current socket
  receive tests already have baseline callback-delivery failures in this
  harness; the attempted binary delivery tests were flaky for the same reason.

## Implementation

1. In `Socket.swift`:
   - Change `tcpWriteCallback` tag push to `lua_pushinteger`.
   - Change `tcpReadCallback` data/tag pushes to `lua_pushdata` and
     `lua_pushinteger`.
   - Change `socket_parseAddress` to use `lua_checkdata(L, at: 1)`.
   - Change only the string-delimiter branch of `socket_read` to use
     `lua_checkdata(L, at: 2)`.

2. In `SocketUdp.swift`:
   - Change `udpWriteCallback` tag push to `lua_pushinteger`.
   - Change `udpReadCallback` data/address pushes to `lua_pushdata`.
   - Change unconnected `socketudp_send` host/port extraction to
     `lua_tostringValue` and `luaL_checkinteger`.

3. In Lua socket tests:
   - Add a deterministic UDP `send` regression with NUL and invalid UTF-8
     payload bytes. This catches the current unconnected-send crash without
     depending on async receive delivery.

4. In `SocketTests.swift`:
   - Add a wrapper for the UDP binary send regression using the existing
     synchronous socket Lua test harness.

5. Update `TODO.org` after plan review, implementation review, build, and
   focused socket tests.

## Verification

Run focused tests first:

```sh
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter "Socket.testUdpSendAcceptsBinaryString|Socket.testTcpParseAddress"
```

Then run:

```sh
mise exec -- just build
```
