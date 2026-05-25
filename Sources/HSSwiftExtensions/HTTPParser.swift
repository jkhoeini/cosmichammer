import Foundation
import CryptoKit

// MARK: - HTTP Request Head

/// Parsed HTTP/1.1 request line + headers + body.
struct HTTPRequestHead {
    let method: String               // "GET", "POST", etc.
    let path: String                 // "/api/foo?bar=1"
    let version: String              // "HTTP/1.1"
    let headers: [(String, String)]  // preserves order, allows duplicates
    let body: Data
}

// MARK: - HTTP Response Head

/// HTTP response status line + headers (body handled separately).
struct HTTPResponseHead {
    let statusCode: Int
    let statusMessage: String
    let headers: [(String, String)]
}

// MARK: - Standard Status Messages

private let standardStatusMessages: [Int: String] = [
    100: "Continue",
    101: "Switching Protocols",
    200: "OK",
    201: "Created",
    204: "No Content",
    301: "Moved Permanently",
    302: "Found",
    304: "Not Modified",
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    408: "Request Timeout",
    409: "Conflict",
    413: "Payload Too Large",
    415: "Unsupported Media Type",
    422: "Unprocessable Entity",
    429: "Too Many Requests",
    500: "Internal Server Error",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout",
]

// MARK: - Request Parser

/// Attempts to parse a complete HTTP request from the buffer.
/// Returns `(request, bytesConsumed)` if complete, or `nil` if more data is needed.
func parseHTTPRequest(from buffer: Data) -> (HTTPRequestHead, Int)? {
    // Look for end-of-headers marker (\r\n\r\n)
    guard let headerEndRange = findHeaderEnd(in: buffer) else {
        return nil
    }

    let headerBytes = buffer[buffer.startIndex..<headerEndRange.lowerBound]
    let headersEndOffset = headerEndRange.upperBound

    // Parse request line and headers from the header section
    guard let headerString = String(data: Data(headerBytes), encoding: .utf8) else {
        return nil
    }

    let lines = headerString.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }

    // Parse request line: "METHOD /path HTTP/1.1"
    let requestLine = lines[0]
    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }

    let method = parts[0]
    let path = parts[1]
    let version = parts.count >= 3 ? parts[2] : "HTTP/1.1"

    // Parse headers
    var headers: [(String, String)] = []
    for i in 1..<lines.count {
        let line = lines[i]
        if line.isEmpty { continue }
        if let colonIndex = line.firstIndex(of: ":") {
            let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
    }

    // Determine body length
    let isChunked = headerValue(named: "Transfer-Encoding", in: headers)?
        .lowercased().contains("chunked") ?? false

    if isChunked {
        return parseChunkedBody(
            method: method, path: path, version: version,
            headers: headers, buffer: buffer, bodyStart: headersEndOffset
        )
    }

    let contentLength = headerValue(named: "Content-Length", in: headers)
        .flatMap { Int($0) } ?? 0

    let totalNeeded = headersEndOffset + contentLength
    guard buffer.count >= totalNeeded else {
        return nil // incomplete body
    }

    let body: Data
    if contentLength > 0 {
        body = buffer[headersEndOffset..<(headersEndOffset + contentLength)]
    } else {
        body = Data()
    }

    let request = HTTPRequestHead(
        method: method, path: path, version: version,
        headers: headers, body: body
    )
    return (request, totalNeeded)
}

// MARK: - Chunked Transfer Encoding

/// Parses a chunked-encoded body, concatenating all chunks and stripping framing.
private func parseChunkedBody(
    method: String, path: String, version: String,
    headers: [(String, String)],
    buffer: Data, bodyStart: Int
) -> (HTTPRequestHead, Int)? {
    var offset = bodyStart
    var body = Data()

    while offset < buffer.count {
        // Find the chunk-size line ending with \r\n
        guard let lineEnd = findCRLF(in: buffer, from: offset) else {
            return nil // incomplete chunk header
        }

        guard let sizeString = String(data: buffer[offset..<lineEnd], encoding: .utf8),
              let chunkSize = Int(sizeString.trimmingCharacters(in: .whitespaces), radix: 16) else {
            return nil
        }

        offset = lineEnd + 2 // skip past \r\n

        if chunkSize == 0 {
            // Terminal chunk — skip trailing \r\n
            if offset + 2 > buffer.count { return nil }
            offset += 2
            break
        }

        // Read chunk data
        guard offset + chunkSize + 2 <= buffer.count else {
            return nil // incomplete chunk data
        }

        body.append(buffer[offset..<(offset + chunkSize)])
        offset += chunkSize + 2 // skip chunk data + trailing \r\n
    }

    let request = HTTPRequestHead(
        method: method, path: path, version: version,
        headers: headers, body: body
    )
    return (request, offset)
}

// MARK: - Response Formatter

