# Plan: WebView typed conversion fixes

## Scope

Implement the still-useful WebView slice from stale head `lmplzsxrmkwx`
(`wip: webview conversion`).

This slice covers:

- `Sources/HSSwiftExtensions/Webview.swift`
- `Sources/HSSwiftExtensions/WebviewDatastore.swift`
- `Sources/HSSwiftExtensions/WebviewToolbar.swift`
- `Sources/HSSwiftExtensions/WebviewUsercontent.swift`
- `Sources/HSSwiftExtensions/WebviewView.swift`
- `Sources/HSSwiftExtensions/WebviewWindow.swift`
- `Tests/CosmicHammerTests/WebviewConversionTests.swift`
- `TODO.org`

Do not touch audiodevice, socket, Canvas matrix, console, speech, or generic
`LuaHelpers.swift` in this commit.

## Audit Summary

The stale WebView diff is mostly useful, but must be adapted to current helper
names and already-landed typed userdata support:

- A module-local `wv_pushAny` is useful because WebKit and toolbar objects are
  still passed through generic `lua_pushany` in callbacks, constructors,
  back-forward lists, datastore records, user scripts, window callbacks, and
  policy callbacks.
- URL request/response table conversion is useful. `webview:url(...)` currently
  attempts `lua_tovalue(... as? URLRequest)`, which cannot parse Lua strings or
  request tables reliably after the generic bridge migration.
- Datastore constructors and async record callbacks still need typed datastore
  and record push helpers. `NSSet` data-type values should be exposed as arrays
  rather than opaque generic sets.
- Toolbar callback and item-detail paths should preserve toolbar userdata,
  WebView window userdata, and nested toolbar item tables.
- Usercontent constructors and script/message callbacks should preserve
  usercontent, user script, frame info, and WebView window values.
- Current head already has `toolbar_pushHSToolbar`, `getToolbar`,
  `toolbar_pushWindowContext`, and chooser-aware toolbar helpers. Use these
  current names; do not replay stale `pushHSToolbar` names.
- Current head already fixed some toolbar receiver extraction through
  `getToolbar`; keep those current improvements.
- `HTTP.swift` already contains private URL request/response conversion helpers
  with the behavior WebView needs. Prefer extracting a shared internal helper
  only if it stays low-risk; otherwise keep WebView wrappers behavior-identical
  to the HTTP helpers and avoid unrelated HTTP churn.

## Implementation

1. In `Webview.swift`:
   - Add `wv_pushAny` that dispatches known WebView/WebKit/toolbar values to
     typed module-local pushers and falls back to `lua_pushany`.
   - Explicitly cover these dispatch types: `HSWebViewWindow`, `HSToolbar`,
     `NSToolbarItem`, `WKWebsiteDataStore`, `WKWebsiteDataRecord`,
     `WKScriptMessage`, `WKUserScript`, `WKNavigationAction`,
     `WKNavigationResponse`, `WKFrameInfo`, `WKBackForwardListItem`,
     `WKBackForwardList`, `WKNavigation`, `WKWindowFeatures`,
     `URLAuthenticationChallenge`, `URLProtectionSpace`, `URLCredential`,
     `WKSecurityOrigin`, `URLRequest`, `NSURLRequest`, `URLResponse`, and
     `NSError`.
   - Most `wv_*_toLua` converters already exist in `Webview.swift`; only
     `wv_URLRequest_toLua`, `wv_URLResponse_toLua`, and `wv_toURLRequest` are
     new in this file.
   - Add `wv_URLRequest_toLua`, `wv_URLResponse_toLua`, and `wv_toURLRequest`
     with behavior matching the private helpers in `HTTP.swift`.
     `wv_toURLRequest` must accept a URL string or a request table with `URL`,
     `mainDocumentURL`, `HTTPBody`, `HTTPMethod`, `timeoutInterval`,
     `HTTPShouldHandleCookies`, `HTTPShouldUsePipelining`, `cachePolicy`,
     `networkServiceType`, and `HTTPHeaderFields`.
   - Use length-aware `lua_tolstring` for request-table `HTTPBody`.
   - Replace WebView window, parent/child, navigation, back-forward-list,
     datastore option, tracking ID, and callback object pushes with `wv_pushAny`.
   - Use `wv_getWindowFromUD` for WebView receiver extraction and relative
     ordering windows.

2. In `WebviewDatastore.swift`:
   - Push default/private/from-WebView datastores through `wv_pushAny`.
   - Pull datastore userdata through `wv_toWKWebsiteDataStore`.
   - Push fetch-record callback results by iterating records and using
     `wv_pushAny` for each record.
   - Expose all website data type sets and record data type sets as arrays.
   - Add wrappers `wv_WKWebsiteDataStore_toLua`,
     `wv_WKWebsiteDataRecord_toLua`, and `wv_toWKWebsiteDataStore` around the
     current `pushWKWebsiteDataStore`, `pushWKWebsiteDataRecord`, and
     `toWKWebsiteDataStoreFromLua` helpers.

3. In `WebviewToolbar.swift`:
   - Replace remaining toolbar constructor/callback/copy/item-detail pushes
     with `wv_pushAny`.
   - Add wrappers `wv_HSToolbar_toLua` and `wv_NSToolbarItem_toLua` using the
     current `toolbar_pushHSToolbar` and `pushNSToolbarItem` helpers.
   - Preserve current `getToolbar` receiver extraction and existing chooser
     window-context behavior.
   - Convert nested `NSToolbarItemGroup.subitems` by iterating and using
     `wv_pushAny`; expose item identifiers as raw strings.

4. In `WebviewUsercontent.swift`:
   - Push new usercontent controllers with `HSUserContentController_toLua`.
   - Convert `injectScript` tables through `table_toWKUserScript`.
   - Push `userScripts()` as an array of tables through `wv_pushAny`.
   - Rename user script/message converters to
     `wv_WKUserScript_toLua` / `wv_WKScriptMessage_toLua` so `wv_pushAny` can
     call them.
   - Update all existing call sites of the renamed functions in
     `WebviewUsercontent.swift`.
   - In script messages, push `body`, `frameInfo`, and `webView` through
     `wv_pushAny`.

5. In `WebviewView.swift` and `WebviewWindow.swift`:
   - Replace callback argument pushes for WebView windows, navigation actions,
     navigation responses, auth challenges, protection spaces, window features,
     and delete-on-close GC calls with `wv_pushAny`.

6. Add `Tests/CosmicHammerTests/WebviewConversionTests.swift`:
   - Constructor smoke test for toolbar, private datastore, and usercontent
     returning userdata.
   - Window-server-gated `webview.new` test proving a datastore userdata option
     and request table are accepted.
   - Usercontent script round-trip test proving scripts return Lua tables.
   - Toolbar item-details test proving nested toolbar userdata and raw string
     identifiers survive conversion.

7. Update `TODO.org`:
   - Mark the WebView item done only after build, focused WebView tests, and
     Claude implementation review converge.

## Verification

Run the build first because Swift tests depend on bundled Lua resources:

```sh
mise exec -- just build
```

Then run focused tests:

```sh
SDK_PATH="$(xcrun --show-sdk-path)" COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/build/test/Cosmic Hammer.app/Contents/Resources" swift test -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" --filter WebviewConversionTests
```

If useful, finish with:

```sh
mise exec -- just verify
```

If compilation exposes stale helper names or platform API drift, update the plan
and implementation instead of forcing the stale diff through unchanged.
