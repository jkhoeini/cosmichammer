// Copyright (C) 2016 Apple Inc. All Rights Reserved.
// See LICENSE.txt for this sample's licensing information
//
// Swift port of Apple's SimplePing sample.

import Foundation
import Darwin

// MARK: - ICMP On-The-Wire Format

struct ICMPHeader {
    var type: UInt8
    var code: UInt8
    var checksum: UInt16
    var identifier: UInt16
    var sequenceNumber: UInt16
}

let ICMPv4TypeEchoRequest: UInt8 = 8
let ICMPv4TypeEchoReply:   UInt8 = 0
let ICMPv6TypeEchoRequest: UInt8 = 128
let ICMPv6TypeEchoReply:   UInt8 = 129

let kICMPHeaderSize = 8 // MemoryLayout<ICMPHeader>.size

// MARK: - IPv4 Header

private struct IPv4Header {
    var versionAndHeaderLength: UInt8
    var differentiatedServices: UInt8
    var totalLength: UInt16
    var identification: UInt16
    var flagsAndFragmentOffset: UInt16
    var timeToLive: UInt8
    var protocolField: UInt8
    var headerChecksum: UInt16
    var sourceAddress: (UInt8, UInt8, UInt8, UInt8)
    var destinationAddress: (UInt8, UInt8, UInt8, UInt8)
}

// MARK: - Checksum

private func inCksum(_ data: Data) -> UInt16 {
    var sum: Int32 = 0
    var index = data.startIndex

    while index < data.endIndex - 1 {
        let word = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
        sum += Int32(word)
        index += 2
    }

    if index < data.endIndex {
        sum += Int32(data[index])
    }

    sum = (sum >> 16) + (sum & 0xFFFF)
    sum += (sum >> 16)
    return UInt16(truncatingIfNeeded: ~sum)
}

// MARK: - SimplePingAddressStyle

enum SimplePingAddressStyle: Int {
    case any = 0
    case ICMPv4
    case ICMPv6
}

// MARK: - SimplePingDelegate

protocol SimplePingDelegate: AnyObject {
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data)
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error)
    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16)
    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error)
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16)
    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data)
}

// Default implementations (all optional)
extension SimplePingDelegate {
    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {}
    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {}
    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16) {}
    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error) {}
    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16) {}
    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {}
}

// MARK: - SimplePing

class SimplePing: NSObject {
    let hostName: String
    let identifier: UInt16
    weak var delegate: SimplePingDelegate?
    var addressStyle: SimplePingAddressStyle = .any

    private(set) var hostAddress: Data?
    private(set) var nextSequenceNumber: UInt16 = 0
    private var nextSequenceNumberHasWrapped = false

    private var host: CFHost?
    var socket: CFSocket?