/// Formats a complete HTTP/1.1 response ready to send over TCP.
///
/// - Parameters:
///   - status: HTTP status code (e.g. 200, 404).
///   - headers: Additional response headers (Content-Length is added automatically).
///   - body: Optional response body data.
///   - keepAlive: If true, adds `Connection: keep-alive`; otherwise `Connection: close`.
/// - Returns: The serialized HTTP response as `Data`.
func formatHTTPResponse(
    status: Int,
    headers: [(String, String)] = [],
    body: Data? = nil,
    keepAlive: Bool = false
) -> Data {
    let statusMessage = standardStatusMessages[status] ?? "Unknown"
    var responseString = "HTTP/1.1 \(status) \(statusMessage)\r\n"

    // Collect user headers, track which are already set
    var hasContentLength = false
    var hasConnection = false
    for (name, value) in headers {
        responseString += "\(name): \(value)\r\n"
        if name.lowercased() == "content-length" { hasContentLength = true }
        if name.lowercased() == "connection" { hasConnection = true }
    }

    // Auto-add Content-Length
    let bodyLength = body?.count ?? 0
    if !hasContentLength {
        responseString += "Content-Length: \(bodyLength)\r\n"
    }

    // Auto-add Connection header
    if !hasConnection {
        responseString += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
    }

    responseString += "\r\n"

    var result = Data(responseString.utf8)
    if let body = body {
        result.append(body)
    }
    return result
}

// MARK: - HTTP Digest Auth

/// HTTP Digest Authentication helper (RFC 2617, MD5 algorithm).
///
/// Uses a fixed username of `"user"` (Hammerspoon convention — password-only auth).
struct HTTPDigestAuth {
    let realm: String
    let password: String

    /// Generate a 401 challenge response with `WWW-Authenticate` header.
    func challengeResponse() -> (statusCode: Int, headers: [(String, String)], body: Data) {
        let nonce = generateNonce()
        let authenticate = "Digest realm=\"\(realm)\", nonce=\"\(nonce)\", algorithm=MD5, qop=\"auth\""
        let body = Data("401 Unauthorized".utf8)
        let headers: [(String, String)] = [
            ("WWW-Authenticate", authenticate),
            ("Content-Type", "text/plain"),
        ]
        return (statusCode: 401, headers: headers, body: body)
    }

    /// Validate an `Authorization: Digest ...` header from a request.
    ///
    /// Expected response calculation (RFC 2617):
    /// ```
    /// HA1 = MD5(username:realm:password)
    /// HA2 = MD5(method:uri)
    /// response = MD5(HA1:nonce:nc:cnonce:qop:HA2)      // qop=auth
    ///         or MD5(HA1:nonce:HA2)                      // no qop
    /// ```
    func isAuthorized(method: String, authHeader: String) -> Bool {
        let params = parseDigestHeader(authHeader)

        guard let nonce = params["nonce"],
              let uri = params["uri"],
              let clientResponse = params["response"] else {
            return false
        }

        let username = params["username"] ?? "user"

        let ha1 = md5Hex("\(username):\(realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")

        let expectedResponse: String
        if let qop = params["qop"],
           let nc = params["nc"],
           let cnonce = params["cnonce"] {
            expectedResponse = md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            expectedResponse = md5Hex("\(ha1):\(nonce):\(ha2)")
        }

        return clientResponse.lowercased() == expectedResponse.lowercased()
    }
}

// MARK: - Digest Auth Internals

/// Generate a random hex nonce string.
private func generateNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Parse the key="value" pairs from a `Digest` authorization header.
private func parseDigestHeader(_ header: String) -> [String: String] {
    // Strip "Digest " prefix if present
    var value = header
    if let range = value.range(of: "Digest ", options: [.caseInsensitive, .anchored]) {
        value = String(value[range.upperBound...])
    }

    var result: [String: String] = [:]

    // Split on commas, handling quoted values
    let scanner = Scanner(string: value)
    scanner.charactersToBeSkipped = nil

    while !scanner.isAtEnd {
        // Skip whitespace and commas
        _ = scanner.scanCharacters(from: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",")))

        // Read key
        guard let key = scanner.scanUpToString("=") else { break }
        guard scanner.scanString("=") != nil else { break }

        // Read value — may be quoted
        let val: String
        if scanner.scanString("\"") != nil {
            val = scanner.scanUpToString("\"") ?? ""
            _ = scanner.scanString("\"")
        } else {
            val = scanner.scanUpToString(",") ?? ""
        }

        result[key.trimmingCharacters(in: .whitespaces)] = val
    }

    return result
}

/// Compute MD5 hex digest of a string using CryptoKit.
private func md5Hex(_ string: String) -> String {
    let data = Data(string.utf8)
    let digest = Insecure.MD5.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Parsing Utilities

/// Find the `\r\n\r\n` header terminator in the buffer.
/// Returns the range of the four-byte sequence, or nil if not found.
private func findHeaderEnd(in data: Data) -> Range<Int>? {
    let marker: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
    guard data.count >= 4 else { return nil }

    for i in data.startIndex...(data.startIndex + data.count - 4) {
        if data[i] == marker[0]
            && data[i + 1] == marker[1]
            && data[i + 2] == marker[2]
            && data[i + 3] == marker[3] {
            return i..<(i + 4)
        }
    }
    return nil
}

/// Find the next `\r\n` starting from `offset`. Returns the index of `\r`.
private func findCRLF(in data: Data, from offset: Int) -> Int? {
    guard data.count >= offset + 2 else { return nil }
    for i in offset..<(data.count - 1) {
        if data[i] == 0x0D && data[i + 1] == 0x0A {
            return i
        }
    }
    return nil
}

/// Case-insensitive header lookup. Returns the first matching value.
private func headerValue(named name: String, in headers: [(String, String)]) -> String? {
    let lowered = name.lowercased()
    return headers.first(where: { $0.0.lowercased() == lowered })?.1
}
