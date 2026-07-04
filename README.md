# Cosmic Hammer

<p align="center">
  <img src="CosmicHammer.svg" alt="Cosmic Hammer" width="200" height="200"/>
</p>

<p align="center">
  <strong>Powerful macOS automation, forged in the cosmos.</strong>
</p>

Discord: [Click to join](https://discord.gg/vxchqkRbkR)

## What is Cosmic Hammer?

This is a tool for powerful automation of macOS. At its core, Cosmic Hammer is just a bridge between the operating system and a Lua scripting engine.

What gives Cosmic Hammer its power is a set of extensions that expose specific pieces of system functionality, to the user. With these, you can write Lua scripts to control many aspects of your macOS environment.

## How do I install it?

### Manually

 * Download the [latest release](https://github.com/jkhoeini/cosmichammer/releases/latest)
 * Drag `Cosmic Hammer.app` from your `Downloads` folder to `Applications`

### Homebrew

  * `brew install cosmic-hammer --cask`

## What next?

Out of the box, Cosmic Hammer does nothing - you will need to create `~/.cosmic-hammer/init.lua` and fill it with useful code. There are several resources which can help you:
 * [Getting Started Guide](https://github.com/jkhoeini/cosmichammer/go/)
 * [API docs](https://github.com/jkhoeini/cosmichammer/docs/)
 * [FAQ](https://github.com/jkhoeini/cosmichammer/faq/)
 * [Sample Configurations](https://github.com/jkhoeini/cosmichammer/wiki/Sample-Configurations) supplied by various users
 * [OpenTelemetry Guide](docs/opentelemetry.md) for tracing, logs, metrics, and local diagnostics
 * [Contribution Guide](https://github.com/jkhoeini/cosmichammer/blob/master/CONTRIBUTING.md) for developers looking to get involved
 * An IRC channel for general chat/support/development (#cosmic-hammer on Libera)

## What is the history of the project?

Cosmic Hammer is a fork of [Hammerspoon](https://github.com/jkhoeini/cosmichammer), which is itself a fork of [Mjolnir](https://github.com/mjolnirapp/mjolnir). Mjolnir aims to be a very minimal application, with its extensions hosted externally and managed using a Lua package manager. We wanted to provide a more integrated experience.

## How is Cosmic Hammer different from Hammerspoon?

Cosmic Hammer keeps the Hammerspoon Lua API you already know, but the implementation underneath has been rebuilt from the ground up for a modern macOS toolchain. The headline differences:

- **Fully Swift** — All ~170 Objective-C extension files and the core runtime (`LuaRuntime`, `HSuicore`, `HSAppleScript`) were rewritten in Swift, with hardened ObjC↔Swift interop (safe casts, no dangling `NSString` pointers, fixed pointer/crash bugs).
- **Modern Lua bridge** — The Objective-C LuaSkin layer (~9,500 lines) is gone. Lua 5.4 comes from the [LuaSwift](https://github.com/tomsci/LuaSwift) package, and all ~90 extensions use idiomatic LuaSwift (`Metatable<T>` registration) with an ObjC exception safety net and reworked garbage-collection handling.
- **No vendored C libraries, no CocoaPods** — Every bundled dependency was replaced with an Apple framework or pure Swift: `hs.websocket` uses `NSURLSessionWebSocketTask`; `hs.httpserver`, `hs.socket`, and `hs.socket.udp` use `Network.framework`; `hs.sqlite3` and `hs.doc` markdown are pure Swift (`swift-markdown`); logging uses `os_log`. SocketRocket, CocoaHTTPServer, CocoaAsyncSocket, lsqlite3, Sundown, CocoaLumberjack, MIKMIDI, ASCIImage, Sparkle, and Sentry are all gone.
- **Modernized build** — No Xcode project. The app builds with `swift build` + a `justfile`, from a standard single-package SPM layout. All extensions are **statically linked into one binary** (no per-extension dylibs) via a generated `package.preload` table driven by `extensions.manifest`. XIBs were replaced with programmatic UI, distribution ships via a Nix flake, and the deployment floor is macOS 26 / Xcode 17.
- **Deterministic Simulation Testing (DST)** — Inspired by TigerBeetle, 32 protocols abstract every OS interaction, backed by seeded deterministic simulators (with fault injection and a simulated clock) alongside the real production implementations. This cut the test suite from ~62s to ~3.6s and drives 800+ deterministic tests.
- **TigerStyle engineering** — Assertions, a 70-line function limit, and bounded loops/buffers/queues/recursion applied across the codebase (surfacing and fixing several latent bugs).
- **Swift-native tests** — The suite was migrated from Objective-C XCTest to Swift Testing as an SPM test target.
- **Built-in OpenTelemetry** — A new `hs.opentelemetry` module (not in Hammerspoon) exports traces, logs, and metrics over OTLP HTTP/protobuf and gRPC, with W3C tracecontext/baggage propagation, attribute redaction, sampling, and automatic instrumentation across the runtime. See the [OpenTelemetry Guide](docs/opentelemetry.md).
- **Performance** — Window operations use a cached `WindowElementHandle` for O(1) access instead of repeated accessibility-tree scans, plus `os_signpost` tracing.
- **Behavioral changes** — Config and data paths follow the [XDG Base Directory](https://specifications.freedesktop.org/basedir-spec/latest/) spec; Spoon plugins and App Intents / Siri Shortcuts integration were removed; new `hs.window:cornerRadius()` / `hs.window.cornerRadiusForID()` were added; and Carbon/deprecated APIs were replaced with modern equivalents.

## What is the future of the project?

Our intentions for Cosmic Hammer broadly fall into these categories:
 * Ever wider coverage of system APIs in Extensions
 * Tighter integration between extensions
 * Smoother user experience

