
/// === hs.network.ping.echoRequest ===
///
/// Provides lower-level access to the ICMP Echo Request infrastructure used by the hs.network.ping module. In general, you should not need to use this module directly unless you have specific requirements not met by the hs.network.ping module and the `hs.network.ping` object methods.
///
/// This module is based heavily on Apple's SimplePing sample project which can be found at https://developer.apple.com/library/content/samplecode/SimplePing/Introduction/Intro.html.
///
/// When a callback function argument is specified as an ICMP table, the Lua table returned will contain the following key-value pairs:
///  * `checksum`       - The ICMP packet checksum used to ensure data integrity.
///  * `code`           - ICMP Control Message Code. This should always be 0 unless the callback has received a "receivedUnexpectedPacket" message.
///  * `identifier`     - The ICMP packet identifier.  This should match the results of [hs.network.ping.echoRequest:identifier](#identifier) unless the callback has received a "receivedUnexpectedPacket" message.
///  * `payload`        - A string containing the ICMP payload for this packet. The default payload has been constructed to cause the ICMP packet to be exactly 64 bytes to match the convention for ICMP Echo Requests.
///  * `sequenceNumber` - The ICMP Sequence Number for this packet.
///  * `type`           - ICMP Control Message Type. Unless the callback has received a "receivedUnexpectedPacket" message, this will be 0 (ICMPv4) or 129 (ICMPv6) for packets we receive and 8 (ICMPv4) or 128 (ICMPv6) for packets we send.
///  * `_raw`           - A string containing the ICMP packet as raw data.
///
/// In cases where the callback receives a "receivedUnexpectedPacket" message because the packet is corrupted or truncated, this table may only contain the `_raw` field.

import Cocoa
import LuaSkin
import Darwin.POSIX

// MARK: - Constants

private let USERDATA_TAG = "hs.network.ping.echoRequest"
private var refTable: LSRefTable = LUA_NOREF

private let ADDRESS_STYLES: [String: Int] = [
    "any":  SimplePingAddressStyle.any.rawValue,
    "IPv4": SimplePingAddressStyle.ICMPv4.rawValue,
    "IPv6": SimplePingAddressStyle.ICMPv6.rawValue,
]

// MARK: - Support Functions

private func pushParsedAddress(_ L: UnsafeMutablePointer<lua_State>!, _ addressData: Data) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    var addrStr = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let err = addressData.withUnsafeBytes { buf in
        getnameinfo(
            buf.baseAddress!.assumingMemoryBound(to: sockaddr.self),
            socklen_t(addressData.count),
            &addrStr,
            socklen_t(NI_MAXHOST),
            nil,
            0,
            NI_NUMERICHOST | NI_WITHSCOPEID | NI_NUMERICSERV
        )
    }
    if err == 0 {
        skin.pushNSObject(NSString(format: "%s", addrStr))
    } else {
        skin.pushNSObject(NSString(format: "** address parse error:%s **", gai_strerror(err)))
    }
    return 1
}

private func pushParsedICMPPayload(_ L: UnsafeMutablePointer<lua_State>!, _ payloadData: Data) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let packetLength = payloadData.count

    lua_newtable(L)
    if packetLength >= kICMPHeaderSize {
        var hdr = ICMPHeader(type: 0, code: 0, checksum: 0, identifier: 0, sequenceNumber: 0)
        payloadData.withUnsafeBytes { buf in
            withUnsafeMutableBytes(of: &hdr) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: buf.baseAddress!, count: kICMPHeaderSize))
            }
        }
        lua_pushinteger(L, lua_Integer(hdr.type))
        lua_setfield(L, -2, "type")
        lua_pushinteger(L, lua_Integer(hdr.code))
        lua_setfield(L, -2, "code")
        lua_pushinteger(L, lua_Integer(hdr.checksum.bigEndian))
        lua_setfield(L, -2, "checksum")
        lua_pushinteger(L, lua_Integer(hdr.identifier.bigEndian))
        lua_setfield(L, -2, "identifier")
        lua_pushinteger(L, lua_Integer(hdr.sequenceNumber.bigEndian))
        lua_setfield(L, -2, "sequenceNumber")
        if packetLength > kICMPHeaderSize {
            skin.pushNSObject(payloadData.subdata(in: kICMPHeaderSize..<packetLength) as NSData)
            lua_setfield(L, -2, "payload")
        }
    } else {
        skin.logDebug("malformed ICMP data:\(payloadData)")
        lua_pushstring(L, "ICMP header is too short -- malformed ICMP packet")
        lua_setfield(L, -2, "error")
    }
    skin.pushNSObject(payloadData as NSData)
    lua_setfield(L, -2, "_raw")

    return 1
}

