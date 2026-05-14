/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample's licensing information

    Abstract:
    An object wrapper around the low-level BSD Sockets ping function.
 */

import Foundation

// MARK: - Address Style Enum

/// Controls the IP address version used by SimplePingSwift instances.
@objc public enum SimplePingAddressStyleSwift: Int {
    case any     = 0   /// Use the first IPv4 or IPv6 address found; the default.
    case icmpv4  = 1   /// Use the first IPv4 address found.
    case icmpv6  = 2   /// Use the first IPv6 address found.
}

// MARK: - ICMP Header

/// Describes the on-the-wire header format for an ICMP ping.
/// Both IPv4 and IPv6 use the same basic structure.
public struct ICMPHeaderSwift {
    public var type: UInt8
    public var code: UInt8
    public var checksum: UInt16
    public var identifier: UInt16
    public var sequenceNumber: UInt16
}

public let ICMPv4TypeEchoRequest: UInt8 = 8
public let ICMPv4TypeEchoReply: UInt8   = 0
public let ICMPv6TypeEchoRequest: UInt8 = 128
public let ICMPv6TypeEchoReply: UInt8   = 129

// MARK: - IPv4 Header

/// Describes the on-the-wire header format for an IPv4 packet.
private struct IPv4Header {
    var versionAndHeaderLength: UInt8
    var differentiatedServices: UInt8
    var totalLength: UInt16
    var identification: UInt16
    var flagsAndFragmentOffset: UInt16
    var timeToLive: UInt8
    var `protocol`: UInt8
    var headerChecksum: UInt16
    var sourceAddress: (UInt8, UInt8, UInt8, UInt8)
    var destinationAddress: (UInt8, UInt8, UInt8, UInt8)
}

// MARK: - Checksum

/// Calculates an IP checksum.
/// This is the standard BSD checksum code, modified to use modern types.
private func in_cksum(_ buffer: UnsafeRawPointer, _ bufferLen: Int) -> UInt16 {
    var bytesLeft = bufferLen
    var sum: Int32 = 0
    var cursor = buffer.assumingMemoryBound(to: UInt16.self)

    // Our algorithm is simple, using a 32 bit accumulator (sum), we add
    // sequential 16 bit words to it, and at the end, fold back all the
    // carry bits from the top 16 bits into the lower 16 bits.
    while bytesLeft > 1 {
        sum += Int32(cursor.pointee)
        cursor = cursor.advanced(by: 1)
        bytesLeft -= 2
    }

    // mop up an odd byte, if necessary
    if bytesLeft == 1 {
        var last: UInt16 = 0
        withUnsafeMutableBytes(of: &last) { lastPtr in
            lastPtr[0] = UnsafeRawPointer(cursor).assumingMemoryBound(to: UInt8.self).pointee
            lastPtr[1] = 0
        }
        sum += Int32(last)
    }

    // add back carry outs from top 16 bits to low 16 bits
    sum = (sum >> 16) + (sum & 0xffff)  // add hi 16 to low 16
    sum += (sum >> 16)                   // add carry
    let answer = UInt16(truncatingIfNeeded: ~sum)

    return answer
}

// MARK: - Delegate Protocol

/// A delegate protocol for the SimplePingSwift class.
@objc public protocol SimplePingSwiftDelegate: AnyObject {
    @objc optional func simplePing(_ pinger: SimplePingSwift, didStartWithAddress address: Data)
    @objc optional func simplePing(_ pinger: SimplePingSwift, didFailWithError error: Error)
    @objc optional func simplePing(_ pinger: SimplePingSwift, didSendPacket packet: Data, sequenceNumber: UInt16)
    @objc optional func simplePing(_ pinger: SimplePingSwift, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error)
    @objc optional func simplePing(_ pinger: SimplePingSwift, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16)
    @objc optional func simplePing(_ pinger: SimplePingSwift, didReceiveUnexpectedPacket packet: Data)
}

// MARK: - SimplePingSwift

