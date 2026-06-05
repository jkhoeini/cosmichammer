# Plan: Console and speech conversion stale-head integration

## Scope

Resolve the TODO for stale head `mtvxytwuwnzw`:

- `Sources/HSSwiftExtensions/Console.swift`
- `Sources/HSSwiftExtensions/LuaHelpers.swift`
- `Sources/HSSwiftExtensions/Speech.swift`
- `Sources/HSSwiftExtensions/SpeechListener.swift`
- focused tests under `Tests/CosmicHammerTests/`
- `TODO.org`

## Stale-Head Audit

Useful hunks:

- `Console.swift` must stop pulling colors, fonts, and styledtext through
  `lua_tovalue(... as! ...)`. `lua_tovalue` intentionally returns nil for
  userdata and plain dictionaries for Lua tables, so those casts are crash-prone.
- `Speech.swift` and `SpeechListener.swift` must push their constructor and
  callback self values with their local typed push helpers instead of generic
  `lua_pushany`. Generic fallback stringifies these private AppKit subclasses.
- The speech constructor regression test is useful because it catches both
  synthesizer and listener userdata shape regressions without requiring live
  audio or dictation callbacks.

Stale or risky hunks not to replay directly:

- Do not copy the stale broad `lua_pushany` branches for `NSColor`,
  `NSAttributedString`, and generic AppKit values. Current head already has a
  narrower `NSColor` push helper and retained-userdata support for
  `NSAttributedString`.
- Do not replace the current color parser with the stale `tableToNSColor`
  expansion. `DrawingColor.swift` already has `table_toNSColor`, which preserves
  `hs.drawing.color` semantics for RGB, HSB, white, named lists, custom color
  collections, and pattern-image colors.
- Do not add live speech callback tests. They would depend on timing, system
  speech services, audio output, and dictation availability.

## Implementation

1. Add a narrow `lua_pushNSFont` helper in `LuaHelpers.swift`, and route
   `NSFont` through it in `lua_pushany`.
2. In `Console.swift`, add local wrappers:
   - `consoleColorFromLua`: requires a Lua table and calls `table_toNSColor`.
   - `consolePushColor`: returns colors via `NSColor_tolua`.
   - `consolePushFont`: returns fonts via `lua_pushNSFont`.
   - `consoleAttributedStringFromLua`: accepts only `hs.styledtext` userdata
     and pulls through `toNSAttributedString`.
3. Replace console color setters and getters with the explicit wrappers.
4. Replace `consoleFont` get/set with `tableToNSFont` and `lua_pushNSFont`.
5. Replace console styledtext force-casts in `setConsole` and
   `printStyledtext` with the explicit styledtext pull helper.
6. Keep `setHistory` conversion as an array conversion only. The stale
   `NSMutableArray(array: (lua_tovalue as? [Any]) ?? [])` avoids a crash but
   silently accepts malformed tables as empty history. Use a checked conversion
   and `luaL_argerror` on non-array tables.
7. Replace speech synthesizer and speech listener constructor/callback
   `lua_pushany` self pushes with typed helpers. For speech listener callbacks,
   `pushHSSpeechRecognizer` is safe because it reuses `selfRef`. For speech
   synthesizer callbacks, use a dedicated helper that pushes `selfRef` when it
   exists and only falls back to `pushHSSpeechSynthesizer` if no self-reference
   is available. Also fix `speak` / `speakToFile` return stack balance so
   creating the self-reference cannot pop the only returned synthesizer value.
8. Add focused tests:
   - `lua_pushNSFont` produces `{ name, size, __luaSkinType = "NSFont" }`.
   - speech constructors return userdata and expose expected methods.
   Avoid direct console controller tests because the controller singleton is an
   AppKit runtime object, not a deterministic test fixture here.

## Self-Critique

- Risk: `NSColor_tolua` can return a string for unconvertible color spaces.
  That matches existing `hs.drawing.color` behavior and is better than adding a
  second color table format.
- Risk: `table_toNSColor` returns black for malformed color tables instead of
  nil. This is existing color-module behavior; `consoleColorFromLua` should
  still validate that the argument is a table so non-tables do not silently pass.
- Risk: speech typed pushes increment retain/reference counters in callbacks.
  Claude correctly flagged that blindly replaying the stale synthesizer callback
  pushes could retain a fresh userdata for every callback. The implementation
  should reuse `selfRef` for callback self arguments because speaking methods
  create that registry reference before callbacks fire.
- Risk: adding `NSFont` to generic `lua_pushany` is broader than console only.
  It is acceptable because font tables are already an established LuaSkin shape
  used by styledtext/canvas, and no metatable/module load order is involved.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
zsh -ic 'SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter "LuaHelpersTests.testPushNSFontAsTable|ModuleLoadRegression.testSpeechConstructorsReturnUserdata"'
zsh -ic 'mise exec -- just build'
```

## Plan Review Notes

Claude reviewed this plan. Valid feedback incorporated:

- The original plan left the synthesizer callback retain strategy too vague.
  The revised plan commits to reusing `selfRef` in callbacks and fixing the
  `speak` / `speakToFile` return stack when creating that reference.
- Console styledtext conversion must explicitly check the `hs.styledtext`
  metatable before pulling userdata.
- Console history conversion should not silently treat malformed tables as an
  empty history.

Feedback I believe is already addressed:

- `table_toNSColor` is a visible free function in the same SPM target, so
  `Console.swift` can call it directly.
- `printStyledtext` keeps the existing split: `hs.styledtext` userdata uses the
  typed pull helper; other values go through `luaL_tolstring`.
