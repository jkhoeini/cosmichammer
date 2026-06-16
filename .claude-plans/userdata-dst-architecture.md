# Userdata-DST Architecture Refactoring Plan

## Executive Summary

Six extension modules store real OS objects as Lua userdata, bypassing the DST protocol layer. This plan covers the architectural approach for each, prioritized by risk and value.

## Extension-by-Extension Recommendations

### 1. Audiodevice — Approach A (Handle-Based), Phase 1, LOW risk
- Userdata already stores `AudioDeviceID` (UInt32) — just needs routing through protocol
- `AudioProtocol` already covers most operations; `ProductionAudio` exists
- **Scope:** ~720 lines, 2-3 days
- **Migration:** Replace ~25 direct `AudioObjectGetPropertyData` calls with `environmentGet(L).audio.method()`
- **Expand:** AudioProtocol needs ~12 new methods (UID, manufacturer, transport type, sample rate ranges, balance/pan)
- **Risk:** `audiodevice_callback` receives raw AudioDeviceID from CoreAudio; data source sub-userdata needs protocol expansion

### 2. Screen — Approach A (Handle-Based), Phase 2, MODERATE risk
- Replace `NSScreen` userdata with `UInt32` screen ID
- `ScreenProtocol` already covers most semantics; `ScreenInfo` has all needed fields
- **Scope:** ~440 lines, 3-4 days
- **Migration:** Change `new_screen(L, NSScreen)` to `new_screen(L, UInt32)`, rewrite ~18 instance methods
- **Expand:** ScreenProtocol needs 6 new methods (UUID, display info, mirror, setPrimary, setOrigin, desktopImageURL)
- **Risk:** `screen_desktopImageURL` needs real NSScreen; module-level gamma state needs coordination

### 3. Window — Approach A (Handle-Based), Phase 3, MODERATE risk
- Replace `HSwindow` userdata with `UInt32` window ID
- `ProductionWindow` already has full handle-based implementation
- **Scope:** ~400 lines, 3-4 days
- **Migration:** Rewrite ~20 instance methods to call `environmentGet(L).window.method(forWindowID:)`
- **Dependency:** Must coordinate with Phase 4 (accessibility) since HSwindow is shared
- **Risk:** Cross-extension coupling — `application:allWindows()` returns HSwindow objects

### 4. Accessibility/UIElement — Approach D (Phased Adapter), Phase 4, HIGH risk
- Most deeply coupled: HSuielement/HSwindow/HSapplication store AXUIElement refs
- 72+ direct AXUIElement API calls in HSuicore.swift
- **Scope:** ~500 lines, 5-7 days
- **Migration:** 3 sub-phases: add optional protocol handle → dual-path methods → test-only protocol path
- **Risk:** HSuicoreProtocols.swift used by ObjC runtime; watcher callbacks create objects from raw AX refs; NSRunningApplication not covered by any protocol

### 5. Eventtap — Approach E+A Hybrid (Selective + Handle), Phase 5, HIGH risk
- CGEvent is mutable reference type with ~60 properties; full simulation impractical
- **Scope:** ~580 lines, 5-7 days
- **Migration:** Migrate tap management + event creation + posting through protocol. Leave CGEvent property access via handle indirection.
- **Expand:** InputProtocol needs ~15 new handle-based methods
- **Risk:** NSEvent bridge (`NSEvent(cgEvent:)`) cannot be simulated; eventtapCallback receives raw CGEvent from OS

### 6. WebView — Approach E (Selective), Phase 6, LOW risk
- 4,875 lines across 6 files; deep stateful UI component
- **Scope:** ~200 lines, 2-3 days
- **Migration:** Only migrate ~10 core operations (create, navigate, eval JS, show/hide)
- **Leave unsimulated:** Toolbar (1,629 lines), user content, data store, navigation delegate callbacks, certificate inspection

## Execution Order

| Phase | Extension | Approach | Risk | Lines | Duration |
|-------|-----------|----------|------|-------|----------|
| 1 | Audiodevice | A (Handle) | Low | ~720 | 2-3 days |
| 2 | Screen | A (Handle) | Moderate | ~440 | 3-4 days |
| 3 | Window | A (Handle) | Moderate | ~400 | 3-4 days |
| 4 | Accessibility | D (Adapter) | High | ~500 | 5-7 days |
| 5 | Eventtap | E+A (Hybrid) | High | ~580 | 5-7 days |
| 6 | WebView | E (Selective) | Low | ~200 | 2-3 days |
| **Total** | | | | **~2,840** | **20-28 days** |

## What Cannot Be Simulated

1. **NSEvent bridge** — `NSEvent(cgEvent:)` for character extraction, touch data
2. **IOKit display info** — hardware-specific display metadata
3. **WebView state machine** — WKWebView navigation lifecycle, JS semantics, cookies
4. **WebView Toolbar** — 1,629 lines of pure NSToolbar UI
5. **CGEvent gesture synthesis** — already unimplemented
6. **Screen mirroring** — display topology side effects
7. **CoreAudio hardware** — actual audio routing/DSP/codecs
8. **AX observer timing** — async notification delivery depends on app behavior
9. **Private API behaviors** — SkyLight, CoreDisplay, CGS depend on GPU state
10. **NSRunningApplication** — process lifecycle requires real process state

## Key Safeguards

- Production protocol implementations must be behavioral clones of direct OS calls
- Run full test suite after each phase — 687 tests must not regress
- Side-table state (`deviceCallbacks`, `originalGammas`) must move to protocol layer
- No new protocol methods should have default implementations — force explicit impl in both Production and Simulated
