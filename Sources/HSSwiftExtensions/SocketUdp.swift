import Cocoa
import LuaSkin
import os.log
import Network

// socket.h shared definitions are duplicated here since Swift can't import the C header directly.
// Each Swift file in the socket extension gets its own copy of the shared state.

private func mainThreadDispatch(_ block: @escaping () -> Void) {
    DispatchQueue.main.async { autoreleasepool { block() } }
}

// Userdata struct matching socket.h's asyncSocketUserData
private struct AsyncSocketUserData {
    var selfRef: Int32 = 0
    var asyncSocket: UnsafeMutableRawPointer? = nil
}

private let DEFAULT: NSString = "DEFAULT"
private let SERVER: NSString = "SERVER"
private let CLIENT: NSString = "CLIENT"

private var refTable: Int32 = LUA_NOREF
private let USERDATA_TAG = "hs.socket.udp"

// Helper to extract the HSAsyncUdpSocket from userdata
private func getUserData(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSAsyncUdpSocket {
    let ud = lua_touserdata(L, idx)!.assumingMemoryBound(to: AsyncSocketUserData.self)
    return Unmanaged<HSAsyncUdpSocket>.fromOpaque(ud.pointee.asyncSocket!).takeUnretainedValue()
}

// MARK: - Lua Callbacks

private func udpConnectCallback(_ asyncUdpSocket: HSAsyncUdpSocket) {
    mainThreadDispatch {
        if asyncUdpSocket.connectCallbackRef != LUA_NOREF {
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(asyncUdpSocket.connectCallbackRef))
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.connectCallbackRef)

            asyncUdpSocket.connectCallbackRef = LUA_NOREF
            if lua_pcall(L, 0, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

private func udpWriteCallback(_ asyncUdpSocket: HSAsyncUdpSocket, tag: Int) {
    mainThreadDispatch {
        if asyncUdpSocket.writeCallbackRef != LUA_NOREF {
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(asyncUdpSocket.writeCallbackRef))
            lua_pushany(L, NSNumber(value: tag))
            luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.writeCallbackRef)

            asyncUdpSocket.writeCallbackRef = LUA_NOREF
            if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

private func udpReadCallback(_ asyncUdpSocket: HSAsyncUdpSocket, data: Data, address: Data) {
    mainThreadDispatch {
        if asyncUdpSocket.readCallbackRef != LUA_NOREF {
            let L = lua_getCurrentState()!
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(asyncUdpSocket.readCallbackRef))
            lua_pushany(L, String(data: data, encoding: .utf8) as NSString?)
            lua_pushany(L, address as NSData)
            if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        }
    }
}

// MARK: - UDP Socket Class (Network.framework + POSIX)

/// Hybrid UDP socket implementation.
///
/// - **Connected mode** (after `connect()`): uses `NWConnection` with `.udp` parameters.
/// - **Unconnected / server mode** (after `listen()` or bare `send(to:)`): uses a POSIX
///   `AF_INET`/`AF_INET6` datagram socket with `DispatchSource.makeReadSource` for async receives.
private class HSAsyncUdpSocket {
    var readCallbackRef: Int32 = LUA_NOREF
    var writeCallbackRef: Int32 = LUA_NOREF
    var connectCallbackRef: Int32 = LUA_NOREF
    var socketTimeout: TimeInterval = -1

    // NWConnection for connected mode
    private var connection: NWConnection?

    // POSIX socket for unconnected / server mode
    private var fd4: Int32 = -1  // IPv4 socket
    private var fd6: Int32 = -1  // IPv6 socket
    private var readSource4: DispatchSourceRead?
    private var readSource6: DispatchSourceRead?
    private var continuousReceive: Bool = false
    private var receiveActive: Bool = false

    // State
    private var isBound: Bool = false
    private var _isConnected: Bool = false
    private var _isClosed: Bool = true
    private var ipv4Enabled: Bool = true
    private var ipv6Enabled: Bool = true
    private var preferredIPVersion: Int = 0  // 0=neutral, 4=ipv4, 6=ipv6
    private var maxRecvIPv4Buffer: UInt16 = 9216
    private var maxRecvIPv6Buffer: UInt32 = 9216
    private var broadcastEnabled: Bool = false
    private var reusePortEnabled: Bool = false

    // Addressing info
    private var _localHost: String?
    private var _localPort: UInt16 = 0
    private var _connectedHost: String?
    private var _connectedPort: UInt16 = 0
    private var _userData: AnyObject?

    private let delegateQueue: DispatchQueue

    init(queue: DispatchQueue) {
        delegateQueue = queue
    }

    // MARK: userData

    func setUserData(_ obj: AnyObject?) {
        _userData = obj
    }

    func userData() -> AnyObject? {
        return _userData
    }

    // MARK: State queries

    func isConnected() -> Bool { return _isConnected }
    func isClosed() -> Bool { return _isClosed }
    func isIPv4() -> Bool {
        if let conn = connection {
            if case .hostPort(let host, _) = conn.currentPath?.remoteEndpoint {
                return "\(host)".contains(".")
            }
        }
        return fd4 >= 0
    }
    func isIPv6() -> Bool {
        if let conn = connection {
            if case .hostPort(let host, _) = conn.currentPath?.remoteEndpoint {
                return "\(host)".contains(":")
            }
        }
        return fd6 >= 0
    }
    func isIPv4Enabled() -> Bool { return ipv4Enabled }
    func isIPv6Enabled() -> Bool { return ipv6Enabled }
    func isIPv4Preferred() -> Bool { return preferredIPVersion == 4 }
    func isIPv6Preferred() -> Bool { return preferredIPVersion == 6 }
    func isIPVersionNeutral() -> Bool { return preferredIPVersion == 0 }
    func maxReceiveIPv4BufferSize() -> UInt16 { return maxRecvIPv4Buffer }
    func maxReceiveIPv6BufferSize() -> UInt32 { return maxRecvIPv6Buffer }

    // MARK: Address info

    func connectedHost() -> String? { return _connectedHost }
    func connectedPort() -> UInt16 { return _connectedPort }
    func connectedAddress() -> Data? {
        guard _isConnected else { return nil }
        return sockaddrData(host: _connectedHost ?? "", port: _connectedPort, family: AF_INET)
    }

    func localHost() -> String? { return _localHost }
    func localPort() -> UInt16 { return _localPort }
    func localAddress() -> Data? {
        return localAddress_IPv4() ?? localAddress_IPv6()
    }

    func localHost_IPv4() -> String? {
        if fd4 >= 0 { return hostFromFd(fd4, family: AF_INET) }
        return nil
    }
    func localHost_IPv6() -> String? {
        if fd6 >= 0 { return hostFromFd(fd6, family: AF_INET6) }
        return nil
    }
    func localPort_IPv4() -> UInt16 {
        if fd4 >= 0 { return portFromFd(fd4, family: AF_INET) }
        return 0
    }
    func localPort_IPv6() -> UInt16 {
        if fd6 >= 0 { return portFromFd(fd6, family: AF_INET6) }
        return 0
    }
    func localAddress_IPv4() -> Data? {
        if fd4 >= 0 { return sockaddrDataFromFd(fd4, family: AF_INET) }
        return nil
    }
    func localAddress_IPv6() -> Data? {
        if fd6 >= 0 { return sockaddrDataFromFd(fd6, family: AF_INET6) }
        return nil
    }

    // MARK: Configuration

    func setIPv4Enabled(_ flag: Bool) { ipv4Enabled = flag }
    func setIPv6Enabled(_ flag: Bool) { ipv6Enabled = flag }
    func setPreferIPv4() { preferredIPVersion = 4 }
    func setPreferIPv6() { preferredIPVersion = 6 }
    func setIPVersionNeutral() { preferredIPVersion = 0 }
    func setMaxReceiveIPv4BufferSize(_ size: UInt16) { maxRecvIPv4Buffer = size }
    func setMaxReceiveIPv6BufferSize(_ size: UInt32) { maxRecvIPv6Buffer = size }

    func enableBroadcast(_ flag: Bool) throws {
        broadcastEnabled = flag
        // Apply to existing POSIX sockets immediately
        if fd4 >= 0 { applyBroadcast(fd4) }
        if fd6 >= 0 { applyBroadcast(fd6) }
    }

    func enableReusePort(_ flag: Bool) throws {
        reusePortEnabled = flag
        // Apply to existing POSIX sockets immediately
        if fd4 >= 0 { applyReusePort(fd4) }
        if fd6 >= 0 { applyReusePort(fd6) }
    }

    // MARK: Connect (NWConnection mode)

    func connect(toHost host: String, onPort port: UInt16) throws {
        guard !_isConnected else {
            throw NSError(domain: "HSAsyncUdpSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "Already connected"])
        }

        let params = NWParameters.udp
        if !ipv4Enabled {
            params.requiredLocalEndpoint = nil
            params.prohibitedInterfaceTypes = []
        }

        let nwHost: NWEndpoint.Host
        if preferredIPVersion == 4 {
            // Attempt to force IPv4 by resolving to numeric if possible
            nwHost = NWEndpoint.Host(host)
        } else if preferredIPVersion == 6 {
            nwHost = NWEndpoint.Host(host)
        } else {
            nwHost = NWEndpoint.Host(host)
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "HSAsyncUdpSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }

        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self._isConnected = true
                self._isClosed = false
                self._connectedHost = host
                self._connectedPort = port
                self.cacheLocalInfoFromConnection(conn)
                self.setUserData(DEFAULT)
                os_log(.debug,"UDP socket connected")
                if self.connectCallbackRef != LUA_NOREF {
                    udpConnectCallback(self)
                }
            case .failed(let err):
                self._isConnected = false
                os_log(.error, "%{public}s", "UDP socket did not connect: \(err)")
                mainThreadDispatch {
                    self.connectCallbackRef = lsLuaUnref(nil,refTable, ref: self.connectCallbackRef)
                }
            case .cancelled:
                self._isConnected = false
                self._isClosed = true
                self.setUserData(nil)
                os_log(.debug,"UDP socket closed")
            default:
                break
            }
        }

        conn.start(queue: delegateQueue)
        _isClosed = false
    }

    // MARK: Bind (POSIX mode)

    func bind(toPort port: UInt16) throws {
        guard !isBound && !_isConnected else {
            throw NSError(domain: "HSAsyncUdpSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Socket already bound or connected"])
        }

        if ipv4Enabled {
            fd4 = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd4 >= 0 else {
                throw NSError(domain: "HSAsyncUdpSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create IPv4 socket: \(String(cString: strerror(errno)))"])
            }
            if reusePortEnabled { applyReusePort(fd4) }
            if broadcastEnabled { applyBroadcast(fd4) }

            var addr4 = sockaddr_in()
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_port = port.bigEndian
            addr4.sin_addr.s_addr = INADDR_ANY

            let bindResult = withUnsafePointer(to: &addr4) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd4, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindResult != 0 {
                let errMsg = String(cString: strerror(errno))
                Darwin.close(fd4)
                fd4 = -1
                throw NSError(domain: "HSAsyncUdpSocket", code: 5, userInfo: [NSLocalizedDescriptionKey: "IPv4 bind failed: \(errMsg)"])
            }
        }

        if ipv6Enabled {
            fd6 = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
            guard fd6 >= 0 else {
                if fd4 >= 0 { Darwin.close(fd4); fd4 = -1 }
                throw NSError(domain: "HSAsyncUdpSocket", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create IPv6 socket: \(String(cString: strerror(errno)))"])
            }
            if reusePortEnabled { applyReusePort(fd6) }

            // Only bind IPv6 — prevent dual-stack overlap with the IPv4 socket
            var on: Int32 = 1
            setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))

            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = port.bigEndian
            addr6.sin6_addr = in6addr_any

            let bindResult = withUnsafePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd6, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if bindResult != 0 {
                let errMsg = String(cString: strerror(errno))
                Darwin.close(fd6)
                fd6 = -1
                // IPv4 bind may have succeeded — that's OK
                if fd4 < 0 {
                    throw NSError(domain: "HSAsyncUdpSocket", code: 5, userInfo: [NSLocalizedDescriptionKey: "IPv6 bind failed: \(errMsg)"])
                }
            }
        }

        guard fd4 >= 0 || fd6 >= 0 else {
            throw NSError(domain: "HSAsyncUdpSocket", code: 6, userInfo: [NSLocalizedDescriptionKey: "No sockets could be bound"])
        }

        isBound = true
        _isClosed = false

        // Cache local address info
        if fd4 >= 0 {
            _localHost = hostFromFd(fd4, family: AF_INET)
            _localPort = portFromFd(fd4, family: AF_INET)
        } else if fd6 >= 0 {
            _localHost = hostFromFd(fd6, family: AF_INET6)
            _localPort = portFromFd(fd6, family: AF_INET6)
        }
    }

    // MARK: Receive (POSIX dispatch sources)

    func beginReceiving() throws {
        guard isBound else {
            throw NSError(domain: "HSAsyncUdpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "Socket not bound"])
        }
        continuousReceive = true
        receiveActive = true
        installReadSources()
    }

    func receiveOnce() throws {
        guard isBound else {
            throw NSError(domain: "HSAsyncUdpSocket", code: 7, userInfo: [NSLocalizedDescriptionKey: "Socket not bound"])
        }
        continuousReceive = false
        receiveActive = true
        installReadSources()
    }

    func pauseReceiving() {
        receiveActive = false
        if let src = readSource4 { src.cancel(); readSource4 = nil }
        if let src = readSource6 { src.cancel(); readSource6 = nil }
    }

    private func installReadSources() {
        if fd4 >= 0 && readSource4 == nil {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd4, queue: delegateQueue)
            src.setEventHandler { [weak self] in self?.handleReadEvent(fd: self?.fd4 ?? -1, isIPv6: false) }
            src.setCancelHandler { /* nothing */ }
            readSource4 = src
            src.resume()
        }
        if fd6 >= 0 && readSource6 == nil {
            let src = DispatchSource.makeReadSource(fileDescriptor: fd6, queue: delegateQueue)
            src.setEventHandler { [weak self] in self?.handleReadEvent(fd: self?.fd6 ?? -1, isIPv6: true) }
            src.setCancelHandler { /* nothing */ }
            readSource6 = src
            src.resume()
        }
    }

    private func handleReadEvent(fd: Int32, isIPv6: Bool) {
        guard fd >= 0, receiveActive else { return }

        let bufSize = isIPv6 ? Int(maxRecvIPv6Buffer) : Int(maxRecvIPv4Buffer)
        var buffer = [UInt8](repeating: 0, count: bufSize)
        var addrStorage = sockaddr_storage()
        var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let bytesRead = withUnsafeMutablePointer(to: &addrStorage) { storagePtr in
            storagePtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buffer, bufSize, 0, sa, &addrLen)
            }
        }

        guard bytesRead > 0 else { return }

        let data = Data(bytes: buffer, count: bytesRead)
        let address = withUnsafePointer(to: &addrStorage) { ptr in
            Data(bytes: ptr, count: Int(addrLen))
        }

        os_log(.debug,"Data read from UDP socket")
        if readCallbackRef != LUA_NOREF {
            udpReadCallback(self, data: data, address: address)
        }

        if !continuousReceive {
            receiveActive = false
            if let src = readSource4 { src.cancel(); readSource4 = nil }
            if let src = readSource6 { src.cancel(); readSource6 = nil }
        }
    }

    // MARK: Receive (NWConnection mode)

    func receiveFromConnection(continuous: Bool) {
        guard let conn = connection else { return }
        continuousReceive = continuous
        receiveActive = true

        conn.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                os_log(.error, "%{public}s", "UDP receive error: \(error)")
                return
            }
            if let data = content {
                // Build a sockaddr from the connected endpoint info
                let address = self.connectedAddress() ?? Data()
                os_log(.debug,"Data read from UDP socket")
                if self.readCallbackRef != LUA_NOREF {
                    udpReadCallback(self, data: data, address: address)
                }
            }
            if self.continuousReceive && self.receiveActive {
                self.receiveFromConnection(continuous: true)
            }
        }
    }

    // MARK: Send (connected NWConnection)

    func send(_ data: Data, withTimeout timeout: TimeInterval, tag: Int) {
        guard let conn = connection else {
            os_log(.error,"UDP send failed: not connected")
            return
        }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                os_log(.error, "%{public}s", "Data not sent on UDP socket: \(error)")
                mainThreadDispatch {
                    self.writeCallbackRef = lsLuaUnref(nil,refTable, ref: self.writeCallbackRef)
                }
            } else {
                os_log(.debug,"Data written to UDP socket")
                if self.writeCallbackRef != LUA_NOREF {
                    udpWriteCallback(self, tag: tag)
                }
            }
        })
    }

    // MARK: Send (unconnected POSIX sendto)

    func send(_ data: Data, toHost host: String, port: UInt16, withTimeout timeout: TimeInterval, tag: Int) {
        // Ensure at least one POSIX socket exists
        ensurePosixSocket()

        delegateQueue.async { [weak self] in
            guard let self = self else { return }

            var sent = false

            // Try IPv4 first if preferred or neutral
            if self.ipv4Enabled && self.fd4 >= 0 && self.preferredIPVersion != 6 {
                if self.sendtoIPv4(fd: self.fd4, data: data, host: host, port: port) {
                    sent = true
                }
            }

            // Fall back to IPv6
            if !sent && self.ipv6Enabled && self.fd6 >= 0 {
                if self.sendtoIPv6(fd: self.fd6, data: data, host: host, port: port) {
                    sent = true
                }
            }

            // Last resort: try IPv4 even if IPv6 was preferred
            if !sent && self.ipv4Enabled && self.fd4 >= 0 && self.preferredIPVersion == 6 {
                if self.sendtoIPv4(fd: self.fd4, data: data, host: host, port: port) {
                    sent = true
                }
            }

            if sent {
                os_log(.debug,"Data written to UDP socket")
                if self.writeCallbackRef != LUA_NOREF {
                    udpWriteCallback(self, tag: tag)
                }
            } else {
                os_log(.error, "%{public}s", "Data not sent on UDP socket: could not resolve or send to \(host):\(port)")
                mainThreadDispatch {
                    self.writeCallbackRef = lsLuaUnref(nil,refTable, ref: self.writeCallbackRef)
                }
            }
        }
    }

    private func sendtoIPv4(fd: Int32, data: Data, host: String, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            // Try DNS resolution
            guard let resolved = resolveHost(host, family: AF_INET) else {
                return false
            }
            addr.sin_addr = resolved
        }

        let result = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(fd, buf.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result >= 0
    }

    private func sendtoIPv6(fd: Int32, data: Data, host: String, port: UInt16) -> Bool {
        var addr6 = sockaddr_in6()
        addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr6.sin6_family = sa_family_t(AF_INET6)
        addr6.sin6_port = port.bigEndian
        if inet_pton(AF_INET6, host, &addr6.sin6_addr) != 1 {
            guard let resolved = resolveHost6(host) else {
                return false
            }
            addr6.sin6_addr = resolved
        }

        let result = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr6) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.sendto(fd, buf.baseAddress, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        return result >= 0
    }

    private func resolveHost(_ host: String, family: Int32) -> in_addr? {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let res = result else { return nil }
        defer { freeaddrinfo(res) }
        if res.pointee.ai_family == AF_INET {
            let sa = res.pointee.ai_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            return sa.sin_addr
        }
        return nil
    }

    private func resolveHost6(_ host: String) -> in6_addr? {
        var hints = addrinfo()
        hints.ai_family = AF_INET6
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let res = result else { return nil }
        defer { freeaddrinfo(res) }
        if res.pointee.ai_family == AF_INET6 {
            let sa = res.pointee.ai_addr!.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            return sa.sin6_addr
        }
        return nil
    }

    // MARK: Ensure POSIX socket exists for unconnected sends

    private func ensurePosixSocket() {
        if ipv4Enabled && fd4 < 0 {
            fd4 = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            if fd4 >= 0 {
                if broadcastEnabled { applyBroadcast(fd4) }
                if reusePortEnabled { applyReusePort(fd4) }
                _isClosed = false
            }
        }
        if ipv6Enabled && fd6 < 0 {
            fd6 = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
            if fd6 >= 0 {
                var on: Int32 = 1
                setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
                if reusePortEnabled { applyReusePort(fd6) }
                _isClosed = false
            }
        }
    }

    // MARK: Close

    func close() {
        pauseReceiving()

        if let conn = connection {
            conn.cancel()
            connection = nil
        }
        if fd4 >= 0 { Darwin.close(fd4); fd4 = -1 }
        if fd6 >= 0 { Darwin.close(fd6); fd6 = -1 }

        _isConnected = false
        _isClosed = true
        isBound = false
        setUserData(nil)
    }

    // MARK: POSIX helpers

    private func applyBroadcast(_ fd: Int32) {
        var flag: Int32 = broadcastEnabled ? 1 : 0
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &flag, socklen_t(MemoryLayout<Int32>.size))
    }

    private func applyReusePort(_ fd: Int32) {
        var flag: Int32 = reusePortEnabled ? 1 : 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &flag, socklen_t(MemoryLayout<Int32>.size))
    }

    private func hostFromFd(_ fd: Int32, family: Int32) -> String? {
        if family == AF_INET {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard result == 0 else { return nil }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var inAddr = addr.sin_addr
            inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buf)
        } else {
            var addr = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard result == 0 else { return nil }
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var in6Addr = addr.sin6_addr
            inet_ntop(AF_INET6, &in6Addr, &buf, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buf)
        }
    }

    private func portFromFd(_ fd: Int32, family: Int32) -> UInt16 {
        if family == AF_INET {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard result == 0 else { return 0 }
            return UInt16(bigEndian: addr.sin_port)
        } else {
            var addr = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard result == 0 else { return 0 }
            return UInt16(bigEndian: addr.sin6_port)
        }
    }

    private func sockaddrDataFromFd(_ fd: Int32, family: Int32) -> Data? {
        if family == AF_INET {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard result == 0 else { return nil }
            return withUnsafePointer(to: &addr) { ptr in
                Data(bytes: ptr, count: Int(len))
            }
        } else {
            var addr = sockaddr_in6()
            var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let result = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getsockname(fd, sa, &len)
                }
            }
            guard result == 0 else { return nil }
            return withUnsafePointer(to: &addr) { ptr in
                Data(bytes: ptr, count: Int(len))
            }
        }
    }

    private func sockaddrData(host: String, port: UInt16, family: Int32) -> Data? {
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)
            return withUnsafePointer(to: &addr) { ptr in
                Data(bytes: ptr, count: MemoryLayout<sockaddr_in>.size)
            }
        } else {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            inet_pton(AF_INET6, host, &addr.sin6_addr)
            return withUnsafePointer(to: &addr) { ptr in
                Data(bytes: ptr, count: MemoryLayout<sockaddr_in6>.size)
            }
        }
    }

    private func cacheLocalInfoFromConnection(_ conn: NWConnection) {
        if let path = conn.currentPath {
            if let local = path.localEndpoint, case .hostPort(let host, let port) = local {
                _localHost = "\(host)"
                _localPort = port.rawValue
            }
        }
    }
}

