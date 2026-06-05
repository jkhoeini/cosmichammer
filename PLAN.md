# Plan: Notify and sound object conversion fixes

## Scope

Implement the notify/sound slice from stale head `onltpntqosrs` (`wip: device
network object conversion audit`).

This slice covers:

- `Sources/HSSwiftExtensions/Notify.swift`
- `Sources/HSSwiftExtensions/NotifyMethods.swift`
- `Sources/HSSwiftExtensions/Sound.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not touch camera, chooser, sharing, Razer, serial, streamdeck, WebView, or
generic `LuaHelpers.swift` in this commit.

## Audit Summary

The stale notify/sound changes are still useful, but should be landed as a
bounded typed conversion slice:

- `Notify.swift` still pushes `NSUserNotification` through generic
  `lua_pushany` in constructors, delivered/scheduled notification arrays, and
  activation callbacks. It also reads notification userdata through generic
  `lua_tovalue` in metamethods.
- `NotifyMethods.swift` still reads `NSUserNotification` userdata through
  generic `lua_tovalue` in nearly every method. The existing `nt_getNotification`
  helper is the right local typed pull seam because it uses `luaL_checkudata`.
- `notification_contentImage` and `notification_setIdImage` still need explicit
  `hs.image` conversion for `NSImage` values instead of generic object casts.
- `nt_userdata_gc` currently decrements `KEY_SELFREFCOUNT` but checks the old
  count when deciding whether to remove `nt_specifics[gus]`; adding array pushes
  increases the chance of leaked bookkeeping unless this is corrected.
- `Sound.swift` still pushes `NSSound`/`HSSoundObject` through generic
  `lua_pushany` in constructors and callbacks, and reads sound userdata through
  generic `lua_tovalue` in methods and metamethods.
- Scalar notify getters/setters may continue using existing primitive/date/table
  conversion where they do not cross a retained native userdata boundary.
- The broader `NSUserNotification` to `UNUserNotificationCenter` rewrite remains
  a separate modernization TODO. This slice only restores the current deprecated
  extension's object conversion behavior.

## Implementation

1. In `Notify.swift`:
   - Use `nt_pushNSUserNotification` in activation callbacks and
     `notification_new`.
   - Add `nt_pushNotificationArray` to push delivered/scheduled notification
     lists as Lua arrays of `hs.notify` userdata.
   - Use `nt_getNotification` in `__tostring` and `__eq`.
   - Fix `nt_userdata_gc` to remove `nt_specifics[gus]` when the decremented
     self-ref count reaches zero or below.
   - Mark `nt_pushNSUserNotification` as `@discardableResult` because many call
     sites only care about the stack effect.

2. In `NotifyMethods.swift`:
   - Replace method-level `lua_tovalue(... as! NSUserNotification)` pulls with
     `nt_getNotification(L, 1)`.
   - Keep existing locked/dispatched behavior and userInfo bookkeeping intact.
   - Push `notification.contentImage` through a notify-local helper that calls
     `NSImage_tolua` and pushes nil for nil or failed image pushes. Do not use
     the stale `lua_pushNSImage` name because it is not present in current head.
   - Set `notification.contentImage` with `toNSImage`, allowing `nil` to clear
     the image by checking `lua_isnil` before calling `toNSImage`.
   - In `notification_setIdImage`, validate argument 2 as `hs.image` userdata
     and use `luaL_argerror` for invalid values.

3. In `Sound.swift`:
   - Use `pushNSSound` for `sound_byname` and `sound_byfile`.
   - Use `pushHSSoundObject` for delegate callbacks.
   - Use `toHSSoundObjectFromLua` for wrapper-level methods and metamethods.
   - Use `toNSSoundFromLua` for methods operating on the underlying `NSSound`.
   - Make `pushNSSound` delegate to `pushHSSoundObject` instead of generic
     `lua_pushany`.
   - Mark sound push helpers as `@discardableResult`.

4. Extend `ObjectConversionRegressionTests`:
   - Add deterministic `hs.notify` Lua tests for constructor userdata, setter
     identity, getter round trip, `tostring`, equality, content image
     setter/getter using `hs.image`, and delivered/scheduled notification list
     return types without sending or scheduling notifications.
   - Add a direct Swift-side Lua-state test for `nt_pushNotificationArray` using
     fabricated `NSUserNotification` objects so the array element conversion path
     is covered without delivering real notifications.
   - Add a direct Swift-side Lua-state test for `nt_pushNSUserNotification` and
     `__gc` self-ref bookkeeping so the refcount cleanup fix is covered.
   - Add deterministic `hs.sound` tests that generate a temporary silent audio
     file, construct sound userdata through `getByFile`, and exercise non-playing
     methods such as `volume`, `loopSound`, `currentTime`, `duration`,
     `isPlaying`, `name`, `device(nil)`, `setCallback(nil/function)`, `tostring`,
     and equality.
   - Do not call `send`, `schedule`, `play`, `pause`, `resume`, or `stop` in
     tests for this slice.

5. Update `TODO.org`:
   - Mark the notify/sound subitem done only after focused tests, build, and
     Claude review converge.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests'
zsh -ic 'mise exec -- just build'
```

Do not use full `just verify` as the deciding signal for this slice; the full
suite baseline is already recorded as failing in unrelated suites.