// MARK: - PingableObject

private class PingableObject: SimplePing, SimplePingDelegate {
    var callbackRef: Int32 = LUA_NOREF
    var selfRef: Int32 = LUA_NOREF
    var passAllUnexpected: Bool = false

    override init(hostName: String) {
        super.init(hostName: hostName)
        self.delegate = self
    }

    // MARK: SimplePingDelegate Methods

    func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        // Clear the close-on-invalidate flag to avoid stopping all ping objects at once
        if let s = self.socket {
            var sockopt = CFSocketGetSocketFlags(s)
            sockopt &= ~kCFSocketCloseOnInvalidate
            CFSocketSetSocketFlags(s, sockopt)
        }

        if callbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: callbackRef)
            skin.pushNSObject(pinger as! PingableObject)
            skin.pushNSObject("didStart" as NSString)
            _ = pushParsedAddress(skin.l, address)
            skin.protectedCallAndError("hs.network.ping.echoRequest:didStartWithAddress callback", nargs: 3, nresults: 0)
            _lua_stackguard_exit(skin.l)
        }
    }

    func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        let errorReason = error.localizedDescription
        skin.logDebug("\(USERDATA_TAG):didFailWithError:\(errorReason) - ping stopped.")
        if callbackRef != LUA_NOREF {
            skin.pushLuaRef(refTable, ref: callbackRef)
            skin.pushNSObject(pinger as! PingableObject)
            skin.pushNSObject("didFail" as NSString)
            skin.pushNSObject(errorReason as NSString)
            skin.protectedCallAndError("hs.network.ping.echoRequest:didFailWithError callback", nargs: 3, nresults: 0)
        }
        selfRef = skin.luaUnref(refTable, ref: selfRef)
        _lua_stackguard_exit(skin.l)
    }

    func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16) {
        if callbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: callbackRef)
            skin.pushNSObject(pinger as! PingableObject)
            skin.pushNSObject("sendPacket" as NSString)
            _ = pushParsedICMPPayload(skin.l, packet)
            lua_pushinteger(skin.l, lua_Integer(sequenceNumber))
            skin.protectedCallAndError("hs.network.ping.echoRequest:didSendPacket callback", nargs: 4, nresults: 0)
            _lua_stackguard_exit(skin.l)
        }
    }

    func simplePing(_ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error) {
        if callbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: callbackRef)
            skin.pushNSObject(pinger as! PingableObject)
            skin.pushNSObject("sendPacketFailed" as NSString)
            _ = pushParsedICMPPayload(skin.l, packet)
            lua_pushinteger(skin.l, lua_Integer(sequenceNumber))
            skin.pushNSObject(error.localizedDescription as NSString)
            skin.protectedCallAndError("hs.network.ping.echoRequest:didFailToSendPacket callback", nargs: 5, nresults: 0)
            _lua_stackguard_exit(skin.l)
        }
    }

    func simplePing(_ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16) {
        if callbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: callbackRef)
            skin.pushNSObject(pinger as! PingableObject)
            skin.pushNSObject("receivedPacket" as NSString)
            _ = pushParsedICMPPayload(skin.l, packet)
            lua_pushinteger(skin.l, lua_Integer(sequenceNumber))
            skin.protectedCallAndError("hs.network.ping.echoRequest:didReceivePingResponsePacket", nargs: 4, nresults: 0)
            _lua_stackguard_exit(skin.l)
        }
    }

    func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {
        var notifyCallback = true
        if !passAllUnexpected {
            if packet.count >= kICMPHeaderSize {
                var hdr = ICMPHeader(type: 0, code: 0, checksum: 0, identifier: 0, sequenceNumber: 0)
                packet.withUnsafeBytes { buf in
                    withUnsafeMutableBytes(of: &hdr) { dst in
                        dst.copyMemory(from: UnsafeRawBufferPointer(start: buf.baseAddress!, count: kICMPHeaderSize))
                    }
                }
                if hdr.identifier.bigEndian != self.identifier {
                    notifyCallback = false
                }
            }
        }
        if notifyCallback && callbackRef != LUA_NOREF {
            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: callbackRef)
            skin.pushNSObject(pinger as! PingableObject)
            skin.pushNSObject("receivedUnexpectedPacket" as NSString)
            _ = pushParsedICMPPayload(skin.l, packet)
            skin.protectedCallAndError("hs.network.ping.echoRequest:didReceiveUnexpectedPacket callback", nargs: 3, nresults: 0)
            _lua_stackguard_exit(skin.l)
        }
    }
}