/// An object wrapper around the low-level BSD Sockets ping function.
///
/// To use the class create an instance, set the delegate and call `start()`
/// to start the instance on the current run loop. If things go well you'll
/// soon get the `simplePing(_:didStartWithAddress:)` delegate callback.
/// From there you can call `sendPing(with:)` to send a ping and you'll
/// receive the `simplePing(_:didReceivePingResponsePacket:sequenceNumber:)`
/// and `simplePing(_:didReceiveUnexpectedPacket:)` delegate callbacks as
/// ICMP packets arrive.
///
/// The class can be used from any thread but the use of any single instance
/// must be confined to a specific thread and that thread must run its run loop.
@objc public class SimplePingSwift: NSObject {

    // MARK: Public Properties

    /// A copy of the value passed to `init(hostName:)`.
    @objc public let hostName: String

    /// The delegate for this object.
    @objc public weak var delegate: SimplePingSwiftDelegate?

    /// Controls the IP address version used by the object.
    @objc public var addressStyle: SimplePingAddressStyleSwift = .any

    /// The address being pinged.
    @objc public private(set) var hostAddress: Data?

    /// The address family for `hostAddress`, or `AF_UNSPEC` if that's nil.
    @objc public var hostAddressFamily: sa_family_t {
        guard let hostAddress = hostAddress, hostAddress.count >= MemoryLayout<sockaddr>.size else {
            return sa_family_t(AF_UNSPEC)
        }
        return hostAddress.withUnsafeBytes { rawPtr -> sa_family_t in
            rawPtr.load(as: sockaddr.self).sa_family
        }
    }

    /// The identifier used by pings by this object.
    @objc public let identifier: UInt16

    /// The next sequence number to be used by this object.
    @objc public private(set) var nextSequenceNumber: UInt16 = 0

    // MARK: Private Properties

    private var nextSequenceNumberHasWrapped = false
    private var host: CFHost?
    private var _socket: CFSocket?

    // MARK: Init

    @objc public init(hostName: String) {
        precondition(!hostName.isEmpty)
        self.hostName = hostName
        self.identifier = UInt16(arc4random() & 0xFFFF)
        super.init()
    }

    deinit {
        stop()
        assert(host == nil)
        assert(_socket == nil)
    }

    // MARK: - Failure Handling

    /// Shuts down the pinger object and tell the delegate about the error.
    private func didFail(with error: Error) {
        // We retain ourselves temporarily because it's common for the delegate method
        // to release its last reference to us, which causes deinit to be called here.
        let _ = Unmanaged.passRetained(self).autorelease()

        stop()
        delegate?.simplePing?(self, didFailWithError: error)
    }

