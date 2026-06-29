import Foundation
import Network
import CryptoKit
import os.log

// MARK: - NWWebSocketServer

/// Server-side WebSocket implementation built on Network.framework.
///
/// Handles the RFC 6455 WebSocket protocol: upgrade handshake, frame
/// parsing/generation, ping/pong, and close. Designed to be driven by
/// the HTTP server layer — when an incoming HTTP request carries an
/// `Upgrade: websocket` header the server hands the raw NWConnection
/// to ``acceptConnection(_:request:)``.
///
/// Only one client connection is supported at a time (matching the
/// current `hs.httpserver` WebSocket API).

/// Maximum accumulated WebSocket read-buffer size (10 MB).  If a client
/// sends more data than this without producing complete frames the
/// connection is torn down.
private let kMaxWebSocketBufferSize = 10_485_760

/// Maximum number of WebSocket frames consumed in a single
/// ``processFrames`` call.  This prevents a burst of tiny frames from
/// monopolising the queue.
private let kMaxWebSocketFramesPerCall = 10_000

/// Maximum allowed WebSocket frame payload size (16 MB).  Frames whose
/// declared payload length exceeds this are rejected and the connection
/// is torn down immediately.
private let kMaxWebSocketPayloadSize: UInt64 = 16_777_216

class NWWebSocketServer {

    // MARK: Public properties

    /// The URL path this WebSocket endpoint listens on (e.g. "/ws").
    let path: String

    /// The currently connected client, if any.
    private(set) var clientConnection: NWConnection?

    /// Called on the main queue when a text message arrives from the client.
    var onMessage: ((String, [String: String]) -> Void)?

    /// Called on the main queue when a client connection is established.
    var onOpen: (() -> Void)?

    /// Called on the main queue when the client disconnects.
    var onClose: (() -> Void)?

    // MARK: Private state

    private let queue = DispatchQueue(label: "NWWebSocketServer")

    /// Partial frame data accumulated while reading.
    private var readBuffer = Data()
    private var clientHeaders: [String: String] = [:]

    private static let logger = Logger(
        subsystem: "org.cosmichammer",
        category: "NWWebSocketServer"
    )

    // MARK: Initialiser

    init(path: String) {
        self.path = path
    }

    // MARK: - Connection lifecycle

    /// Accept an incoming TCP connection that has been identified as a
    /// WebSocket upgrade request.
    ///
    /// The caller must supply the raw HTTP headers so that the handshake
    /// response (101 Switching Protocols) can be computed and sent before
    /// switching to WebSocket framing.
    ///
    /// - Parameters:
    ///   - connection: A ready `NWConnection` from the HTTP listener.
    ///   - request: The full HTTP request headers as a dictionary.  At a
    ///     minimum `"Sec-WebSocket-Key"` must be present.
    func acceptConnection(_ connection: NWConnection, request headers: [String: String]) {
        // If there is an existing client, close it first.
        if let old = clientConnection {
            sendCloseFrame(on: old)
            old.cancel()
        }

        clientConnection = connection
        readBuffer = Data()
        clientHeaders = headers

        // Build and send the HTTP 101 handshake response.
        guard let acceptKey = headers["Sec-WebSocket-Key"] else {
            Self.logger.error("WebSocket upgrade missing Sec-WebSocket-Key")
            connection.cancel()
            clientConnection = nil
            return
        }

        let responseKey = Self.computeAcceptKey(acceptKey)
        let handshake = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(responseKey)",
            "", ""   // blank line terminates headers
        ].joined(separator: "\r\n")

        guard let handshakeData = handshake.data(using: .utf8) else {
            Self.logger.error("Failed to encode WebSocket handshake")
            connection.cancel()
            clientConnection = nil
            return
        }