// MARK: - Module Functions

/// hs.network.ping.echoRequest.echoRequest(server) -> echoRequestObject
/// Constructor
/// Creates a new ICMP Echo Request object for the server specified.
///
/// Parameters:
///  * `server` - a string containing the hostname or ip address of the server to communicate with. Both IPv4 and IPv6 style addresses are supported.
///
/// Returns:
///  * an echoRequest object
///
/// Notes:
///  * This constructor returns a lower-level object than the `hs.network.ping.ping` constructor and is more difficult to use. It is recommended that you use this constructor only if `hs.network.ping.ping` is not sufficient for your needs.
///
///  * For convenience, you can call this constructor as `hs.network.ping.echoRequest(server)`
private let echoRequest_new: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let pinger = PingableObject(hostName: skin.toNSObject(atIndex: 1) as! String)
    skin.pushNSObject(pinger)
    return 1
}

// MARK: - Module Methods

/// hs.network.ping.echoRequest:setCallback(fn) -> echoRequestObject
/// Method
/// Set or remove the object callback function
///
/// Parameters:
///  * `fn` - a function to set as the callback function for this object, or nil if you wish to remove any existing callback function.
///
/// Returns:
///  * the echoRequestObject
///
/// Notes:
///  * The callback function should expect between 3 and 5 arguments and return none. The possible arguments which are sent will be one of the following:
///
///    * "didStart" - indicates that the object has resolved the address of the server and is ready to begin sending and receiving ICMP Echo packets.
///      * `object`  - the echoRequestObject itself
///      * `message` - the message to the callback, in this case "didStart"
///      * `address` - a string representation of the IPv4 or IPv6 address of the server specified to the constructor.
///
///    * "didFail" - indicates that the object has failed, either because the address could not be resolved or a network error has occurred.
///      * `object`  - the echoRequestObject itself
///      * `message` - the message to the callback, in this case "didFail"
///      * `error`   - a string describing the error that occurred.
///    * Notes:
///      * When this message is received, you do not need to call [hs.network.ping.echoRequest:stop](#stop) -- the object will already have been stopped.
///
///    * "sendPacket" - indicates that the object has sent an ICMP Echo Request packet.
///      * `object`  - the echoRequestObject itself
///      * `message` - the message to the callback, in this case "sendPacket"
///      * `icmp`    - an ICMP packet table representing the packet which has been sent as described in the header of this module's documentation.
///      * `seq`     - the sequence number for this packet. Sequence numbers always start at 0 and increase by 1 every time the [hs.network.ping.echoRequest:sendPayload](#sendPayload) method is called.
///
///    * "sendPacketFailed" - indicates that the object failed to send the ICMP Echo Request packet.
///      * `object`  - the echoRequestObject itself
///      * `message` - the message to the callback, in this case "sendPacketFailed"
///      * `icmp`    - an ICMP packet table representing the packet which was to be sent.
///      * `seq`     - the sequence number for this packet.
///      * `error`   - a string describing the error that occurred.
///    * Notes:
///      * Unlike "didFail", the echoRequestObject is not stopped when this message occurs; you can try to send another payload if you wish without restarting the object first.
///
///    * "receivedPacket" - indicates that an expected ICMP Echo Reply packet has been received by the object.
///      * `object`  - the echoRequestObject itself
///      * `message` - the message to the callback, in this case "receivedPacket"
///      * `icmp`    - an ICMP packet table representing the packet received.
///      * `seq`     - the sequence number for this packet.
///
///    * "receivedUnexpectedPacket" - indicates that an unexpected ICMP packet was received
///      * `object`  - the echoRequestObject itself
///      * `message` - the message to the callback, in this case "receivedUnexpectedPacket"
///      * `icmp`    - an ICMP packet table representing the packet received.
///    * Notes:
///      * This message can occur for a variety of reasons, the most common being:
///        * the ICMP packet is corrupt or truncated and cannot be parsed
///        * the ICMP Identifier does not match ours and the sequence number is not one we have sent
///        * the ICMP type does not match an ICMP Echo Reply
///        * When using IPv6, this is especially common because IPv6 uses ICMP for network management functions like Router Advertisement and Neighbor Discovery.
///      * In general, it is reasonably safe to ignore these messages, unless you are having problems receiving anything else, in which case it could indicate problems on your network that need addressing.
private let echoRequest_setCallback: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TFUNCTION | LS_TNIL, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject

    pinger.callbackRef = skin.luaUnref(refTable, ref: pinger.callbackRef)
    if lua_type(L, 2) == LUA_TFUNCTION {
        lua_pushvalue(L, 2)
        pinger.callbackRef = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.network.ping.echoRequest:hostName() -> string
/// Method
/// Returns the name of the target host as provided to the echoRequestObject's constructor
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string containing the hostname as specified when the object was created.
private let echoRequest_hostName: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject
    skin.pushNSObject(pinger.hostName as NSString)
    return 1
}