    var hostAddressFamily: sa_family_t {
        guard let addr = hostAddress, addr.count >= MemoryLayout<sockaddr>.size else {
            return sa_family_t(AF_UNSPEC)
        }
        return addr.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }
    }

    init(hostName: String) {
        self.hostName = hostName
        self.identifier = UInt16(arc4random() & 0xFFFF)
    }

    deinit {
        stop()
        assert(host == nil)
        assert(socket == nil)
    }

    // MARK: - Public API

    func start() {
        assert(host == nil)
        assert(hostAddress == nil)

        let hostRef = CFHostCreateWithName(nil, hostName as CFString).takeRetainedValue()
        self.host = hostRef

        var context = CFHostClientContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        CFHostSetClient(hostRef, hostResolveCallback, &context)
        CFHostScheduleWithRunLoop(hostRef, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        var streamError = CFStreamError()
        let success = CFHostStartInfoResolution(hostRef, .addresses, &streamError)
        if !success {
            didFail(withHostStreamError: streamError)
        }
    }

    func sendPing(with data: Data?) {
        assert(hostAddress != nil)

        let payload: Data
        if let data = data {
            payload = data
        } else {
            let n = 99 - Int(nextSequenceNumber % 100)
            let str = String(format: "%28zd bottles of beer on the wall", n)
            payload = str.data(using: .ascii)!
            assert(payload.count == 56)
        }

        let packet: Data
        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            packet = pingPacket(type: ICMPv4TypeEchoRequest, payload: payload, requiresChecksum: true)
        case sa_family_t(AF_INET6):
            packet = pingPacket(type: ICMPv6TypeEchoRequest, payload: payload, requiresChecksum: false)
        default:
            fatalError("unexpected host address family")
        }

        var bytesSent: Int = -1
        var err: Int32 = 0

        if socket == nil {
            bytesSent = -1
            err = EBADF
        } else {
            bytesSent = hostAddress!.withUnsafeBytes { addrBuf in
                packet.withUnsafeBytes { pktBuf in
                    sendto(
                        CFSocketGetNative(socket),
                        pktBuf.baseAddress,
                        packet.count,
                        0,
                        addrBuf.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                        socklen_t(hostAddress!.count)
                    )
                }
            }
            if bytesSent < 0 {
                err = errno
            }
        }

        if bytesSent > 0 && bytesSent == packet.count {
            delegate?.simplePing(self, didSendPacket: packet, sequenceNumber: nextSequenceNumber)
        } else {
            if err == 0 { err = ENOBUFS }
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil)
            delegate?.simplePing(self, didFailToSendPacket: packet, sequenceNumber: nextSequenceNumber, error: error)
        }

        nextSequenceNumber &+= 1
        if nextSequenceNumber == 0 {
            nextSequenceNumberHasWrapped = true
        }
    }

    func stop() {
        stopHostResolution()
        stopSocket()
        hostAddress = nil
    }

    // MARK: - Packet building

    private func pingPacket(type: UInt8, payload: Data, requiresChecksum: Bool) -> Data {
        var packet = Data(count: kICMPHeaderSize + payload.count)

        packet[0] = type
        packet[1] = 0 // code
        packet[2] = 0; packet[3] = 0 // checksum placeholder
        let idBE = identifier.bigEndian
        packet[4] = UInt8(idBE & 0xFF)
        packet[5] = UInt8(idBE >> 8)
        let seqBE = nextSequenceNumber.bigEndian
        packet[6] = UInt8(seqBE & 0xFF)
        packet[7] = UInt8(seqBE >> 8)
        packet.replaceSubrange(kICMPHeaderSize..<kICMPHeaderSize + payload.count, with: payload)

        if requiresChecksum {
            let cs = inCksum(packet)
            packet[2] = UInt8(cs & 0xFF)
            packet[3] = UInt8(cs >> 8)
        }

        return packet
    }

    // MARK: - Validation

    private static func icmpHeaderOffset(inIPv4Packet packet: Data) -> Int? {
        let ipHeaderMinSize = MemoryLayout<IPv4Header>.size
        guard packet.count >= ipHeaderMinSize + kICMPHeaderSize else { return nil }

        return packet.withUnsafeBytes { buf -> Int? in
            let vhl = buf.load(as: UInt8.self)
            let proto = buf.load(fromByteOffset: 9, as: UInt8.self)
            guard (vhl & 0xF0) == 0x40, proto == UInt8(IPPROTO_ICMP) else { return nil }
            let headerLength = Int(vhl & 0x0F) * MemoryLayout<UInt32>.size
            guard packet.count >= headerLength + kICMPHeaderSize else { return nil }
            return headerLength
        }
    }

    private func validateSequenceNumber(_ sequenceNumber: UInt16) -> Bool {
        if nextSequenceNumberHasWrapped {
            return (nextSequenceNumber &- sequenceNumber) < 120
        } else {
            return sequenceNumber < nextSequenceNumber
        }
    }

    private func readICMPHeader(from data: Data, at offset: Int) -> ICMPHeader {
        var hdr = ICMPHeader(type: 0, code: 0, checksum: 0, identifier: 0, sequenceNumber: 0)
        data.withUnsafeBytes { buf in
            let src = buf.baseAddress!.advanced(by: offset)
            withUnsafeMutableBytes(of: &hdr) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src, count: kICMPHeaderSize))
            }
        }
        return hdr
    }

    private func validatePing4Response(_ packet: inout Data) -> UInt16? {
        guard let icmpOffset = SimplePing.icmpHeaderOffset(inIPv4Packet: packet) else { return nil }

        let icmp = readICMPHeader(from: packet, at: icmpOffset)

        // Verify checksum
        var temp = packet
        temp[icmpOffset + 2] = 0
        temp[icmpOffset + 3] = 0
        let calculated = inCksum(Data(temp[icmpOffset...]))
        guard icmp.checksum == calculated else { return nil }

        guard icmp.type == ICMPv4TypeEchoReply, icmp.code == 0 else { return nil }
        guard UInt16(bigEndian: icmp.identifier) == identifier else { return nil }
        let seq = UInt16(bigEndian: icmp.sequenceNumber)
        guard validateSequenceNumber(seq) else { return nil }

        packet.removeSubrange(0..<icmpOffset)
        return seq
    }

    private func validatePing6Response(_ packet: Data) -> UInt16? {
        guard packet.count >= kICMPHeaderSize else { return nil }

        let icmp = readICMPHeader(from: packet, at: 0)

        guard icmp.type == ICMPv6TypeEchoReply, icmp.code == 0 else { return nil }
        guard UInt16(bigEndian: icmp.identifier) == identifier else { return nil }
        let seq = UInt16(bigEndian: icmp.sequenceNumber)
        guard validateSequenceNumber(seq) else { return nil }
        return seq
    }

    private func validatePingResponse(_ packet: inout Data) -> UInt16? {
        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            return validatePing4Response(&packet)
        case sa_family_t(AF_INET6):
            return validatePing6Response(packet)
        default:
            return nil
        }
    }

    // MARK: - Socket I/O

    fileprivate func readData() {
        let bufferSize = 65535
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }

        var addr = sockaddr_storage()
        var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let bytesRead = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(CFSocketGetNative(socket), buffer, bufferSize, 0, sa, &addrLen)
            }
        }

        if bytesRead > 0 {
            var packet = Data(bytes: buffer, count: bytesRead)
            if let seq = validatePingResponse(&packet) {
                delegate?.simplePing(self, didReceivePingResponsePacket: packet, sequenceNumber: seq)
            } else {
                let raw = Data(bytes: buffer, count: bytesRead)
                delegate?.simplePing(self, didReceiveUnexpectedPacket: raw)
            }
        } else {
            var err = errno
            if bytesRead == 0 { err = EPIPE }
            didFail(withError: NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil))
        }
    }

    // MARK: - Startup

    private func startWithHostAddress() {
        assert(hostAddress != nil)

        var fd: Int32 = -1
        var err: Int32 = 0

        switch hostAddressFamily {
        case sa_family_t(AF_INET):
            fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
            if fd < 0 { err = errno }
        case sa_family_t(AF_INET6):
            fd = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
            if fd < 0 { err = errno }
        default:
            err = EPROTONOSUPPORT
        }

        if err != 0 {
            didFail(withError: NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: nil))
        } else {
            var context = CFSocketContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let cfSocket = CFSocketCreateWithNative(nil, fd, CFSocketCallBackType.readCallBack.rawValue, socketReadCallback, &context)!
            self.socket = cfSocket

            assert(CFSocketGetSocketFlags(cfSocket) & kCFSocketCloseOnInvalidate != 0)

            let rls = CFSocketCreateRunLoopSource(nil, cfSocket, 0)!
            CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .defaultMode)

            delegate?.simplePing(self, didStartWithAddress: hostAddress!)
        }
    }

    fileprivate func hostResolutionDone() {
        guard let hostRef = host else { return }

        var resolved: DarwinBoolean = false
        guard let addresses = CFHostGetAddressing(hostRef, &resolved)?.takeUnretainedValue() as? [Data],
              resolved.boolValue else {
            stopHostResolution()
            didFail(withError: NSError(domain: kCFErrorDomainCFNetwork as String,
                                       code: Int(CFNetworkErrors.cfHostErrorHostNotFound.rawValue),
                                       userInfo: nil))
            return
        }

        var found = false
        for address in addresses {
            guard address.count >= MemoryLayout<sockaddr>.size else { continue }
            let family = address.withUnsafeBytes { $0.load(as: sockaddr.self).sa_family }

            switch family {
            case sa_family_t(AF_INET) where addressStyle != .ICMPv6:
                hostAddress = address
                found = true
            case sa_family_t(AF_INET6) where addressStyle != .ICMPv4:
                hostAddress = address
                found = true
            default:
                break
            }
            if found { break }
        }

        stopHostResolution()

        if found {
            startWithHostAddress()
        } else {
            didFail(withError: NSError(domain: kCFErrorDomainCFNetwork as String,
                                       code: Int(CFNetworkErrors.cfHostErrorHostNotFound.rawValue),
                                       userInfo: nil))
        }
    }

    // MARK: - Error handling

    private func didFail(withError error: Error) {
        // Prevent dealloc during delegate callback
        let selfRetain = self
        _ = selfRetain

        stop()
        delegate?.simplePing(self, didFailWithError: error)
    }

    fileprivate func didFail(withHostStreamError streamError: CFStreamError) {
        var userInfo: [String: Any]?
        if streamError.domain == Int(kCFStreamErrorDomainNetDB) {
            userInfo = [kCFGetAddrInfoFailureKey as String: NSNumber(value: streamError.error)]
        }
        let error = NSError(domain: kCFErrorDomainCFNetwork as String,
                            code: Int(CFNetworkErrors.cfHostErrorUnknown.rawValue),
                            userInfo: userInfo)
        didFail(withError: error)
    }

    // MARK: - Teardown

    private func stopHostResolution() {
        if let hostRef = host {
            CFHostSetClient(hostRef, nil, nil)
            CFHostUnscheduleFromRunLoop(hostRef, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            host = nil
        }
    }

    private func stopSocket() {
        if let s = socket {
            let fd = CFSocketGetNative(s)
            let autoClose = CFSocketGetSocketFlags(s) & kCFSocketCloseOnInvalidate != 0
            CFSocketInvalidate(s)
            if !autoClose && fd >= 0 {
                close(fd)
            }
            socket = nil
        }
    }
}

// MARK: - C callbacks

private func socketReadCallback(_ s: CFSocket?, _ type: CFSocketCallBackType, _ address: CFData?, _ data: UnsafeRawPointer?, _ info: UnsafeMutableRawPointer?) {
    guard let info = info else { return }
    let obj = Unmanaged<SimplePing>.fromOpaque(info).takeUnretainedValue()
    obj.readData()
}

private func hostResolveCallback(_ host: CFHost, _ typeInfo: CFHostInfoType, _ error: UnsafePointer<CFStreamError>?, _ info: UnsafeMutableRawPointer?) {
    guard let info = info else { return }
    let obj = Unmanaged<SimplePing>.fromOpaque(info).takeUnretainedValue()
    if let error = error, error.pointee.domain != 0 {
        obj.didFail(withHostStreamError: error.pointee)
    } else {
        obj.hostResolutionDone()
    }
}
