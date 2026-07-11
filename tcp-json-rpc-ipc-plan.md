# Local TCP JSON-RPC IPC

## Finding

The current `hs` path is not Unix-like: [`Sources/hs/hs.swift`](Sources/hs/hs.swift) is a bespoke Swift client using `CFMessagePort`, readline/libedit, app auto-launch, colors, history, local callback ports, and a custom message-id protocol. Server behavior lives in [`extensions/ipc/ipc.lua`](extensions/ipc/ipc.lua) with a default `"Cosmic Hammer"` port, CLI registration, print mirroring, install helpers, and legacy compatibility.

The existing [`hs.socket`](extensions/socket/socket.lua) API proves TCP works, but it is not a good core replacement because server reads do not identify the client and server writes broadcast to every connection:

```swift
/// Notes:
///  * Results are passed to the socket's [callback function](#setCallback), which must be set to use this method.
///  * If called on a listening socket with multiple connections, data is read from each of them.
```

```swift
/// Notes:
///  * If called on a listening socket with multiple connections, data is broadcast to all connected sockets.
```

## Recommended Design

Use a tiny native loopback TCP server plus Lua-owned eval semantics.

```mermaid
flowchart LR
  ncClient["nc or socat"] -->|"JSON line"| tcpServer["IPCTCPServer"]
  tcpServer -->|"method params"| luaHandler["hs.ipc.__handleRPC"]
  luaHandler -->|"eval in session env"| luaState["main Lua state"]
  luaHandler -->|"output event"| tcpServer
  tcpServer -->|"JSON line"| ncClient
```

Protocol:

- Transport: TCP bound to loopback only, newline-delimited UTF-8 JSON, one JSON-RPC 2.0 object per line.
- Discovery: write `~/.local/state/cosmichammer/ipc.json` with mode `0600`, containing `host`, `port`, `token`, `protocolVersion`, and `pid`.
- Auth: require a per-boot random token in `params.token` or via an `auth` request; this keeps `nc`/`socat` usable while avoiding unauthenticated local code execution.
- Methods: `serverInfo`, `eval`, `complete`, `close`; no middleware, no sessions API unless needed later.
- Streaming: send JSON-RPC notifications like `$/output` before the final `eval` response, prepl-style.
- Non-goals for v1: cancellation, remote binding, TLS, editor middleware, app auto-launch, colors, history, or a bundled CLI.

Example interaction:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"eval","params":{"token":"...","code":"print(\"hi\"); 2+2"}}' | nc 127.0.0.1 49152
```

Expected response shape:

```json
{"jsonrpc":"2.0","method":"$/output","params":{"id":1,"stream":"stdout","text":"hi\n"}}
{"jsonrpc":"2.0","id":1,"result":{"status":"ok","values":["4"],"text":"4\n"}}
```

## Implementation Plan

1. Add [`Sources/HSSwiftExtensions/IPCTCPServer.swift`](Sources/HSSwiftExtensions/IPCTCPServer.swift) using `Network.framework` directly, not `hs.socket`. It should own listener lifecycle, per-connection buffers, max line size, JSON decoding/encoding, auth state, and serialized dispatch onto the main Lua state.
2. Extend [`Sources/HSSwiftExtensions/IPC.swift`](Sources/HSSwiftExtensions/IPC.swift) to expose Lua functions such as `startServer`, `stopServer`, and `serverInfo`. Keep `hs.libipc.localPort/remotePort` initially only if we want to preserve the generic public `hs.ipc` API; remove the default CLI port path.
3. Replace the CLI-heavy body of [`extensions/ipc/ipc.lua`](extensions/ipc/ipc.lua) with a small `__handleRPC(sessionID, method, params, emit)` function. Preserve current eval behavior that matters: `_consoleInputPreparser`, `load("return " .. code)` fallback, per-session environment, structured errors, and print capture.
4. Remove the bundled CLI artifacts after the TCP endpoint is covered: [`Sources/hs/`](Sources/hs/), [`Sources/CEditline/`](Sources/CEditline/), the `hs` product/target from [`Package.swift`](Package.swift), `hs-cli` from [`justfile`](justfile), the `Frameworks/hs/hs` copy/sign/smoke checks in [`scripts/build/app-bundle.sh`](scripts/build/app-bundle.sh), [`scripts/build/sign-app.sh`](scripts/build/sign-app.sh), and [`scripts/build/smoke-resources.sh`](scripts/build/smoke-resources.sh), plus the manpage copy in [`scripts/build/copy-resources.sh`](scripts/build/copy-resources.sh).
5. Update docs and generated docs inputs: remove `cliInstall`, `cliStatus`, `cliUninstall`, CLI color/history APIs from [`extensions/ipc/ipc.lua`](extensions/ipc/ipc.lua), and replace examples that shell out to `hs -c` in [`extensions/doc/doc_builder.lua`](extensions/doc/doc_builder.lua) and related references.
6. Add focused tests before removal: JSON line parser, auth failure, malformed request, `serverInfo`, `eval` return values, `print` streaming, error response, completion, concurrent clients serialized on the Lua state, and discovery file permissions. Prefer Swift tests for framing/server behavior plus Lua tests for `__handleRPC` eval semantics.

## Migration Order

Build this as a compatibility-overlap change, then delete baggage only after tests pass:

1. Land TCP JSON-RPC endpoint behind `require("hs.ipc")`.
2. Verify `nc`/`socat` examples work locally.
3. Remove `hs` build/package artifacts.
4. Trim old CLI APIs/docs.
5. Run `zsh -ic 'mise exec -- just check-generated'`, `zsh -ic 'mise exec -- just docs-lint'`, and `zsh -ic 'mise exec -- just test'`.

## Task Checklist

- [ ] Define minimal newline-delimited JSON-RPC protocol and response/error shapes.
- [ ] Implement native loopback TCP server with discovery file and token auth.
- [ ] Move current CLI eval behavior into a small Lua RPC handler.
- [ ] Add parser, auth, eval, output, completion, and concurrency tests.
- [ ] Delete bundled `hs` CLI source, build, signing, manpage, and install helpers.
- [ ] Update docs/examples and run generated-doc checks.