/// hs.network.ping.echoRequest:identifier() -> integer
/// Method
/// Returns the identifier number for the echoRequestObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an integer specifying the identifier which is embedded in the ICMP packets this object sends.
///
/// Notes:
///  * ICMP Echo Replies which include this identifier will generate a "receivedPacket" message to the object callback, while replies which include a different identifier will generate a "receivedUnexpectedPacket" message.
private let echoRequest_identifier: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject
    lua_pushinteger(L, lua_Integer(pinger.identifier))
    return 1
}

/// hs.network.ping.echoRequest:nextSequenceNumber() -> integer
/// Method
/// The sequence number that will be used for the next ICMP packet sent by this object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * an integer specifying the sequence number that will be embedded in the next ICMP message sent by this object when [hs.network.ping.echoRequest:sendPayload](#sendPayload) is invoked.
///
/// Notes:
///  * ICMP Echo Replies which are expected by this object should always be less than this number, with the caveat that this number is a 16-bit integer which will wrap around to 0 after sending a packet with the sequence number 65535.
///  * Because of this wrap around effect, this module will generate a "receivedPacket" message to the object callback whenever the received packet has a sequence number that is within the last 120 sequence numbers we've sent and a "receivedUnexpectedPacket" otherwise.
///    * Per the comments in Apple's SimplePing.m file: Why 120?  Well, if we send one ping per second, 120 is 2 minutes, which is the standard "max time a packet can bounce around the Internet" value.
private let echoRequest_nextSequenceNumber: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject
    lua_pushinteger(L, lua_Integer(pinger.nextSequenceNumber))
    return 1
}

/// hs.network.ping.echoRequest:acceptAddressFamily([family]) -> echoRequestObject | current value
/// Method
/// Get or set the address family the echoRequestObject should communicate with.
///
/// Parameters:
///  * `family` - an optional string, default "any", which specifies the address family used by this object.  Valid values are "any", "IPv4", and "IPv6".
///
/// Returns:
///  * if an argument is provided, returns the echoRequestObject, otherwise returns the current value.
///
/// Notes:
///  * Setting this value to "IPv6" or "IPv4" will cause the echoRequestObject to attempt to resolve the server's name into an IPv6 address or an IPv4 address and communicate via ICMPv6 or ICMP(v4) when the [hs.network.ping.echoRequest:start](#start) method is invoked.  A callback with the message "didFail" will occur if the server could not be resolved to an address in the specified family.
///  * If this value is set to "any", then the first address which is discovered for the server's name will determine whether ICMPv6 or ICMP(v4) is used, based upon the family of the address.
///
///  * Setting a value with this method will have no immediate effect on an echoRequestObject which has already been started with [hs.network.ping.echoRequest:start](#start). You must first stop and then restart the object for any change to have an effect.
private let echoRequest_addressStyle: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject

    if lua_gettop(L) == 1 {
        let answer = ADDRESS_STYLES.first(where: { $0.value == pinger.addressStyle.rawValue })?.key
        if let answer = answer {
            skin.pushNSObject(answer as NSString)
        } else {
            skin.logError("\(USERDATA_TAG):unrecognized address style \(pinger.addressStyle.rawValue) -- notify developers")
            lua_pushnil(L)
        }
    } else {
        let key = skin.toNSObject(atIndex: 2) as! String
        if let styleRaw = ADDRESS_STYLES[key], let style = SimplePingAddressStyle(rawValue: styleRaw) {
            pinger.addressStyle = style
            lua_pushvalue(L, 1)
        } else {
            let allKeys = ADDRESS_STYLES.keys.joined(separator: ", ")
            return luaL_argerror(L, 1, "must be one of \(allKeys)")
        }
    }
    return 1
}

