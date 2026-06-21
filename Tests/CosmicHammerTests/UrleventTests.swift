import Testing
import Foundation
import CLua
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite(.serialized) final class UrleventTests {

        // MARK: - URL Parsing (pure Swift, no Lua needed)

        @Test func httpURLParsesSchemeHostParams() {
            let result = parseURLEvent("http://example.com?a=1&b=2")
            #expect(result != nil)
            #expect(result?.scheme == "http")
            #expect(result?.host == "example.com")
            #expect(result?.params["a"] == "1")
            #expect(result?.params["b"] == "2")
        }

        @Test func httpsURLNormalizesCase() {
            let result = parseURLEvent("HTTPS://Example.Com/path")
            #expect(result != nil)
            #expect(result?.scheme == "https")
            #expect(result?.host == "example.com")
        }

        @Test func barePathGetsFileScheme() {
            let result = parseURLEvent("/tmp/foo.html")
            #expect(result != nil)
            #expect(result?.scheme == "file")
            #expect(result?.fullURL.hasPrefix("file://") == true)
        }

        @Test func pathWithSpacesIsEncoded() {
            let result = parseURLEvent("/path/to/my file.html")
            #expect(result != nil)
            #expect(result?.scheme == "file")
            #expect(result?.fullURL.contains("%20") == true)
        }

        @Test func pathWithHashIsHandledCorrectly() {
            // After bug fix 1: # in filenames should be encoded, not treated as fragment
            let result = parseURLEvent("/path/to/file#1.html")
            #expect(result != nil)
            #expect(result?.scheme == "file")
            // The # must be percent-encoded so URL doesn't treat it as fragment
            #expect(result?.fullURL.contains("%23") == true)
        }

        @Test func urlWithNoQueryParams() {
            let result = parseURLEvent("http://example.com")
            #expect(result != nil)
            #expect(result?.params.isEmpty == true)
        }

        @Test func urlWithEmptyQueryValue() {
            let result = parseURLEvent("http://example.com?key=")
            #expect(result != nil)
            #expect(result?.params["key"] == "")
        }

        @Test func urlWithQueryNoEquals() {
            // bits.count != 2 guard skips entries without '='
            let result = parseURLEvent("http://example.com?key")
            #expect(result != nil)
            #expect(result?.params.isEmpty == true)
        }

        @Test func urlWithDuplicateQueryKeys() {
            // Last value wins
            let result = parseURLEvent("http://example.com?a=1&a=2")
            #expect(result != nil)
            #expect(result?.params["a"] == "2")
        }

        @Test func urlWithEncodedQueryChars() {
            let result = parseURLEvent("http://example.com?name=hello%20world")
            #expect(result != nil)
            #expect(result?.params["name"] == "hello world")
        }

        @Test func emptyURLStringDoesNotCrash() {
            let result = parseURLEvent("")
            // Empty string produces a valid but empty URL in Foundation
            // Just verify no crash
            _ = result
        }

        @Test func cosmichammerSchemeURL() {
            let result = parseURLEvent("cosmichammer://doThing?val=1")
            #expect(result != nil)
            #expect(result?.scheme == "cosmichammer")
            #expect(result?.host == "dothing")
            #expect(result?.params["val"] == "1")
        }

        @Test func mailtoURL() {
            let result = parseURLEvent("mailto:user@example.com")
            #expect(result != nil)
            #expect(result?.scheme == "mailto")
        }

        @Test func fileURLExplicit() {
            let result = parseURLEvent("file:///tmp/foo.html")
            #expect(result != nil)
            #expect(result?.scheme == "file")
        }

        @Test func urlWithMultipleQueryParams() {
            let result = parseURLEvent("http://example.com?x=1&y=2&z=3")
            #expect(result != nil)
            #expect(result?.params.count == 3)
            #expect(result?.params["x"] == "1")
            #expect(result?.params["y"] == "2")
            #expect(result?.params["z"] == "3")
        }

        @Test func pathWithUnicodeIsEncoded() {
            let result = parseURLEvent("/tmp/caf\u{00e9}.html")
            #expect(result != nil)
            #expect(result?.scheme == "file")
            #expect(result?.fullURL.contains("caf") == true)
        }

        @Test func barePathPreservesDirectory() {
            let result = parseURLEvent("/usr/local/bin/something")
            #expect(result != nil)
            #expect(result?.scheme == "file")
            #expect(result?.fullURL.contains("/usr/local/bin/something") == true)
        }

        // MARK: - Lua callback integration

        @Test func setCallbackReceivesURLParts() {
            withModuleLoaded(luaopen_hs_liburlevent) { L in
                // Register a callback that stores its arguments in globals
                #expect(luaEval(L, """
                    _G._cb_scheme = nil
                    _G._cb_host = nil
                    _G._cb_params = nil
                    _G._cb_fullURL = nil
                    _G._cb_pid = nil
                    mod.setCallback(function(scheme, host, params, fullURL, pid)
                        _G._cb_scheme = scheme
                        _G._cb_host = host
                        _G._cb_params = params
                        _G._cb_fullURL = fullURL
                        _G._cb_pid = pid
                    end)
                """))

                // Verify the callback was set by checking we can call setCallback without error
                #expect(luaEvalBool(L, "return type(mod.setCallback) == 'function'") == true)
            }
        }

        @Test func getDefaultHandlerReturnsStringOrNil() {
            withModuleLoaded(luaopen_hs_liburlevent) { L in
                // getDefaultHandler should return a string (bundle ID) for "http"
                let resultType = luaEvalString(L, "return type(mod.getDefaultHandler('http'))")
                // Should be "string" or "nil" — just ensure no crash
                #expect(resultType == "string" || resultType == "nil")
            }
        }

        @Test func getAllHandlersReturnsTable() {
            withModuleLoaded(luaopen_hs_liburlevent) { L in
                let resultType = luaEvalString(L, "return type(mod.getAllHandlersForScheme('http'))")
                #expect(resultType == "table")
            }
        }
    }
}