    /// Shuts down the pinger object and tell the delegate about the error.
    /// This converts the CFStreamError to an NSError and then calls through to
    /// didFail(with:) to do the real work.
    private func didFail(with streamError: CFStreamError) {
        var userInfo: [String: Any]?
        if streamError.domain == CFStreamErrorDomain(kCFStreamErrorDomainNetDB) {
            userInfo = [kCFGetAddrInfoFailureKey as String: streamError.error]
        }
        let error = NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfHostErrorUnknown.rawValue), userInfo: userInfo)
        didFail(with: error)
    }

    // MARK: - Ping Packet Construction

    /// Builds a ping packet from the supplied parameters.
    private func pingPacket(type: UInt8, payload: Data, requiresChecksum: Bool) -> Data {
        var packet = Data(count: MemoryLayout<ICMPHeaderSwift>.size + payload.count)

        packet.withUnsafeMutableBytes { rawPtr in
            let icmpPtr = rawPtr.baseAddress!.assumingMemoryBound(to: ICMPHeaderSwift.self)
            icmpPtr.pointee.type = type
            icmpPtr.pointee.code = 0
            icmpPtr.pointee.checksum = 0
            icmpPtr.pointee.identifier = CFSwapInt16HostToBig(identifier)
            icmpPtr.pointee.sequenceNumber = CFSwapInt16HostToBig(nextSequenceNumber)

            // Copy payload after the header
            let payloadDst = rawPtr.baseAddress!.advanced(by: MemoryLayout<ICMPHeaderSwift>.size)
            payload.withUnsafeBytes { payloadSrc in
                if let src = payloadSrc.baseAddress {
                    payloadDst.copyMemory(from: src, byteCount: payload.count)
                }
            }
        }

        if requiresChecksum {
            let checksum = packet.withUnsafeBytes { rawPtr in
                in_cksum(rawPtr.baseAddress!, packet.count)
            }
            packet.withUnsafeMutableBytes { rawPtr in
                let icmpPtr = rawPtr.baseAddress!.assumingMemoryBound(to: ICMPHeaderSwift.self)
                icmpPtr.pointee.checksum = checksum
            }
        }

        return packet
    }

    // MARK: - Send Ping

    @objc public func sendPing(with data: Data?) {
        precondition(hostAddress != nil) // gotta wait for simplePing:didStartWithAddress:

        var payload: Data
        if let data = data {
            payload = data
        } else {
            let bottles = 99 - Int(nextSequenceNumber % 100)
            let msg = String(format: "%28zd bottles of beer on the wall", bottles)
            payload = msg.data(using: .ascii)!
            assert(payload.count == 56)
        }

        let packet: Data
        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            packet = pingPacket(type: ICMPv4TypeEchoRequest, payload: payload, requiresChecksum: true)
        case sa_family_t(AF_INET6):
            packet = pingPacket(type: ICMPv6TypeEchoRequest, payload: payload, requiresChecksum: false)
        default:
            assertionFailure()
            return
        }

        // Send the packet.
        let bytesSent: ssize_t
        var err: Int32 = 0

        if _socket == nil {
            bytesSent = -1
            err = EBADF
        } else {
            bytesSent = packet.withUnsafeBytes { packetPtr in
                hostAddress!.withUnsafeBytes { addrPtr in
                    sendto(
                        CFSocketGetNative(_socket!),
                        packetPtr.baseAddress!,
                        packet.count,
                        0,
                        addrPtr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                        socklen_t(hostAddress!.count)
                    )
                }
            }
            if bytesSent < 0 {
                err = errno
            }
        }

        // Handle the results of the send.
        if bytesSent > 0 && bytesSent == packet.count {
            delegate?.simplePing?(self, didSendPacket: packet, sequenceNumber: nextSequenceNumber)
        } else {
            if err == 0 {
                err = ENOBUFS
            }
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
            delegate?.simplePing?(self, didFailToSendPacket: packet, sequenceNumber: nextSequenceNumber, error: error)
        }

        nextSequenceNumber &+= 1
        if nextSequenceNumber == 0 {
            nextSequenceNumberHasWrapped = true
        }
    }

    // MARK: - Packet Validation

    /// Calculates the offset of the ICMP header within an IPv4 packet.
    private class func icmpHeaderOffset(in packet: Data) -> Int? {
        guard packet.count >= (MemoryLayout<IPv4Header>.size + MemoryLayout<ICMPHeaderSwift>.size) else { return nil }

        return packet.withUnsafeBytes { rawPtr -> Int? in
            let ipPtr = rawPtr.baseAddress!.assumingMemoryBound(to: IPv4Header.self)
            guard (ipPtr.pointee.versionAndHeaderLength & 0xF0) == 0x40, // IPv4
                  ipPtr.pointee.protocol == UInt8(IPPROTO_ICMP) else { return nil }

            let ipHeaderLength = Int(ipPtr.pointee.versionAndHeaderLength & 0x0F) * MemoryLayout<UInt32>.size
            guard packet.count >= (ipHeaderLength + MemoryLayout<ICMPHeaderSwift>.size) else { return nil }

            return ipHeaderLength
        }
    }

    /// Checks whether the specified sequence number is one we sent.
    private func validateSequenceNumber(_ sequenceNumber: UInt16) -> Bool {
        if nextSequenceNumberHasWrapped {
            return (nextSequenceNumber &- sequenceNumber) < 120
        } else {
            return sequenceNumber < nextSequenceNumber
        }
    }

    /// Checks whether an incoming IPv4 packet looks like a ping response.
    private func validatePing4ResponsePacket(_ packet: inout Data, sequenceNumber: inout UInt16) -> Bool {
        guard let icmpHeaderOffset = SimplePingSwift.icmpHeaderOffset(in: packet) else { return false }

        return packet.withUnsafeMutableBytes { rawPtr -> Bool in
            let icmpPtr = rawPtr.baseAddress!.advanced(by: icmpHeaderOffset).assumingMemoryBound(to: ICMPHeaderSwift.self)

            let receivedChecksum = icmpPtr.pointee.checksum
            icmpPtr.pointee.checksum = 0
            let calculatedChecksum = in_cksum(UnsafeRawPointer(icmpPtr), rawPtr.count - icmpHeaderOffset)
            icmpPtr.pointee.checksum = receivedChecksum

            guard receivedChecksum == calculatedChecksum else { return false }
            guard icmpPtr.pointee.type == ICMPv4TypeEchoReply && icmpPtr.pointee.code == 0 else { return false }
            guard CFSwapInt16BigToHost(icmpPtr.pointee.identifier) == self.identifier else { return false }

            let seq = CFSwapInt16BigToHost(icmpPtr.pointee.sequenceNumber)
            guard self.validateSequenceNumber(seq) else { return false }

            sequenceNumber = seq
            return true
        }

        // Note: In the ObjC version, the IPv4 header bytes are removed from packet.
        // We handle that after this method returns.
    }

    /// Checks whether an incoming IPv6 packet looks like a ping response.
    private func validatePing6ResponsePacket(_ packet: Data, sequenceNumber: inout UInt16) -> Bool {
        guard packet.count >= MemoryLayout<ICMPHeaderSwift>.size else { return false }

        return packet.withUnsafeBytes { rawPtr -> Bool in
            let icmpPtr = rawPtr.baseAddress!.assumingMemoryBound(to: ICMPHeaderSwift.self)

            guard icmpPtr.pointee.type == ICMPv6TypeEchoReply && icmpPtr.pointee.code == 0 else { return false }
            guard CFSwapInt16BigToHost(icmpPtr.pointee.identifier) == self.identifier else { return false }

            let seq = CFSwapInt16BigToHost(icmpPtr.pointee.sequenceNumber)
            guard self.validateSequenceNumber(seq) else { return false }

            sequenceNumber = seq
            return true
        }
    }

    /// Checks whether an incoming packet looks like a ping response.
    private func validatePingResponsePacket(_ packet: inout Data, sequenceNumber: inout UInt16) -> Bool {
        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            if validatePing4ResponsePacket(&packet, sequenceNumber: &sequenceNumber) {
                // Remove the IPv4 header
                if let offset = SimplePingSwift.icmpHeaderOffset(in: packet) {
                    packet.removeSubrange(0..<offset)
                }
                return true
            }
            return false
        case sa_family_t(AF_INET6):
            return validatePing6ResponsePacket(packet, sequenceNumber: &sequenceNumber)
        default:
            assertionFailure()
            return false
        }
    }

    // MARK: - Read Data

    /// Reads data from the ICMP socket.
    private func readData() {
        let kBufferSize = 65535
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: kBufferSize, alignment: 1)
        defer { buffer.deallocate() }

        var addr = sockaddr_storage()
        var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let bytesRead = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                recvfrom(CFSocketGetNative(_socket!), buffer, kBufferSize, 0, sockaddrPtr, &addrLen)
            }
        }

        var err: Int32 = 0
        if bytesRead < 0 {
            err = errno
        }

        if bytesRead > 0 {
            var packet = Data(bytes: buffer, count: Int(bytesRead))
            var sequenceNumber: UInt16 = 0

            if validatePingResponsePacket(&packet, sequenceNumber: &sequenceNumber) {
                delegate?.simplePing?(self, didReceivePingResponsePacket: packet, sequenceNumber: sequenceNumber)
            } else {
                delegate?.simplePing?(self, didReceiveUnexpectedPacket: packet)
            }
        } else {
            if err == 0 { err = EPIPE }
            didFail(with: NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil))
        }
    }

    // MARK: - Socket Callback

    /// The callback for our CFSocket object.
    private static let socketReadCallback: CFSocketCallBack = { s, callbackType, address, data, info in
        guard let info = info else { return }
        let obj = Unmanaged<SimplePingSwift>.fromOpaque(info).takeUnretainedValue()
        assert(s === obj._socket)
        assert(callbackType == .readCallBack)
        obj.readData()
    }

    // MARK: - Start With Host Address

    /// Starts the send and receive infrastructure.
    private func startWithHostAddress() {
        assert(hostAddress != nil)

        var err: Int32 = 0
        var fd: Int32 = -1

        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            if fd < 0 { err = errno }
        case sa_family_t(AF_INET6):
            fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
            if fd < 0 { err = errno }
        default:
            err = EPROTONOSUPPORT
        }

        if err != 0 {
            didFail(with: NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil))
        } else {
            var context = CFSocketContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)

            _socket = CFSocketCreateWithNative(nil, fd, CFSocketCallBackType.readCallBack.rawValue, SimplePingSwift.socketReadCallback, &context)
            assert(_socket != nil)

            // The socket will now take care of cleaning up our file descriptor.
            assert(CFSocketGetSocketFlags(_socket!) & kCFSocketCloseOnInvalidate != 0)
            fd = -1

            let rls = CFSocketCreateRunLoopSource(nil, _socket!, 0)!
            CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .defaultMode)

            delegate?.simplePing?(self, didStartWithAddress: hostAddress!)
        }
        assert(fd == -1)
    }

    // MARK: - Host Resolution

    /// Processes the results of our name-to-address resolution.
    private func hostResolutionDone() {
        var resolved: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(host!, &resolved)?.takeUnretainedValue() as? [Data],
              resolved.boolValue else {
            stopHostResolution()
            didFail(with: NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfHostErrorHostNotFound.rawValue), userInfo: nil))
            return
        }

        var foundAddress = false
        for address in addresses {
            guard address.count >= MemoryLayout<sockaddr>.size else { continue }
            let family = address.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }
            switch family {
            case sa_family_t(AF_INET):
                if addressStyle != .icmpv6 {
                    hostAddress = address
                    foundAddress = true
                }
            case sa_family_t(AF_INET6):
                if addressStyle != .icmpv4 {
                    hostAddress = address
                    foundAddress = true
                }
            default:
                break
            }
            if foundAddress { break }
        }

        stopHostResolution()

        if foundAddress {
            startWithHostAddress()
        } else {
            didFail(with: NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfHostErrorHostNotFound.rawValue), userInfo: nil))
        }
    }

    /// The callback for our CFHost object.
    private static let hostResolveCallback: CFHostClientCallBack = { theHost, typeInfo, error, info in
        guard let info = info else { return }
        let obj = Unmanaged<SimplePingSwift>.fromOpaque(info).takeUnretainedValue()
        assert(theHost === obj.host!)
        assert(typeInfo == .addresses)

        if let error = error, error.pointee.domain != 0 {
            obj.didFail(with: error.pointee)
        } else {
            obj.hostResolutionDone()
        }
    }

    // MARK: - Public Start/Stop

    @objc public func start() {
        assert(host == nil)
        assert(hostAddress == nil)

        host = CFHostCreateWithName(nil, hostName as CFString).takeRetainedValue()
        assert(host != nil)

        var context = CFHostClientContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        CFHostSetClient(host!, SimplePingSwift.hostResolveCallback, &context)
        CFHostScheduleWithRunLoop(host!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)

        var streamError = CFStreamError()
        let success = CFHostStartInfoResolution(host!, .addresses, &streamError)
        if !success {
            didFail(with: streamError)
        }
    }

    /// Stops the name-to-address resolution infrastructure.
    private func stopHostResolution() {
        if let host = host {
            CFHostSetClient(host, nil, nil)
            CFHostUnscheduleFromRunLoop(host, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue)
            self.host = nil
        }
    }

    /// Stops the send and receive infrastructure.
    private func stopSocket() {
        if let socket = _socket {
            CFSocketInvalidate(socket)
            _socket = nil
        }
    }

    @objc public func stop() {
        stopHostResolution()
        stopSocket()
        hostAddress = nil
    }
}