/// hs.network.ping.echoRequest:start() -> echoRequestObject
/// Method
/// Start the echoRequestObject by resolving the server's address and start listening for ICMP Echo Reply packets.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the echoRequestObject
private let echoRequest_start: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject

    if pinger.selfRef == LUA_NOREF {
        pinger.start()
        lua_pushvalue(L, 1)
        pinger.selfRef = skin.luaRef(refTable)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.network.ping.echoRequest:stop() -> echoRequestObject
/// Method
/// Stop listening for ICMP Echo Reply packets with this object.
///
/// Parameters:
///  * None
///
/// Returns:
///  * the echoRequestObject
private let echoRequest_stop: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject

    if pinger.selfRef != LUA_NOREF {
        pinger.stop()
        pinger.selfRef = skin.luaUnref(refTable, ref: pinger.selfRef)
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.network.ping.echoRequest:isRunning() -> boolean
/// Method
/// Returns a boolean indicating whether or not this echoRequestObject is currently listening for ICMP Echo Replies.
///
/// Parameters:
///  * None
///
/// Returns:
///  * true if the object is currently listening for ICMP Echo Replies, or false if it is not.
private let echoRequest_isRunning: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject
    lua_pushboolean(L, (pinger.selfRef != LUA_NOREF) ? 1 : 0)
    return 1
}

/// hs.network.ping.echoRequest:hostAddress() -> string | false | nil
/// Method
/// Returns a string representation for the server's IP address, or a boolean if address resolution has not completed yet.
///
/// Parameters:
///  * None
///
/// Returns:
///  * If the object has been started and address resolution has completed, then the string representation of the server's IP address is returned.
///  * If the object has been started, but resolution is still pending, returns a boolean value of false.
///  * If the object has not been started, returns nil.
private let echoRequest_hostAddress: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject
    if let hostAddress = pinger.hostAddress {
        _ = pushParsedAddress(L, hostAddress)
    } else {
        if pinger.selfRef != LUA_NOREF {
            lua_pushboolean(L, 0)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.network.ping.echoRequest:sendPayload([payload]) -> echoRequestObject | false | nil
/// Method
/// Sends a single ICMP Echo Request packet.
///
/// Parameters:
///  * `payload` - an optional string containing the data to include in the ICMP Echo Request as the packet payload.
///
/// Returns:
///  * If the object has been started and address resolution has completed, then the ICMP Echo Packet is sent and this method returns the echoRequestObject
///  * If the object has been started, but resolution is still pending, the packet is not sent and this method returns a boolean value of false.
///  * If the object has not been started, the packet is not sent and this method returns nil.
///
/// Notes:
///  * By convention, unless you are trying to test for specific network fragmentation or congestion problems, ICMP Echo Requests are generally 64 bytes in length (this includes the 8 byte header, giving 56 bytes of payload data).  If you do not specify a payload, a default payload which will result in a packet size of 64 bytes is constructed.
private let echoRequest_sendPayload: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject
    var payload: Data? = nil
    if lua_gettop(L) == 2 {
        payload = skin.toNSObject(at: 2, withOptions: UInt(1 << 3)) as? Data
    }

    if payload == nil {
        let padLen = max(0, 56 - 24 - USERDATA_TAG.count)
        let padStr = String(repeating: " ", count: padLen)
        let defaultPayload = String(format: "Cosmic Hammer %s %s0x%04x:%04x", USERDATA_TAG, padStr, pinger.identifier, pinger.nextSequenceNumber)
        payload = defaultPayload.data(using: .ascii)
    }

    if pinger.hostAddress != nil {
        pinger.sendPing(with: payload)
        lua_pushvalue(L, 1)
    } else {
        if pinger.selfRef != LUA_NOREF {
            lua_pushboolean(L, 0)
        } else {
            lua_pushnil(L)
        }
    }
    return 1
}

/// hs.network.ping.echoRequest:hostAddressFamily() -> string
/// Method
/// Returns the host address family currently in use by this echoRequestObject.
///
/// Parameters:
///  * None
///
/// Returns:
///  * a string indicating the IP address family currently used by this echoRequestObject.  It will be one of the following values:
///    * "IPv4"       - indicates that ICMP(v4) packets are being sent and listened for.
///    * "IPv6"       - indicates that ICMPv6 packets are being sent and listened for.
///    * "unresolved" - indicates that the echoRequestObject has not been started or that address resolution is still in progress.
private let echoRequest_addressFamily: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject

    switch pinger.hostAddressFamily {
    case sa_family_t(AF_INET):
        skin.pushNSObject("IPv4" as NSString)
    case sa_family_t(AF_INET6):
        skin.pushNSObject("IPv6" as NSString)
    case sa_family_t(AF_UNSPEC):
        skin.pushNSObject("unresolved" as NSString)
    default:
        skin.logError("\(USERDATA_TAG):unrecognized address family \(pinger.hostAddressFamily) -- notify developers")
        lua_pushnil(L)
    }
    return 1
}

/// hs.network.ping.echoRequest:seeAllUnexpectedPackets([state]) -> boolean | echoRequestObject
/// Method
/// Get or set whether or not the callback should receive all unexpected packets or only those which carry our identifier.
///
/// Parameters:
///  * `state` - an optional boolean, default false, specifying whether or not all unexpected packets or only those which carry our identifier should generate a "receivedUnexpectedPacket" callback message.
///
/// Returns:
///  * if an argument is provided, returns the echoRequestObject; otherwise returns the current value
///
/// Notes:
///  * The nature of ICMP packet reception is such that all listeners receive all ICMP packets, even those which belong to another process or echoRequestObject.
///    * By default, a valid packet (i.e. with a valid checksum) which does not contain our identifier is ignored since it was not intended for our receiver.  Only corrupt or packets with our identifier but that were otherwise unexpected will generate a "receivedUnexpectedPacket" callback message.
///    * This method optionally allows the echoRequestObject to receive *all* incoming packets, even ones which are expected by another process or echoRequestObject.
///  * If you wish to examine ICMPv6 router advertisement and neighbor discovery packets, you should set this property to true. Note that this module does not provide the necessary tools to decode these packets at present, so you will have to decode them yourself if you wish to examine their contents.
private let echoRequest_seeAllUnexpectedPackets: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let pinger = skin.toNSObject(atIndex: 1) as! PingableObject

    if lua_gettop(L) == 1 {
        lua_pushboolean(L, pinger.passAllUnexpected ? 1 : 0)
    } else {
        pinger.passAllUnexpected = lua_toboolean(L, 2) != 0
        lua_pushvalue(L, 1)
    }
    return 1
}