        connection.send(
            content: handshakeData,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    Self.logger.error("Handshake send error: \(error)")
                    connection.cancel()
                    self.clientConnection = nil
                    return
                }
                // Handshake complete — start the read loop.
                self.beginReading(connection)
                DispatchQueue.main.async { self.onOpen?() }
            }
        )
    }

    /// Convenience overload that accepts the raw HTTP request bytes,
    /// parses the headers internally, and calls through to the
    /// dictionary-based variant.
    func acceptConnection(_ connection: NWConnection, rawHTTPRequest data: Data) {
        let headers = Self.parseHTTPHeaders(data)
        acceptConnection(connection, request: headers)
    }

    /// Send a UTF-8 text message to the connected client.
    func send(_ message: String) {
        guard let connection = clientConnection else { return }
        guard let payload = message.data(using: .utf8) else { return }
        let frame = Self.buildFrame(opcode: .text, payload: payload, masked: false)
        connection.send(
            content: frame,
            completion: .contentProcessed { error in
                if let error {
                    Self.logger.error("WebSocket send error: \(error)")
                }
            }
        )
    }

    /// Gracefully close the WebSocket connection.
    func close() {
        guard let connection = clientConnection else { return }
        sendCloseFrame(on: connection)
        // Give the close frame a moment to flush before tearing down.
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            connection.cancel()
            self?.clientConnection = nil
            self?.clientHeaders = [:]
        }
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }

    // MARK: - Reading

    /// Kick off the asynchronous read loop on `connection`.
    private func beginReading(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }

            if let content {
                if self.readBuffer.count + content.count > kMaxWebSocketBufferSize {
                    Self.logger.error("WebSocket read buffer exceeded \(kMaxWebSocketBufferSize) bytes — disconnecting client")
                    self.tearDown(connection)
                    return
                }
                self.readBuffer.append(content)
                self.processFrames(connection)
            }

            if let error {
                Self.logger.error("WebSocket read error: \(error)")
                self.tearDown(connection)
                return
            }

            if isComplete {
                self.tearDown(connection)
                return
            }

            // Continue reading.
            self.beginReading(connection)
        }
    }

    /// Consume as many complete WebSocket frames as possible from
    /// ``readBuffer``.
    private func processFrames(_ connection: NWConnection) {
        var framesConsumed = 0
        for _ in 0..<kMaxWebSocketFramesPerCall {
            guard let frame = Self.parseFrame(&readBuffer) else { break }
            framesConsumed += 1

            switch frame.opcode {
            case .text:
                if let text = String(data: frame.payload, encoding: .utf8) {
                    let callback = self.onMessage
                    let headers = self.clientHeaders
                    DispatchQueue.main.async { callback?(text, headers) }
                }

            case .binary:
                // The current API only exposes text messages.  Silently
                // drop binary frames.
                break

            case .ping:
                // Reply with pong carrying the same payload.
                let pong = Self.buildFrame(opcode: .pong, payload: frame.payload, masked: false)
                connection.send(content: pong, completion: .contentProcessed { _ in })

            case .pong:
                // Unsolicited pong — ignore.
                break

            case .close:
                // Echo the close frame and tear down.
                sendCloseFrame(on: connection)
                tearDown(connection)
                return

            case .continuation:
                // Fragmented messages are not used in the current
                // hs.httpserver WebSocket API.  Drop them.
                break
            }
        }
        // Warn only when the iteration limit was actually exhausted (not when
        // the loop exited normally because no complete frame was available).
        if framesConsumed >= kMaxWebSocketFramesPerCall && readBuffer.count > 2 {
            Self.logger.warning("WebSocket processFrames hit \(kMaxWebSocketFramesPerCall)-frame limit with \(self.readBuffer.count) bytes remaining")
        }
    }

    // MARK: - Teardown

    private func tearDown(_ connection: NWConnection) {
        connection.cancel()
        if clientConnection === connection {
            clientConnection = nil
            clientHeaders = [:]
            readBuffer = Data()
            DispatchQueue.main.async { [weak self] in self?.onClose?() }
        }
    }

    private func sendCloseFrame(on connection: NWConnection) {
        let frame = Self.buildFrame(opcode: .close, payload: Data(), masked: false)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - RFC 6455 Frame Parsing

    /// Opcodes defined in RFC 6455 section 5.2.
    enum Opcode: UInt8 {
        case continuation = 0x0
        case text         = 0x1
        case binary       = 0x2
        case close        = 0x8
        case ping         = 0x9
        case pong         = 0xA
    }

    /// A fully decoded WebSocket frame.
    struct Frame {
        let fin: Bool
        let opcode: Opcode
        let payload: Data
    }

    /// Try to parse one complete frame from the front of `buffer`.
    ///
    /// On success the consumed bytes are removed from `buffer` and the
    /// parsed ``Frame`` is returned.  If the buffer does not yet contain
    /// a complete frame, `nil` is returned and the buffer is left
    /// untouched.
    static func parseFrame(_ buffer: inout Data) -> Frame? {
        // Minimum frame size: 2 bytes (flags+opcode, mask+len).
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[buffer.startIndex]
        let byte1 = buffer[buffer.startIndex + 1]

        let fin     = (byte0 & 0x80) != 0
        let rawOp   = byte0 & 0x0F
        let masked  = (byte1 & 0x80) != 0
        var payloadLen = UInt64(byte1 & 0x7F)

        var offset = 2

        // Extended payload length.
        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            payloadLen = UInt64(buffer[buffer.startIndex + offset]) << 8
                       | UInt64(buffer[buffer.startIndex + offset + 1])
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen = (payloadLen << 8) | UInt64(buffer[buffer.startIndex + offset + i])
            }
            offset += 8
        }

        // Reject frames whose declared payload exceeds the safety cap.
        if payloadLen > kMaxWebSocketPayloadSize {
            Self.logger.error("WebSocket frame payload \(payloadLen) bytes exceeds \(kMaxWebSocketPayloadSize)-byte limit — dropping connection")
            buffer.removeAll()
            return nil
        }

        // Masking key (4 bytes, present when masked).
        var maskingKey: [UInt8]?
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskingKey = [
                buffer[buffer.startIndex + offset],
                buffer[buffer.startIndex + offset + 1],
                buffer[buffer.startIndex + offset + 2],
                buffer[buffer.startIndex + offset + 3],
            ]
            offset += 4
        }

        // Payload.
        let totalNeeded = offset + Int(payloadLen)
        guard buffer.count >= totalNeeded else { return nil }

        var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + totalNeeded)])

        // Unmask if necessary.
        if let key = maskingKey {
            for i in 0..<payload.count {
                payload[payload.startIndex + i] ^= key[i % 4]
            }
        }

        // Consume the frame from the buffer.
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + totalNeeded))

        guard let opcode = Opcode(rawValue: rawOp) else {
            // Unknown opcode — treat as close.
            return Frame(fin: fin, opcode: .close, payload: Data())
        }

        return Frame(fin: fin, opcode: opcode, payload: payload)
    }

    // MARK: - RFC 6455 Frame Building

    /// Build a WebSocket frame.
    ///
    /// - Parameters:
    ///   - opcode: The frame opcode.
    ///   - payload: The payload bytes.
    ///   - masked: Whether to apply a random masking key (required for
    ///     client-to-server frames, not for server-to-client).
    static func buildFrame(opcode: Opcode, payload: Data, masked: Bool) -> Data {
        var frame = Data()

        // Byte 0: FIN + opcode (always set FIN for non-fragmented).
        frame.append(0x80 | opcode.rawValue)

        // Byte 1: MASK flag + payload length.
        let maskBit: UInt8 = masked ? 0x80 : 0x00
        let length = payload.count

        if length <= 125 {
            frame.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }

        // Masking key + masked payload (if applicable).
        if masked {
            var key = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &key)
            frame.append(contentsOf: key)
            var maskedPayload = payload
            for i in 0..<maskedPayload.count {
                maskedPayload[maskedPayload.startIndex + i] ^= key[i % 4]
            }
            frame.append(maskedPayload)
        } else {
            frame.append(payload)
        }

        return frame
    }

    // MARK: - Handshake helpers

    /// Compute the `Sec-WebSocket-Accept` value per RFC 6455 section 4.2.2.
    ///
    /// accept = base64( SHA-1( key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) )
    static func computeAcceptKey(_ clientKey: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = clientKey + magic
        let hash = Insecure.SHA1.hash(data: Data(combined.utf8))
        return Data(hash).base64EncodedString()
    }

    /// Minimal HTTP/1.1 header parser.  Returns a dictionary of
    /// header-name -> value (last value wins on duplicates).
    static func parseHTTPHeaders(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var headers: [String: String] = [:]
        let lines = text.components(separatedBy: "\r\n")
        for line in lines.dropFirst() {  // skip request line
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return headers
    }

    /// Check whether raw HTTP request data represents a WebSocket upgrade.
    static func isWebSocketUpgrade(_ data: Data) -> Bool {
        let headers = parseHTTPHeaders(data)
        guard let upgrade = headers["Upgrade"] ?? headers["upgrade"] else { return false }
        return upgrade.lowercased() == "websocket"
    }

    /// Extract the request path (e.g. "/ws") from the HTTP request line.
    static func requestPath(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Request line: "GET /path HTTP/1.1"
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }
}