// MARK: - Module Functions

/// hs.socket.udp.new([fn]) -> hs.socket.udp object
/// Constructor
/// Creates an unconnected asynchronous UDP socket object.
///
/// Parameters:
///  * `fn` - An optional [callback function](#setCallback) for reading data from the socket, settable here for convenience.
///
/// Returns:
///  * An [`hs.socket.udp`](#new) object.
///
private func socketudp_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let udpDelegateQueue = DispatchQueue(label: "udpDelegateQueue")
    let asyncUdpSocket = HSAsyncUdpSocket(queue: udpDelegateQueue)

    if lua_type(L, 1) == LUA_TFUNCTION {
        lua_pushvalue(L, 1)
        asyncUdpSocket.readCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    lua_getglobal(L, "require")


    lua_pushstring(L, "hs.socket")


    lua_pcall(L, 1, 1, 0)
    for field in ["udp", "timeout"] {
        lua_getfield(L, -1, field)
    }
    asyncUdpSocket.socketTimeout = lua_tonumber(L, -1)

    let userData = lua_newuserdata(L, MemoryLayout<AsyncSocketUserData>.size)!
        .assumingMemoryBound(to: AsyncSocketUserData.self)
    userData.pointee = AsyncSocketUserData()
    userData.pointee.asyncSocket = Unmanaged.passRetained(asyncUdpSocket).toOpaque()
    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

/// hs.socket.udp:connect(host, port[, fn]) -> self or nil
/// Method
/// Connects an unconnected socket.
///
/// Parameters:
///  * `host` - A string containing the hostname or IP address.
///  * `port` - A port number [1-65535].
///  * `fn` - An optional single-use callback function to execute after establishing the connection. The callback receives no parameters.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
/// * By design, UDP is a connectionless protocol, and connecting is not needed.
/// * Choosing to connect to a specific host/port has the following effect:
///   * You will only be able to send data to the connected host/port;
///   * You will only be able to receive data from the connected host/port;
///   * You will receive ICMP messages that come from the connected host/port, such as "connection refused".
/// * The actual process of connecting a UDP socket does not result in any communication on the socket, it simply changes the internal state of the socket.
/// * You cannot bind a socket for listening after it has been connected.
/// * You can only connect a socket once.
///
private func socketudp_connect(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)
    let theHost = lua_tovalue(L, at: 2) as! String
    let thePort = (lua_tovalue(L, at: 3) as! NSNumber).uint16Value

    if lua_type(L, 4) == LUA_TFUNCTION {
        lua_pushvalue(L, 4)
        asyncUdpSocket.connectCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    do {
        try asyncUdpSocket.connect(toHost: theHost, onPort: thePort)
    } catch {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.connectCallbackRef)

        asyncUdpSocket.connectCallbackRef = LUA_NOREF
        os_log(.error, "%{public}s", "Unable to connect: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:listen(port) -> self or nil
/// Method
/// Binds an unconnected socket to a port for listening.
///
/// Parameters:
///  * `port` - A port number [0-65535]. Ports [1-1023] are privileged. Port 0 allows the OS to select any available port.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
private func socketudp_listen(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)
    let thePort = (lua_tovalue(L, at: 2) as! NSNumber).uint16Value

    do {
        try asyncUdpSocket.bind(toPort: thePort)
    } catch {
        os_log(.error, "%{public}s", "Unable to bind port: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    asyncUdpSocket.setUserData(SERVER)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:close() -> self
/// Method
/// Immediately closes the socket, freeing it for reuse. Any pending send operations are discarded.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
private func socketudp_close(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncUdpSocket = getUserData(L, 1)

    asyncUdpSocket.close()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:pause() -> self
/// Method
/// Suspends reading of packets from the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object
///
/// Notes:
///  * Call one of the receive methods to resume.
///
private func socketudp_pause(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncUdpSocket = getUserData(L, 1)

    asyncUdpSocket.pauseReceiving()

    lua_pushvalue(L, 1)
    return 1
}

private func socketudp_receiveContinuous(_ L: UnsafeMutablePointer<lua_State>!, readContinuous: Bool) -> Bool {
    let asyncUdpSocket = getUserData(L, 1)

    if lua_type(L, 2) == LUA_TFUNCTION {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.readCallbackRef)

        asyncUdpSocket.readCallbackRef = LUA_NOREF
        lua_pushvalue(L, 2)
        asyncUdpSocket.readCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    if asyncUdpSocket.readCallbackRef == LUA_NOREF {
        os_log(.error,"No callback defined!")
        return false
    }

    // Connected mode uses NWConnection receive; unconnected uses POSIX dispatch sources
    if asyncUdpSocket.isConnected() {
        asyncUdpSocket.receiveFromConnection(continuous: readContinuous)
        return true
    }

    do {
        if readContinuous {
            try asyncUdpSocket.beginReceiving()
        } else {
            try asyncUdpSocket.receiveOnce()
        }
    } catch {
        os_log(.error, "%{public}s", "Unable to read from UDP socket: \(error.localizedDescription)")
        return false
    }

    return true
}

/// hs.socket.udp:receive([fn]) -> self or nil
/// Method
/// Reads packets from the socket as they arrive.
///
/// Parameters:
///  * `fn` - Optionally supply the [read callback](#setCallback) here.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Results are passed to the [callback function](#setCallback), which must be set to use this method.
///  * There are two modes of operation for receiving packets: one-at-a-time & continuous.
///  * In one-at-a-time mode, you call receiveOne every time you are ready process an incoming UDP packet.
///  * Receiving packets one-at-a-time may be better suited for implementing certain state machine code where your state machine may not always be ready to process incoming packets.
///  * In continuous mode, the callback is invoked immediately every time incoming udp packets are received.
///  * Receiving packets continuously is better suited to real-time streaming applications.
///  * You may switch back and forth between one-at-a-time mode and continuous mode.
///  * If the socket is currently in one-at-a-time mode, calling this method will switch it to continuous mode.
///
private func socketudp_receive(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if socketudp_receiveContinuous(L, readContinuous: true) {
        lua_pushvalue(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.socket.udp:receiveOne([fn]) -> self or nil
/// Method
/// Reads a single packet from the socket.
///
/// Parameters:
///  * `fn` - Optionally supply the [read callback](#setCallback) here.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Results are passed to the [callback function](#setCallback), which must be set to use this method.
///  * There are two modes of operation for receiving packets: one-at-a-time & continuous.
///  * In one-at-a-time mode, you call receiveOne every time you are ready process an incoming UDP packet.
///  * Receiving packets one-at-a-time may be better suited for implementing certain state machine code where your state machine may not always be ready to process incoming packets.
///  * In continuous mode, the callback is invoked immediately every time incoming udp packets are received.
///  * Receiving packets continuously is better suited to real-time streaming applications.
///  * You may switch back and forth between one-at-a-time mode and continuous mode.
///  * If the socket is currently in continuous mode, calling this method will switch it to one-at-a-time mode
///
private func socketudp_receiveOne(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    if socketudp_receiveContinuous(L, readContinuous: false) {
        lua_pushvalue(L, 1)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.socket.udp:send(message[, host, port][, tag, fn]) -> self
/// Method
/// Sends a packet to the destination address.
///
/// Parameters:
///  * `message` - A string containing data to be sent on the socket.
///  * `host` - A string containing the hostname or IP address.
///  * `port` - A port number [1-65535].
///  * `tag` - An optional integer to assist with labeling writes.
///  * `fn` - An optional single-use callback function to execute after sending the packet. The callback receives the tag parameter provided here.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * For non-connected sockets, the remote destination is specified for each packet.
///  * If the socket has been explicitly connected with [`connect`](#connect), only the message parameter and an optional tag and/or write callback can be supplied.
///  * Recall that connecting is optional for a UDP socket.
///  * For connected sockets, data can only be sent to the connected address.
///
private func socketudp_send(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)

    let sendData = lua_tovalue(L, at: 2) as! Data

    if asyncUdpSocket.isConnected() {
        let tag: Int = lua_type(L, 3) == LUA_TNUMBER ? Int(lua_tointeger(L, 3)) : -1
        if lua_type(L, 3) == LUA_TFUNCTION {
            lua_pushvalue(L, 3)
            asyncUdpSocket.writeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        }
        if lua_type(L, 3) != LUA_TFUNCTION && lua_type(L, 4) == LUA_TFUNCTION {
            lua_pushvalue(L, 4)
            asyncUdpSocket.writeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        }

        asyncUdpSocket.send(sendData, withTimeout: asyncUdpSocket.socketTimeout, tag: tag)
    } else {
        let theHost = lua_tovalue(L, at: 3) as! String
        let thePort = (lua_tovalue(L, at: 4) as! NSNumber).uint16Value
        let tag: Int = lua_type(L, 5) == LUA_TNUMBER ? Int(lua_tointeger(L, 5)) : -1
        if lua_type(L, 5) == LUA_TFUNCTION {
            lua_pushvalue(L, 5)
            asyncUdpSocket.writeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        }
        if lua_type(L, 5) != LUA_TFUNCTION && lua_type(L, 6) == LUA_TFUNCTION {
            lua_pushvalue(L, 6)
            asyncUdpSocket.writeCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        }

        asyncUdpSocket.send(sendData, toHost: theHost, port: thePort, withTimeout: asyncUdpSocket.socketTimeout, tag: tag)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:broadcast([flag]) -> self or nil
/// Method
/// Enables broadcasting on the underlying socket.
///
/// Parameters:
///  * `flag` - An optional boolean: `true` to enable broadcasting, `false` to disable it. Defaults to `true`.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * By default, the underlying socket in the OS will not allow you to send broadcast messages.
///  * In order to send broadcast messages, you need to enable this functionality in the socket.
///  * A broadcast is a UDP message to addresses like "192.168.255.255" or "255.255.255.255" that is delivered to every host on the network.
///  * The reason this is generally disabled by default (by the OS) is to prevent accidental broadcast messages from flooding the network.
///
private func socketudp_enableBroadcast(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncUdpSocket = getUserData(L, 1)
    let enableFlag: Bool = !(lua_type(L, 2) == LUA_TBOOLEAN && lua_toboolean(L, 3) == 0)

    do {
        try asyncUdpSocket.enableBroadcast(enableFlag)
    } catch {
        os_log(.error, "%{public}s", "Unable to enable broadcasting: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:reusePort([flag]) -> self or nil
/// Method
/// Enables port reuse on the socket.
///
/// Parameters:
///  * `flag` - An optional boolean: `true` to enable port reuse, `false` to disable it. Defaults to `true`.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * By default, only one socket can be bound to a given IP address & port at a time.
///  * To enable multiple processes to simultaneously bind to the same address & port, you need to enable this functionality in the socket.
///  * All processes that wish to use the address & port simultaneously must all enable reuse port on the socket bound to that port.
///  * Must be called before binding the socket.
///
private func socketudp_enableReusePort(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncUdpSocket = getUserData(L, 1)
    let enableFlag: Bool = !(lua_type(L, 2) == LUA_TBOOLEAN && lua_toboolean(L, 3) == 0)

    do {
        try asyncUdpSocket.enableReusePort(enableFlag)
    } catch {
        os_log(.error, "%{public}s", "Unable to enable port reuse: \(error.localizedDescription)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:enableIPv(version[, flag]) -> self or nil
/// Method
/// Enables or disables IPv4 or IPv6 on the underlying socket. By default, both are enabled.
///
/// Parameters:
///  * `version` - A number containing the IP version (4 or 6) to enable or disable.
///  * `flag` - A boolean: `true` to enable the chosen IP version, `false` to disable it. Defaults to `true`.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object, or `nil` if an error occurred.
///
/// Notes:
///  * Must be called before binding the socket. If you want to create an IPv6-only server, do something like:
///    * `hs.socket.udp.new(callback):enableIPv(4, false):listen(port):receive()`
///  * The convenience constructor [`hs.socket.server`](#server) will automatically bind the socket and requires closing and relistening to use this method.
///
private func socketudp_enableIPversion(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)
    let ipVersion = UInt8(lua_tointeger(L, 2))
    let enableFlag: Bool = !(lua_type(L, 3) == LUA_TBOOLEAN && lua_toboolean(L, 3) == 0)

    if ipVersion == 4 {
        asyncUdpSocket.setIPv4Enabled(enableFlag)
    } else if ipVersion == 6 {
        asyncUdpSocket.setIPv6Enabled(enableFlag)
    } else {
        os_log(.error, "%{public}s", "Invalid IP version: \(ipVersion)")
        lua_pushnil(L)
        return 1
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:preferIPv([version]) -> self
/// Method
/// Sets the preferred IP version: IPv4, IPv6, or neutral (first to resolve).
///
/// Parameters:
///  * `version` - An optional number containing the IP version to prefer. Anything but 4 or 6 else sets the default neutral behavior.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * If a DNS lookup returns only IPv4 results, the socket will automatically use IPv4.
///  * If a DNS lookup returns only IPv6 results, the socket will automatically use IPv6.
///  * If a DNS lookup returns both IPv4 and IPv6 results, then the protocol used depends on the configured preference.
///
private func socketudp_preferIPversion(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)

    if lua_type(L, 2) == LUA_TNUMBER && lua_tointeger(L, 2) == 4 {
        asyncUdpSocket.setPreferIPv4()
    } else if lua_type(L, 2) == LUA_TNUMBER && lua_tointeger(L, 2) == 6 {
        asyncUdpSocket.setPreferIPv6()
    } else {
        asyncUdpSocket.setIPVersionNeutral()
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:setBufferSize(size[, version]) -> self
/// Method
/// Sets the maximum size of the buffer that will be allocated for receive operations.
///
/// Parameters:
///  * `size` - An number containing the receive buffer size in bytes.
///  * `version` - An optional number containing the IP version for which to set the buffer size. Anything but 4 or 6 else sets the same size for both.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * The default maximum size is 9216 bytes.
///  * The theoretical maximum size of any IPv4 UDP packet is `UINT16_MAX = 65535`.
///  * The theoretical maximum size of any IPv6 UDP packet is `UINT32_MAX = 4294967295`.
///  * Since the OS notifies us of the size of each received UDP packet, the actual allocated buffer size for each packet is exact.
///  * In practice the size of UDP packets is generally much smaller than the max. Most protocols will send and receive packets of only a few bytes, or will set a limit on the size of packets to prevent fragmentation in the IP layer.
///  * If you set the buffer size too small, the sockets API in the OS will silently discard any extra data.
///
private func socketudp_setReceiveBufferSize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)
    let bufferSize = UInt(lua_tointeger(L, 2))
    let ipv4BufferSize = bufferSize > UInt(UInt16.max) ? UInt16.max : UInt16(bufferSize)
    let ipv6BufferSize = bufferSize > UInt(UInt32.max) ? UInt32.max : UInt32(bufferSize)

    if lua_type(L, 3) == LUA_TNUMBER {
        if lua_tointeger(L, 3) == 4 {
            asyncUdpSocket.setMaxReceiveIPv4BufferSize(ipv4BufferSize)
        } else if lua_tointeger(L, 3) == 6 {
            asyncUdpSocket.setMaxReceiveIPv6BufferSize(ipv6BufferSize)
        }
    } else {
        asyncUdpSocket.setMaxReceiveIPv4BufferSize(ipv4BufferSize)
        asyncUdpSocket.setMaxReceiveIPv6BufferSize(ipv6BufferSize)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:setCallback([fn]) -> self
/// Method
/// Sets the read callback for the socket.
///
/// Parameters:
///  * `fn` - An optional callback function to process data read from the socket. `nil` or no argument clears the callback. The callback receives 2 parameters:
///    * `data` - The data read from the socket as a string.
///    * `sockaddr` - The sending address as a binary socket address structure. See [`parseAddress`](#parseAddress).
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  * A callback must be set in order to read data from the socket.
///
private func socketudp_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.readCallbackRef)


    asyncUdpSocket.readCallbackRef = LUA_NOREF

    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        asyncUdpSocket.readCallbackRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:setTimeout(timeout) -> self
/// Method
/// Sets the timeout for the socket operations.
///
/// Parameters:
///  * `timeout` - A number containing the timeout duration, in seconds.
///
/// Returns:
///  * The [`hs.socket.udp`](#new) object.
///
/// Notes:
///  *  If the timeout value is negative, the operations will not use a timeout, which is the default.
///
private func socketudp_setTimeout(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)

    luaL_checktype(L, 2, LUA_TNUMBER)
    let asyncUdpSocket = getUserData(L, 1)
    asyncUdpSocket.socketTimeout = lua_tonumber(L, 2)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.socket.udp:connected() -> bool
/// Method
/// Returns the connection status of the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * `true` if connected, otherwise `false`.
///
/// Notes:
///  * UDP sockets are typically meant to be connectionless.
///  * This method will only return `true` if the [`hs.socket.udp:connect`](#connect) method has been explicitly called.
///
private func socketudp_connected(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncUdpSocket = getUserData(L, 1)

    lua_pushboolean(L, asyncUdpSocket.isConnected() ? 1 : 0)
    return 1
}

/// hs.socket.udp:closed() -> bool
/// Method
/// Returns the closed status of the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * `true` if the socket is closed, otherwise `false`.
///
/// Notes:
///  * UDP sockets are typically meant to be connectionless.
///  * Sending a packet anywhere, regardless of whether or not the destination receives it, opens the socket until it is explicitly closed.
///  * An active listening socket will not be closed, but will not be 'connected' unless the [`hs.socket.udp:connect`](#connect) method has been called.
///
private func socketudp_closed(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncUdpSocket = getUserData(L, 1)

    lua_pushboolean(L, asyncUdpSocket.isClosed() ? 1 : 0)
    return 1
}

/// hs.socket.udp:info() -> table
/// Method
/// Returns information about the socket.
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table containing the following keys:
///    * connectedAddress - `string` (`sockaddr` struct)
///    * connectedHost - `string`
///    * connectedPort - `number`
///    * isClosed - `boolean`
///    * isConnected - `boolean`
///    * isIPv4 - `boolean`
///    * isIPv4Enabled - `boolean`
///    * isIPv4Preferred - `boolean`
///    * isIPv6 - `boolean`
///    * isIPv6Enabled - `boolean`
///    * isIPv6Preferred - `boolean`
///    * isIPVersionNeutral - `boolean`
///    * localAddress - `string` (`sockaddr` struct)
///    * localAddress_IPv4 - `string` (`sockaddr` struct)
///    * localAddress_IPv6 - `string` (`sockaddr` struct)
///    * localHost - `string`
///    * localHost_IPv4 - `string`
///    * localHost_IPv6 - `string`
///    * localPort - `number`
///    * localPort_IPv4 - `number`
///    * localPort_IPv6 - `number`
///    * maxReceiveIPv4BufferSize - `number`
///    * maxReceiveIPv6BufferSize - `number`
///    * timeout - `number`
///    * userData - `string`
///
private func socketudp_info(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_checkudata(L, 1, USERDATA_TAG)
    let asyncUdpSocket = getUserData(L, 1)

    let info: NSDictionary = [
        "connectedAddress": asyncUdpSocket.connectedAddress() ?? Data(),
        "connectedHost": asyncUdpSocket.connectedHost() ?? "",
        "connectedPort": NSNumber(value: asyncUdpSocket.connectedPort()),
        "isClosed": NSNumber(value: asyncUdpSocket.isClosed()),
        "isConnected": NSNumber(value: asyncUdpSocket.isConnected()),
        "isIPv4": NSNumber(value: asyncUdpSocket.isIPv4()),
        "isIPv4Enabled": NSNumber(value: asyncUdpSocket.isIPv4Enabled()),
        "isIPv4Preferred": NSNumber(value: asyncUdpSocket.isIPv4Preferred()),
        "isIPv6": NSNumber(value: asyncUdpSocket.isIPv6()),
        "isIPv6Enabled": NSNumber(value: asyncUdpSocket.isIPv6Enabled()),
        "isIPv6Preferred": NSNumber(value: asyncUdpSocket.isIPv6Preferred()),
        "isIPVersionNeutral": NSNumber(value: asyncUdpSocket.isIPVersionNeutral()),
        "localAddress": asyncUdpSocket.localAddress() ?? Data(),
        "localAddress_IPv4": asyncUdpSocket.localAddress_IPv4() ?? Data(),
        "localAddress_IPv6": asyncUdpSocket.localAddress_IPv6() ?? Data(),
        "localHost": asyncUdpSocket.localHost() ?? "",
        "localHost_IPv4": asyncUdpSocket.localHost_IPv4() ?? "",
        "localHost_IPv6": asyncUdpSocket.localHost_IPv6() ?? "",
        "localPort": NSNumber(value: asyncUdpSocket.localPort()),
        "localPort_IPv4": NSNumber(value: asyncUdpSocket.localPort_IPv4()),
        "localPort_IPv6": NSNumber(value: asyncUdpSocket.localPort_IPv6()),
        "maxReceiveIPv4BufferSize": NSNumber(value: asyncUdpSocket.maxReceiveIPv4BufferSize()),
        "maxReceiveIPv6BufferSize": NSNumber(value: asyncUdpSocket.maxReceiveIPv6BufferSize()),
        "timeout": NSNumber(value: asyncUdpSocket.socketTimeout),
        "userData": asyncUdpSocket.userData() ?? "",
    ]

    lua_pushany(L, info)
    return 1
}

// MARK: - Library Registration Functions

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let asyncUdpSocket = getUserData(L, 1)

    let isServer = asyncUdpSocket.userData() as? NSString == SERVER
    let theHost = isServer ? asyncUdpSocket.localHost() : asyncUdpSocket.connectedHost()
    let thePort = isServer ? asyncUdpSocket.localPort() : asyncUdpSocket.connectedPort()

    lua_pushstring(L, "\(USERDATA_TAG): \(theHost ?? ""):\(thePort) (\(lua_topointer(L, 1)!))")
    return 1
}

private func userdata_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: AsyncSocketUserData.self)
    let asyncUdpSocket: HSAsyncUdpSocket = Unmanaged.fromOpaque(userData.pointee.asyncSocket!).takeRetainedValue()
    userData.pointee.asyncSocket = nil

    asyncUdpSocket.close()
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.readCallbackRef)

    asyncUdpSocket.readCallbackRef = LUA_NOREF
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.writeCallbackRef)

    asyncUdpSocket.writeCallbackRef = LUA_NOREF
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, asyncUdpSocket.connectCallbackRef)

    asyncUdpSocket.connectCallbackRef = LUA_NOREF

    return 0
}

private func meta_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return 0
}

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: socketudp_new),
    luaL_Reg(name: nil, func: nil),
]

// Metatable for created objects when _new invoked
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("connect"), func: socketudp_connect),
    luaL_Reg(name: strdup("listen"), func: socketudp_listen),
    luaL_Reg(name: strdup("close"), func: socketudp_close),
    luaL_Reg(name: strdup("pause"), func: socketudp_pause),
    luaL_Reg(name: strdup("receive"), func: socketudp_receive),
    luaL_Reg(name: strdup("receiveOne"), func: socketudp_receiveOne),
    luaL_Reg(name: strdup("send"), func: socketudp_send),
    luaL_Reg(name: strdup("broadcast"), func: socketudp_enableBroadcast),
    luaL_Reg(name: strdup("reusePort"), func: socketudp_enableReusePort),
    luaL_Reg(name: strdup("enableIPv"), func: socketudp_enableIPversion),
    luaL_Reg(name: strdup("preferIPv"), func: socketudp_preferIPversion),
    luaL_Reg(name: strdup("setBufferSize"), func: socketudp_setReceiveBufferSize),
    luaL_Reg(name: strdup("setCallback"), func: socketudp_setCallback),
    luaL_Reg(name: strdup("setTimeout"), func: socketudp_setTimeout),
    luaL_Reg(name: strdup("connected"), func: socketudp_connected),
    luaL_Reg(name: strdup("closed"), func: socketudp_closed),
    luaL_Reg(name: strdup("info"), func: socketudp_info),
    luaL_Reg(name: strdup("__tostring"), func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"), func: userdata_gc),
    luaL_Reg(name: nil, func: nil),
]

private var meta_gcLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: meta_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libsocketudp")
public func luaopen_hs_libsocketudp(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")
    luaL_setfuncs(L, &userdata_metaLib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(moduleLib.count - 1))
    luaL_setfuncs(L, &moduleLib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(meta_gcLib.count - 1))
    luaL_setfuncs(L, &meta_gcLib, 0)
    lua_setmetatable(L, -2)

    return 1
}