// MARK: - Lua<->NSObject Conversion Functions

private func pushPingableObject(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let value = obj as! PingableObject

    if value.selfRef != LUA_NOREF {
        LuaSkin.skin(with: L).pushLuaRef(refTable, ref: value.selfRef)
    } else {
        let valuePtr = lua_newuserdata(L, MemoryLayout<UnsafeMutableRawPointer>.size)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        valuePtr.pointee = Unmanaged.passRetained(value).toOpaque()
        luaL_getmetatable(L, USERDATA_TAG)
        lua_setmetatable(L, -2)
    }
    return 1
}

private func toPingableObjectFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.skin(with: L)
    if luaL_testudata(L, idx, USERDATA_TAG) != nil {
        let ptr = luaL_checkudata(L, idx, USERDATA_TAG)!
            .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        return Unmanaged<PingableObject>.fromOpaque(ptr.pointee!).takeUnretainedValue()
    } else {
        skin.logError("expected \(USERDATA_TAG) object, found \(String(cString: lua_typename(L, lua_type(L, idx))))")
    }
    return nil
}

// MARK: - Cosmic Hammer/Lua Infrastructure

private let userdata_tostring: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    let obj = skin.luaObject(at: 1, toClass: "PingableObject") as! PingableObject
    let title = obj.hostName
    let ptr = lua_topointer(L, 1)
    skin.pushNSObject("\(USERDATA_TAG): \(title) (\(String(describing: ptr)))" as NSString)
    return 1
}

