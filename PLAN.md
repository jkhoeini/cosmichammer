# Plan: image/color/styledtext/pasteboard conversion fixes

## Scope

Integrate the remaining useful parts of stale change `pklzrzypmpkw` after the
app/window/uielement slice was already committed. This item covers only:

- `Sources/HSSwiftExtensions/Dialog.swift`
- `Sources/HSSwiftExtensions/DrawingColor.swift`
- `Sources/HSSwiftExtensions/Image.swift`
- `Sources/HSSwiftExtensions/Menubar.swift`
- `Sources/HSSwiftExtensions/Pasteboard.swift`
- `Sources/HSSwiftExtensions/Styledtext.swift`
- `Tests/CosmicHammerTests/ObjectConversionRegressionTests.swift`
- `TODO.org`

Do not reapply the already-integrated app/window/uielement hunks from
`pklzrzypmpkw`.

## Implementation

1. Expose the richer local conversion helpers that other modules need:
   - `NSColor_tolua` and `table_toNSColor` from `DrawingColor.swift`.
   - `NSImage_tolua` from `Image.swift`, while preserving the current
     `lua_pushretainedUserdata` implementation and not reverting to the stale
     raw-pointer version.
   - `lua_toNSAttributedString` and `NSAttributedString_toLua` from
     `Styledtext.swift`.
   - Concretely, widen these helpers from `private` to internal package/module
     visibility. Leave helpers private when they are only used within their file.

2. Replace generic `lua_pushany` / `lua_tovalue` paths for these types:
   - `Dialog.swift`: color panel callbacks and color setter/getter use explicit
     NSColor helpers.
   - `DrawingColor.swift`: color/list pushers, color-table parsing, and pattern
     image extraction use explicit helpers.
   - `Image.swift`: constructors and image methods push `hs.image` userdata
     explicitly; image methods extract with the current typed userdata helper.
   - `Menubar.swift`: icon and attributed-title paths use explicit image and
     styledtext helpers. Check current `Menubar.swift` against the stale hunk
     before editing; do not blindly apply stale status-item code if current code
     has drifted.
   - `Pasteboard.swift`: read/write paths convert images, colors, styledtext,
     arrays, and dictionaries explicitly without relying on generic userdata
     conversion.
   - `Styledtext.swift`: constructors, attribute tables, substring/copy/case
     methods, fonts, shadows, paragraph styles, and concat paths use explicit
     typed conversion helpers.

3. Add focused regression tests in `ObjectConversionRegressionTests.swift` for:
   - `hs.image` constructors returning userdata.
   - color tables converting through `hs.drawing.color`.
   - styledtext attribute tables round-tripping as Lua tables.
   - pasteboard image/styledtext read/write round-tripping as userdata.

4. Update `TODO.org` when the item is complete: mark this item `DONE`, keep the
   split follow-up items intact, and add verification plus Claude review notes.

## Risks And Checks

- Preserve current userdata lifecycle code in `Image.swift` and `Styledtext.swift`;
  do not regress to stale raw-pointer storage.
- Check every helper call that can return `0`; callers returning one Lua value
  need an explicit nil fallback.
- Keep color conversion using `table_toNSColor`, not the simpler shared
  `tableToNSColor`, where named, hex, white, HSB, or pattern colors matter.
- Watch stack balance in `Pasteboard.swift`, especially URL-table probing and
  recursive array/dictionary pushing.
- Dialog color-panel callbacks require UI event-loop interaction, so do not add
  a brittle callback test unless there is an existing reliable harness. Cover the
  same explicit color helper path through focused color conversion tests and
  compile coverage.
- Re-run Claude review in chunks after implementation because a full diff can
  time out.

## Verification

Run:

```sh
zsh -ic 'mise exec -- just test-resources'
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter ObjectConversionRegressionTests
```

Also re-run the prior conversion guards:

```sh
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter "CanvasValueConversionTests|LocationConversionTests|SpotlightConversionTests"
```

Also run `zsh -ic 'mise exec -- just build'` or a full filtered `swift test`
compile after code edits to catch cross-module visibility errors. `just verify`
is the final broad gate for the stale-head cleanup, but if it still hits known
baseline UI/hardware failures, record the exact failures in `TODO.org` instead
of treating them as this item.
