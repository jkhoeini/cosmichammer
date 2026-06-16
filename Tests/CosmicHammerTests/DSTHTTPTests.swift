import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite("DST HTTP") final class DSTHTTPTests {

        // MARK: - Helpers

        /// Create a Lua state with a configured SimulatedNetwork, register the http module
        /// as the global "http", and run the body. The caller can configure responses on the
        /// returned SimulatedNetwork before executing Lua code.
        private func withHTTPState(
            faults: FaultConfig = FaultConfig(),
            configure: (SimulatedNetwork) -> Void = { _ in },
            body: (UnsafeMutablePointer<lua_State>) throws -> Void
        ) rethrows {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let net = env.network as! SimulatedNetwork
            configure(net)

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer {
                environmentDetach(L)
                lua_close(L)
            }

            _ = luaopen_hs_libhttp(L)
            lua_setglobal(L, "http")

            try body(L)
        }

        // MARK: - Synchronous GET

        @Test func httpGetReturnsConfiguredResponse() {
            withHTTPState(configure: { net in
                net.httpResponses["https://example.com/api"] = HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/plain"],
                    body: "hello world".data(using: .utf8)
                )
            }) { L in
                let status = luaEvalInt(L, """
                    local status, body, headers = http.doRequest("https://example.com/api", "GET")
                    return status
                """)
                #expect(status == 200)

                let body = luaEvalString(L, """
                    local status, body, headers = http.doRequest("https://example.com/api", "GET")
                    return body
                """)
                #expect(body == "hello world")
            }
        }

        @Test func httpGetReturnsDefaultResponseForUnknownURL() {
            withHTTPState { L in
                // SimulatedNetwork has a default response of 200 "OK" for unknown URLs
                let status = luaEvalInt(L, """
                    local status, body, headers = http.doRequest("https://unknown.example.com/path", "GET")
                    return status
                """)
                #expect(status == 200)

                let body = luaEvalString(L, """
                    local status, body, headers = http.doRequest("https://unknown.example.com/path", "GET")
                    return body
                """)
                #expect(body == "OK")
            }
        }

        @Test func httpGetWithCustomResponseHeaders() {
            withHTTPState(configure: { net in
                net.httpResponses["https://example.com/headers"] = HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/html", "X-Custom": "test-value"],
                    body: "<html></html>".data(using: .utf8)
                )
            }) { L in
                let customHeader = luaEvalString(L, """
                    local status, body, headers = http.doRequest("https://example.com/headers", "GET")
                    return headers["X-Custom"]
                """)
                #expect(customHeader == "test-value")
            }
        }

        @Test func httpGetWithJsonBody() {
            withHTTPState(configure: { net in
                net.httpResponses["https://api.example.com/data"] = HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: "{\"key\":\"value\",\"count\":42}".data(using: .utf8)
                )
            }) { L in
                let status = luaEvalInt(L, """
                    local status, body, headers = http.doRequest("https://api.example.com/data", "GET")
                    return status
                """)
                #expect(status == 200)

                // Non-text/* content type: body is present but may not be a Lua string
                let bodyType = luaEvalString(L, """
                    local status, body, headers = http.doRequest("https://api.example.com/data", "GET")
                    return type(body)
                """)
                #expect(bodyType != "nil")
            }
        }

        @Test func httpGetReturnsTextBodyAsString() {
            withHTTPState(configure: { net in
                net.httpResponses["https://example.com/text"] = HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/plain"],
                    body: "plain text response".data(using: .utf8)
                )
            }) { L in
                // text/* content types should be returned as UTF-8 strings
                let body = luaEvalString(L, """
                    local status, body, headers = http.doRequest("https://example.com/text", "GET")
                    return body
                """)
                #expect(body == "plain text response")
            }
        }

        @Test func httpGetReturns404StatusCode() {
            withHTTPState(configure: { net in
                net.httpResponses["https://example.com/missing"] = HTTPResponse(
                    statusCode: 404,
                    headers: ["Content-Type": "text/plain"],
                    body: "Not Found".data(using: .utf8)
                )
            }) { L in
                let status = luaEvalInt(L, """
                    local status, body, headers = http.doRequest("https://example.com/missing", "GET")
                    return status
                """)
                #expect(status == 404)
            }
        }

        // MARK: - Synchronous POST / doRequest

        @Test func httpDoRequestPost() {
            withHTTPState(configure: { net in
                net.httpResponses["https://example.com/submit"] = HTTPResponse(
                    statusCode: 201,
                    headers: ["Content-Type": "text/plain"],
                    body: "created".data(using: .utf8)
                )
            }) { L in
                let status = luaEvalInt(L, """
                    local status, body, headers = http.doRequest("https://example.com/submit", "POST", "payload=data")
                    return status
                """)
                #expect(status == 201)

                let body = luaEvalString(L, """
                    local status, body, headers = http.doRequest("https://example.com/submit", "POST", "payload=data")
                    return body
                """)
                #expect(body == "created")
            }
        }

        @Test func httpDoRequestWithHeaders() {
            withHTTPState(configure: { net in
                net.httpResponses["https://example.com/auth"] = HTTPResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/plain"],
                    body: "authorized".data(using: .utf8)
                )
            }) { L in
                // Pass request headers as the 4th argument
                let body = luaEvalString(L, """
                    local status, body, headers = http.doRequest(
                        "https://example.com/auth", "GET", nil,
                        {["Authorization"] = "Bearer token123"}
                    )
                    return body
                """)
                #expect(body == "authorized")
            }
        }

        // MARK: - Fault injection

        @Test func httpGetTimeoutUnderFault() {
            var faults = FaultConfig()
            faults.httpTimeoutProbability = 1.0
            withHTTPState(faults: faults) { L in
                // Under timeout fault, doRequest returns 0, nil, nil
                let status = luaEvalInt(L, """
                    local status, body, headers = http.doRequest("https://example.com/api", "GET")
                    return status
                """)
                #expect(status == 0)

                let bodyIsNil = luaEvalBool(L, """
                    local status, body, headers = http.doRequest("https://example.com/api", "GET")
                    return body == nil
                """)
                #expect(bodyIsNil == true)
            }
        }

        @Test func httpGetConnectionFailUnderFault() {
            var faults = FaultConfig()
            faults.connectionFailProbability = 1.0
            withHTTPState(faults: faults) { L in
                // Under connection failure, doRequest returns 0, nil, nil
                let status = luaEvalInt(L, """
                    local status, body, headers = http.doRequest("https://example.com/api", "GET")
                    return status
                """)
                #expect(status == 0)

                let headersNil = luaEvalBool(L, """
                    local status, body, headers = http.doRequest("https://example.com/api", "GET")
                    return headers == nil
                """)
                #expect(headersNil == true)
            }
        }

        // MARK: - Pure functions (no network)

        @Test func httpUrlPartsParses() {
            withHTTPState { L in
                let scheme = luaEvalString(L, """
                    local parts = http.urlParts("https://example.com:8080/path?q=1#frag")
                    return parts.scheme
                """)
                #expect(scheme == "https")

                let host = luaEvalString(L, """
                    local parts = http.urlParts("https://example.com:8080/path?q=1#frag")
                    return parts.host
                """)
                #expect(host == "example.com")

                let port = luaEvalInt(L, """
                    local parts = http.urlParts("https://example.com:8080/path?q=1#frag")
                    return parts.port
                """)
                #expect(port == 8080)

                let path = luaEvalString(L, """
                    local parts = http.urlParts("https://example.com:8080/path?q=1#frag")
                    return parts.path
                """)
                #expect(path == "/path")

                let query = luaEvalString(L, """
                    local parts = http.urlParts("https://example.com:8080/path?q=1#frag")
                    return parts.query
                """)
                #expect(query == "q=1")

                let fragment = luaEvalString(L, """
                    local parts = http.urlParts("https://example.com:8080/path?q=1#frag")
                    return parts.fragment
                """)
                #expect(fragment == "frag")
            }
        }

        @Test func httpUrlPartsFileURL() {
            withHTTPState { L in
                let isFile = luaEvalBool(L, """
                    local parts = http.urlParts("file:///tmp/test.txt")
                    return parts.isFileURL
                """)
                #expect(isFile == true)

                let notFile = luaEvalBool(L, """
                    local parts = http.urlParts("https://example.com")
                    return parts.isFileURL
                """)
                #expect(notFile == false)
            }
        }

        @Test func httpEncodeForQuery() {
            withHTTPState { L in
                let encoded = luaEvalString(L, """
                    return http.encodeForQuery("hello world&foo=bar")
                """)
                #expect(encoded != nil)
                // Spaces should be percent-encoded, & should be encoded
                #expect(encoded!.contains("%20") || encoded!.contains("+"))
                #expect(!encoded!.contains(" "))
            }
        }

        @Test func httpEncodeForQueryPreservesSimpleStrings() {
            withHTTPState { L in
                let encoded = luaEvalString(L, """
                    return http.encodeForQuery("simple")
                """)
                #expect(encoded == "simple")
            }
        }

        // MARK: - Determinism

        @Test func httpResponsesDeterministicAcrossRuns() {
            // Same seed should produce identical behavior
            for _ in 0..<2 {
                let harness = SimulatorHarness(seed: 42)
                let env = harness.createEnvironment()
                let net = env.network as! SimulatedNetwork
                net.httpResponses["https://example.com"] = HTTPResponse(
                    statusCode: 200, headers: [:], body: "deterministic".data(using: .utf8)
                )

                let L = luaL_newstate()!
                luaL_openlibs(L)
                environmentAttach(L, env)
                defer {
                    environmentDetach(L)
                    lua_close(L)
                }

                _ = luaopen_hs_libhttp(L)
                lua_setglobal(L, "http")

                let status = luaEvalInt(L, """
                    local s, b, h = http.doRequest("https://example.com", "GET")
                    return s
                """)
                #expect(status == 200)
            }
        }
    }
}