private let userdata_eq: lua_CFunction = { L in
    if luaL_testudata(L, 1, USERDATA_TAG) != nil && luaL_testudata(L, 2, USERDATA_TAG) != nil {
        let skin = LuaSkin.skin(with: L)
        let obj1 = skin.luaObject(at: 1, toClass: "PingableObject") as! PingableObject
        let obj2 = skin.luaObject(at: 2, toClass: "PingableObject") as! PingableObject
        lua_pushboolean(L, (obj1 === obj2) ? 1 : 0)
    } else {
        lua_pushboolean(L, 0)
    }
    return 1
}

private let userdata_gc: lua_CFunction = { L in
    let skin = LuaSkin.skin(with: L)
    let ptr = luaL_checkudata(L, 1, USERDATA_TAG)!
        .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    if let rawPtr = ptr.pointee {
        let obj = Unmanaged<PingableObject>.fromOpaque(rawPtr).takeRetainedValue()
        obj.callbackRef = skin.luaUnref(refTable, ref: obj.callbackRef)

        if obj.selfRef != LUA_NOREF {
            obj.stop()
            obj.selfRef = skin.luaUnref(refTable, ref: obj.selfRef)
        }
        ptr.pointee = nil
    }

    lua_pushnil(L)
    lua_setmetatable(L, 1)
    return 0
}

// Metatable for userdata objects
private var userdata_metaLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("hostName"),                func: echoRequest_hostName),
    luaL_Reg(name: strdup("identifier"),              func: echoRequest_identifier),
    luaL_Reg(name: strdup("nextSequenceNumber"),      func: echoRequest_nextSequenceNumber),
    luaL_Reg(name: strdup("setCallback"),             func: echoRequest_setCallback),
    luaL_Reg(name: strdup("acceptAddressFamily"),     func: echoRequest_addressStyle),
    luaL_Reg(name: strdup("start"),                   func: echoRequest_start),
    luaL_Reg(name: strdup("stop"),                    func: echoRequest_stop),
    luaL_Reg(name: strdup("isRunning"),               func: echoRequest_isRunning),
    luaL_Reg(name: strdup("hostAddress"),             func: echoRequest_hostAddress),
    luaL_Reg(name: strdup("hostAddressFamily"),       func: echoRequest_addressFamily),
    luaL_Reg(name: strdup("sendPayload"),             func: echoRequest_sendPayload),
    luaL_Reg(name: strdup("seeAllUnexpectedPackets"), func: echoRequest_seeAllUnexpectedPackets),

    luaL_Reg(name: strdup("__tostring"),              func: userdata_tostring),
    luaL_Reg(name: strdup("__eq"),                    func: userdata_eq),
    luaL_Reg(name: strdup("__gc"),                    func: userdata_gc),
    luaL_Reg(name: nil,                               func: nil),
]

// Functions for returned object when module loads
private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("echoRequest"), func: echoRequest_new),
    luaL_Reg(name: nil,                   func: nil),
]

@_cdecl("luaopen_hs_libnetworkping")
public func luaopen_hs_libnetworkping(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: USERDATA_TAG,
                                    functions: &moduleLib,
                                    metaFunctions: nil,
                                    objectFunctions: &userdata_metaLib)

    skin.registerPushNSHelper(pushPingableObject, forClass: "PingableObject")
    skin.registerLuaObjectHelper(toPingableObjectFromLua, forClass: "PingableObject",
                                 withUserdataMapping: USERDATA_TAG)

    return 1
}
