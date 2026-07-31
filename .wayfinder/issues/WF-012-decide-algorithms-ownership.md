---
id: WF-012
title: Decide Algorithms.swift ownership and deletion
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by: []
---

## Question

Resolve whether the duplicated, mostly uncalled hash implementations in `Algorithms.swift` are deleted in favor of `Hash.swift` and public `hs.hash` behavior, or become the single canonical pure-Swift implementation used by `Hash.swift`. Define observable digest/error tests that protect the decision without retaining dead C-shaped exports solely for tests.

## Resolution comments

### 2026-07-29 — Delete the duplicate C-shaped algorithms; test `hs.hash`

Delete `Sources/HSSwiftExtensions/Algorithms.swift`. `Hash.swift` remains the sole implementation owner for the documented `hs.hash` module, with its algorithm callbacks private behind the module's Lua interface. Do not retain or rename the 40 `init_*`/`append_*`/`finish_*` functions, expose a typed callback table for tests, or move their C-shaped `UnsafeMutableRawPointer` interface into another file.

The evidence is one-sided: all 40 C ABIs are statically unconsumed; only the CRC32 and SHA256 triples have Swift-identity callers, both from two digest-length-only tests. The other 34 functions have no active-tree caller. `Hash.swift` already owns the production path and public set of 13 algorithms. Nine families overlap, `Algorithms.swift` additionally carries six undocumented/unreachable families (`MD2`, `MD4`, `SHA224`, `SHA384`, `hmacSHA224`, `hmacSHA384`), and it lacks all four public SHA3 families. It is not a canonical pure-Swift module: it is a second CommonCrypto/zlib implementation expressed through manually allocated raw contexts. Making it canonical would enlarge the interface, rewire working production code, and preserve dead algorithms solely because they exist.

The two direct tests in `TigerStyleSystemBTests.swift` are deleted, not redirected to private `Hash.swift` callbacks. Their length assertions are weaker than the existing public known-answer tests for CRC32 and SHA256. Tests cross the same `hs.hash` interface users do.

#### Ownership and order

Make this a small serial foundation slice before the Hash LuaSwift work package and before any Location slice that might touch `TigerStyleSystemBTests.swift`:

- slice owner: delete all of `Algorithms.swift`; remove only the Algorithms/hash section from `TigerStyleSystemBTests.swift`; own both whole files for the slice;
- oracle owner: before implementation, lock/add the digest matrix in `HashFunctionalTests.swift`/`TigerStyleMediaTests.swift`; facade-only assertions in `HashFunctionalTests.swift` must use `runLua` with `require("hs.hash")`, not `withModuleLoaded(luaopen_hs_libhash)`, without editing production;
- after the deletion receipt, hand `Hash.swift` and the hash-specific test files to the WP2 Hash owner; no concurrent writers;
- do not edit `Hash.swift`, `Package.swift`, registry inputs/outputs, manifests, or generated files in the deletion slice.

Because SwiftPM discovers source files automatically, deleting `Algorithms.swift` needs no package-manifest replacement. The native-bridge partition owns scheduling and integration of this slice; the Lua-entrypoint wave still owns removal of `luaopen_hs_libhash` after the typed registry foundation.

#### Observable regression contract

Lock behavior at the user-facing seam, never at implementation callbacks. Native table/digest/lifecycle assertions may use `withModuleLoaded`; sorting, shortcut metamethods, constants wrapping, and `forFile` must use the full `runLua`/`require("hs.hash")` facade path:

1. Through full `require("hs.hash")`, `hs.hash.types` is the exact sorted 13-name set: `CRC32`, `MD5`, `SHA1`, `SHA256`, `SHA3_224`, `SHA3_256`, `SHA3_384`, `SHA3_512`, `SHA512`, `hmacMD5`, `hmacSHA1`, `hmacSHA256`, `hmacSHA512`.
2. Each of the 13 algorithms has at least one published known-answer vector through `new/append/finish/value`; hashes also cover empty input, and HMAC covers an empty key plus a binary key/data case containing NUL.
3. For every family, split streaming input equals contiguous input; hexadecimal output decodes to the exact binary `value(true)` bytes; digest lengths match the documented type.
4. Case-insensitive accepted names preserve the canonical name returned by `type()`. An unknown name remains a catchable Lua error ending in `bad argument #1 (unrecognized hash type)`.
5. `value()` before finish is `nil`; repeated `finish()` is stable; append after finish returns `nil, "hash calculation completed"`; in-progress GC returns registry/self-reference counts to baseline without firing the canary.
6. Through full `require("hs.hash")`, the legacy Lua shortcuts and `forFile` remain equivalent to the streaming path; file read and 1 GiB limit errors remain covered by their simulated filesystem path. Raw native-module tests assert only set membership for `types`, because native insertion order is intentionally different from the facade's sorted order.

Deletion is not ready until the independently approved matrix contains all 13 known-answer rows plus the empty-input and NUL-containing HMAC cases and passes on the pre-deletion tree. Current tests have known answers for only CRC32, MD5, SHA1, SHA256, SHA512, and hmacSHA256; non-empty/length checks for the remaining families do not satisfy this gate. The deletion gate validates the complete matrix, then runs the focused hash functional, media, lifecycle, full-facade, module-load, and registration suites; integration runs `just verify`. Release artifact inspection must find none of the 40 deleted C names. Source checks must find no `Algorithms.swift`, no direct `init_CRC32`/`init_SHA256` test calls, and no replacement export aliases.

Independent review found that facade-only behavior could not be proved through the raw native-module harness and that existing suites lack seven required known-answer families. Both gaps are now explicit pre-deletion gates; re-review reported no issues and confirmed deletion is lower risk than canonicalizing the duplicate. Fresh pre-decision `just test` evidence passed 1,044 tests in 127 suites. No production source is changed by this decision session. No new ticket or Fog graduation is required; the existing non-module bridge partition now has the answer it needs.
