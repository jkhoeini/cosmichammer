import Cocoa
import LuaSkin
import CocoaHTTPServer
import CocoaAsyncSocket
import os.log

// MARK: - Constants

private let TIMEOUT_WRITE_ERROR: TimeInterval = 30
private let HTTP_FINAL_RESPONSE: Int = 91

private let USERDATA_TAG = "hs.httpserver"
private var refTable: LSRefTable = 0

// MARK: - Helper Functions

private func get_item_arg(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafeMutablePointer<httpserver_t> {
    return luaL_checkudata(L, idx, USERDATA_TAG)!.bindMemory(to: httpserver_t.self, capacity: 1)
}

private func getUserData(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSHTTPServer {
    let httpServer = get_item_arg(L, idx)
    return Unmanaged<HSHTTPServer>.fromOpaque(httpServer.pointee.server!).takeUnretainedValue()
}

// MARK: - Userdata Struct

private struct httpserver_t {
    var server: UnsafeMutableRawPointer?
}

// MARK: - ObjC Class Definitions

@objc private class HSWebSocket: WebSocket {
    @objc var callback: Int32 = LUA_NOREF

    override func didOpen() {
        super.didOpen()
        os_log(.info, "Opened websocket connection")
    }

    override func didReceive(_ msg: Data!) {
        var response: NSData? = nil

        let responseCallbackBlock = { [self] in
            if self.callback != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: self.callback)
                skin.pushNSObject(msg as NSData)

                if !skin.protectedCallAndTraceback(1, nresults: 1) {
                    let errorMsg = lua_tostring(skin.l, -1).map { String(cString: $0) } ?? "unknown error"
                    skin.logError("hs.httpserver:websocket callback error: \(errorMsg)")
                } else {
                    response = skin.toNSObject(atIndex: -1) as? NSData
                }

                lua_pop(skin.l, 1)
                _lua_stackguard_exit(skin.l)
            }
        }

        if Thread.isMainThread {
            responseCallbackBlock()
        } else {
            DispatchQueue.main.sync(execute: responseCallbackBlock)
        }

        sendMessage("\(response as Any)")
    }

    override func didReceiveMessage(_ msg: String!) {
        var response: NSData? = nil

        let responseCallbackBlock = { [self] in
            if self.callback != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: self.callback)
                lua_pushstring(skin.l, msg)

                if !skin.protectedCallAndTraceback(1, nresults: 1) {
                    let errorMsg = lua_tostring(skin.l, -1).map { String(cString: $0) } ?? "unknown error"
                    skin.logError("hs.httpserver:websocket callback error: \(errorMsg)")
                } else {
                    response = skin.toNSObject(atIndex: -1) as? NSData
                }

                lua_pop(skin.l, 1)
                _lua_stackguard_exit(skin.l)
            }
        }

        if Thread.isMainThread {
            responseCallbackBlock()
        } else {
            DispatchQueue.main.sync(execute: responseCallbackBlock)
        }

        sendMessage("\(response as Any)")
    }

    override func didClose() {
        super.didClose()
        os_log(.info, "Closed websocket connection")
    }
}

@objc private class HSHTTPServer: HTTPServer {
    @objc var fn: Int32 = LUA_NOREF
    @objc var maxBodySize: UInt = 10 * 1024 * 1024
    @objc var sslIdentity: SecIdentity?
    @objc var httpPassword: String?
    @objc var wsCallback: Int32 = LUA_NOREF
    @objc var wsPath: String?
    @objc var ws: HSWebSocket?

    override init() {
        super.init()
        httpPassword = nil
        maxBodySize = 10 * 1024 * 1024
        wsCallback = LUA_NOREF
        fn = LUA_NOREF
    }
}

@objc private class HSHTTPDataResponse: HTTPDataResponse {
    @objc var hsStatus: Int = 0
    @objc var hsHeaders: NSDictionary?

    override func status() -> Int { return hsStatus }
    override func httpHeaders() -> [AnyHashable: Any]! { return hsHeaders as? [AnyHashable: Any] }
}

@objc private class HSHTTPConnection: HTTPConnection {

    override func supportsMethod(_ method: String!, atPath path: String!) -> Bool {
        if method == "POST" || method == "PUT" {
            return requestContentLength <= (config.server as! HSHTTPServer).maxBodySize
        }
        return true
    }

    override func handleUnknownMethod(_ method: String!) {
        if requestContentLength > (config.server as! HSHTTPServer).maxBodySize {
            let response = HTTPMessage(responseWithStatusCode: 413, description: nil, version: HTTPVersion1_1_str)!
            response.setHeaderField("Content-Length", value: "0")
            response.setHeaderField("Connection", value: "close")

            let responseData = preprocessErrorResponse(response)
            asyncSocket.write(responseData, withTimeout: TIMEOUT_WRITE_ERROR, tag: HTTP_FINAL_RESPONSE)
        } else {
            super.handleUnknownMethod(method)
        }
    }

    override func preprocessErrorResponse(_ response: HTTPMessage!) -> Data! {
        if response.statusCode() == 413 {
            let msg = "<html><head><title>Request Entity Too Large</title><head><body><H1>HTTP/1.1 413 Request Entity Too Large</H1><br/>The \(request.method()!) method is not supported for requests larger than \((config.server as! HSHTTPServer).maxBodySize) bytes.<br/><hr/></body></html>"
            let msgData = msg.data(using: .utf8)!
            response.setBody(msgData)
            response.setHeaderField("Content-Length", value: "\(msgData.count)")
        }
        return super.preprocessErrorResponse(response)
    }

    override func processBodyData(_ postDataChunk: Data!) {
        request.append(postDataChunk)
    }

    override func httpResponse(forMethod method: String!, uri path: String!) -> (any HTTPResponse & NSObjectProtocol)! {
        var responseCode: Int32 = 0
        var responseHeaders: NSMutableDictionary? = nil
        var responseBody: Data? = nil

        let responseCallbackBlock = { [self] in
            if (self.config.server as! HSHTTPServer).fn != LUA_NOREF {
                let skin = LuaSkin.skin(with: nil)
                let L = skin.l!
                _lua_stackguard_entry(L)

                self.request.setHeaderField("X-Remote-Addr", value: self.asyncSocket.connectedHost)
                self.request.setHeaderField("X-Remote-Port", value: "\(self.asyncSocket.connectedPort)")
                self.request.setHeaderField("X-Server-Addr", value: self.asyncSocket.localHost)
                self.request.setHeaderField("X-Server-Port", value: "\(self.asyncSocket.localPort)")

                skin.pushLuaRef(refTable, ref: (self.config.server as! HSHTTPServer).fn)
                lua_pushstring(L, method)
                lua_pushstring(L, path)
                skin.pushNSObject(self.request.allHeaderFields())
                skin.pushNSObject(self.request.body() as NSData?, withOptions: LS_NSConversionOptions.nsLuaStringAsDataOnly.rawValue)

                if !skin.protectedCallAndTraceback(4, nresults: 3) {
                    let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "unknown error"
                    skin.logError("hs.httpserver:setCallback() callback error: \(errorMsg)")
                    responseCode = 503
                    responseBody = "An error occurred during hs.httpserver callback handling".data(using: .utf8)
                    lua_pop(L, 1)
                } else {
                    if !(lua_type(L, -3) == LUA_TSTRING && lua_type(L, -2) == LUA_TNUMBER && lua_type(L, -1) == LUA_TTABLE) {
                        skin.logError("hs.httpserver:setCallback() callbacks must return three values. A string for the response body, an integer response code, and a table of headers")
                        responseCode = 503
                        responseBody = "Callback handler returned invalid values".data(using: .utf8)
                    } else {
                        responseBody = skin.toNSObject(at: -3, withOptions: LS_NSConversionOptions.nsLuaStringAsDataOnly.rawValue) as? Data
                        responseCode = Int32(lua_tointeger(L, -2))

                        responseHeaders = NSMutableDictionary()
                        var headerTypeError = false
                        lua_pushnil(L)
                        while lua_next(L, -2) != 0 {
                            if lua_type(L, -1) == LUA_TSTRING && lua_type(L, -2) == LUA_TSTRING {
                                let key: String = skin.toNSObject(atIndex: -2) as! String
                                let value: String = skin.toNSObject(atIndex: -1) as! String
                                responseHeaders?[key] = value
                            } else {
                                headerTypeError = true
                            }
                            lua_pop(L, 1)
                        }
                        if headerTypeError {
                            skin.logError("hs.httpserver:setCallback() callback returned a header table that contains non-strings")
                        }
                    }
                    lua_pop(L, 3)
                }
                _lua_stackguard_exit(L)
            }
        }

        if Thread.isMainThread {
            responseCallbackBlock()
        } else {
            DispatchQueue.main.sync(execute: responseCallbackBlock)
        }

        let response = HSHTTPDataResponse(data: responseBody)!
        response.hsStatus = Int(responseCode)
        response.hsHeaders = responseHeaders
        return response
    }

    override func isPasswordProtected(_ path: String!) -> Bool {
        return (config.server as! HSHTTPServer).httpPassword != nil
    }

    override func useDigestAccessAuthentication() -> Bool {
        return true
    }

    override func password(forUser username: String!) -> String! {
        return (config.server as! HSHTTPServer).httpPassword
    }

    override func webSocket(forURI path: String!) -> WebSocket! {
        if path == (config.server as! HSHTTPServer).wsPath {
            let ws = HSWebSocket(request: request, socket: asyncSocket)!
            ws.callback = (config.server as! HSHTTPServer).wsCallback
            (config.server as! HSHTTPServer).ws = ws
            return ws
        }
        return super.webSocket(forURI: path)
    }
}

@objc private class HSHTTPSConnection: HSHTTPConnection {
    override func isSecureServer() -> Bool {
        return true
    }

    override func sslIdentityAndCertificates() -> [Any]! {
        guard let identity = MYGetOrCreateAnonymousIdentity("Cosmic Hammer HTTP Server", 20 * kMYAnonymousIdentityDefaultExpirationInterval) else {
            os_log(.error, "ERROR: Unable to find/generate a certificate")
            return nil
        }

        (config.server as! HSHTTPServer).sslIdentity = identity
        return [identity]
    }

    override func startConnection() {
        if isSecureServer() {
            let certificates = sslIdentityAndCertificates()

            if let certificates = certificates, certificates.count > 0 {
                let settings = NSMutableDictionary(capacity: 3)
                settings[kCFStreamSSLIsServer as String] = NSNumber(value: true)
                settings[kCFStreamSSLCertificates as String] = certificates
                // kTLSProtocol12 = 8 (deprecated SSLProtocol enum value)
                settings[GCDAsyncSocketSSLProtocolVersionMin] = NSNumber(value: Int32(8))
                settings[GCDAsyncSocketSSLProtocolVersionMax] = NSNumber(value: Int32(8))

                asyncSocket.startTLS(settings as? [String: NSObject])
            }
        }

        (self as HTTPConnection).perform(Selector(("startReadingRequest")))
    }
}

// MARK: - Module Functions

/// hs.httpserver.new([ssl], [bonjour]) -> object
/// Function
/// Creates a new HTTP or HTTPS server
///
/// Parameters:
///  * ssl     - An optional boolean. If true, the server will start using HTTPS. Defaults to false.
///  * bonjour - An optional boolean. If true, the server will advertise itself with Bonjour.  Defaults to true. Note that in order to change this, you must supply a true or false value for the `ssl` argument.
///
/// Returns:
///  * An `hs.httpserver` object
///
/// Notes:
///  * By default, the server will start on a random TCP port and advertise itself with Bonjour. You can check the port with `hs.httpserver:getPort()`
///  * By default, the server will listen on all network interfaces. You can override this with `hs.httpserver:setInterface()` before starting the server
///  * Currently, in HTTPS mode, the server will use a self-signed certificate, which most browsers will warn about. If you want/need to be able to use `hs.httpserver` with a certificate signed by a trusted Certificate Authority, please file an bug on Cosmic Hammer requesting support for this.
private func httpserver_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TBOOLEAN | LS_TOPTIONAL, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    let useSSL = (lua_type(L, 1) == LUA_TBOOLEAN) ? (lua_toboolean(L, 1) != 0) : false
    let useBonjour = (lua_type(L, 2) == LUA_TBOOLEAN) ? (lua_toboolean(L, 2) != 0) : true

    let ptr = lua_newuserdata(L, MemoryLayout<httpserver_t>.size)!
    let httpServer = ptr.bindMemory(to: httpserver_t.self, capacity: 1)
    httpServer.pointee = httpserver_t()

    let server = HSHTTPServer()
    if useSSL {
        server.setConnectionClass(HSHTTPSConnection.self)
    } else {
        server.setConnectionClass(HSHTTPConnection.self)
    }
    if useBonjour { server.setType("_http._tcp.") }

    server.fn = LUA_NOREF
    httpServer.pointee.server = Unmanaged.passRetained(server).toOpaque()

    luaL_getmetatable(L, USERDATA_TAG)
    lua_setmetatable(L, -2)
    return 1
}

/// hs.httpserver:websocket(path, callback) -> object
/// Method
/// Enables a websocket endpoint on the HTTP server
///
/// Parameters:
///  * path - A string containing the websocket path such as '/ws'
///  * callback - A function returning a string for each received websocket message
///
/// Returns:
///  * The `hs.httpserver` object
///
/// Notes:
///  * The callback is passed one string parameter containing the received message
///  * The callback must return a string containing the response message
///  * Given a path '/mysock' and a port of 8000, the websocket URL is as follows:
///   * ws://localhost:8000/mysock
///   * wss://localhost:8000/mysock (if SSL enabled)
private func httpserver_websocket(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TFUNCTION, LS_TBREAK)
    let server = getUserData(L, 1)

    server.wsPath = skin.toNSObject(atIndex: 2) as? String
    server.wsCallback = skin.luaUnref(refTable, ref: server.wsCallback)
    lua_pushvalue(L, 3)
    server.wsCallback = skin.luaRef(refTable)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:send(message) -> object
/// Method
/// Sends a message to the websocket client
///
/// Parameters:
///  * message - A string containing the message to send
///
/// Returns:
///  * The `hs.httpserver` object
private func httpserver_send(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let server = getUserData(L, 1)

    server.ws?.sendMessage(skin.toNSObject(atIndex: 2) as? String)

    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:setCallback([callback]) -> object
/// Method
/// Sets the request handling callback for an HTTP server object
///
/// Parameters:
///  * callback - An optional function that will be called to process each incoming HTTP request, or nil to remove an existing callback. See the notes section below for more information about this callback
///
/// Returns:
///  * The `hs.httpserver` object
///
/// Notes:
///  * The callback will be passed four arguments:
///   * A string containing the type of request (i.e. `GET`/`POST`/`DELETE`/etc)
///   * A string containing the path element of the request (e.g. `/index.html`)
///   * A table containing the request headers
///   * A string containing the raw contents of the request body, or the empty string if no body is included in the request.
///  * The callback *must* return three values:
///   * A string containing the body of the response
///   * An integer containing the response code (e.g. 200 for a successful request)
///   * A table containing additional HTTP headers to set (or an empty table, `{}`, if no extra headers are required)
///
/// Notes:
///  * A POST request, often used by HTML forms, will store the contents of the form in the body of the request.
private func httpserver_setCallback(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let server = getUserData(L, 1)

    switch lua_type(L, 2) {
    case LUA_TFUNCTION:
        server.fn = skin.luaUnref(refTable, ref: server.fn)
        lua_pushvalue(L, 2)
        server.fn = skin.luaRef(refTable)
    case LUA_TNIL, LUA_TNONE:
        server.fn = skin.luaUnref(refTable, ref: server.fn)
    default:
        skin.logError("Unknown type passed to hs.httpserver:setCallback(). Argument must be a function or nil")
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:maxBodySize([size]) -> object | current-value
/// Method
/// Get or set the maximum allowed body size for an incoming HTTP request.
///
/// Parameters:
///  * size - An optional integer value specifying the maximum body size allowed for an incoming HTTP request in bytes.  Defaults to 10485760 (10 MB).
///
/// Returns:
///  * If a new size is specified, returns the `hs.httpserver` object; otherwise the current value.
///
/// Notes:
///  * Because the Cosmic Hammer http server processes incoming requests completely in memory, this method puts a limit on the maximum size for a POST or PUT request.
private func httpserver_maxBodySize(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)

    let server = getUserData(L, 1)
    if lua_gettop(L) == 2 {
        server.maxBodySize = UInt(lua_tointeger(L, 2))
        lua_pushvalue(L, 1)
    } else {
        lua_pushinteger(L, lua_Integer(server.maxBodySize))
    }
    return 1
}

/// hs.httpserver:setPassword([password]) -> object
/// Method
/// Sets a password for an HTTP server object
///
/// Parameters:
///  * password - An optional string that contains the server password, or nil to remove an existing password
///
/// Returns:
///  * The `hs.httpserver` object
///
/// Notes:
///  * It is not currently possible to set multiple passwords for different users, or passwords only on specific paths
private func httpserver_setPassword(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TBREAK)
    let server = getUserData(L, 1)

    switch lua_type(L, 2) {
    case LUA_TNIL, LUA_TNONE:
        server.httpPassword = nil
    case LUA_TSTRING:
        server.httpPassword = skin.toNSObject(atIndex: 2) as? String
    default:
        skin.logError("Unknown type passed to hs.httpserver:setPassword(). Argument must be a string or nil")
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:start() -> object
/// Method
/// Starts an HTTP server object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.httpserver` object
private func httpserver_start(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let server = getUserData(L, 1)

    if server.fn == LUA_NOREF && server.wsCallback == LUA_NOREF {
        skin.logError("hs.httpserver:start() called with no callback set. You must call `hs.httpserver:setCallback()` or `hs.httpserver:websocket()` first.")
    } else {
        do {
            try server.start()
        } catch {
            skin.logError("hs.httpserver:start() Unable to start object: \(error)")
        }
    }

    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:stop() -> object
/// Method
/// Stops an HTTP server object
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.httpserver` object
private func httpserver_stop(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let server = getUserData(L, 1)
    server.stop()

    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:getPort() -> number
/// Method
/// Gets the TCP port the server is configured to listen on
///
/// Parameters:
///  * None
///
/// Returns:
///  * A number containing the TCP port
private func httpserver_getPort(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let server = getUserData(L, 1)
    lua_pushinteger(L, lua_Integer(server.listeningPort()))
    return 1
}

/// hs.httpserver:setPort(port) -> object
/// Method
/// Sets the TCP port the server is configured to listen on
///
/// Parameters:
///  * port - An integer containing a TCP port to listen on
///
/// Returns:
///  * The `hs.httpserver` object
private func httpserver_setPort(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let server = getUserData(L, 1)
    server.setPort(UInt16(luaL_checkinteger(L, 2)))
    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:getInterface() -> string or nil
/// Method
/// Gets the network interface the server is configured to listen on
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the network interface name, or nil if the server will listen on all interfaces
private func httpserver_getInterface(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let server = getUserData(L, 1)
    if let iface = server.interface() {
        lua_pushstring(L, iface)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.httpserver:setInterface(interface) -> object
/// Method
/// Sets the network interface the server is configured to listen on
///
/// Parameters:
///  * interface - A string containing an interface name
///
/// Returns:
///  * The `hs.httpserver` object
///
/// Notes:
///  * As well as real interface names (e.g. `en0`) the following values are valid:
///   * An IP address of one of your interfaces
///   * localhost
///   * loopback
///   * nil (which means all interfaces, and is the default)
private func httpserver_setInterface(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let server = getUserData(L, 1)
    if lua_isnoneornil(L, 2) {
        server.setInterface(nil)
    } else {
        server.setInterface(String(cString: luaL_checkstring(L, 2)))
    }
    lua_pushvalue(L, 1)
    return 1
}

/// hs.httpserver:getName() -> string
/// Method
/// Gets the Bonjour name the server is configured to advertise itself as
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the Bonjour name of this server
///
/// Notes:
///  * This is not the hostname of the server, just its name in Bonjour service lists (e.g. Safari's Bonjour bookmarks menu)
private func httpserver_getName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let server = getUserData(L, 1)
    if let name = server.name() {
        lua_pushstring(L, name)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.httpserver:setName(name) -> object
/// Method
/// Sets the Bonjour name the server should advertise itself as
///
/// Parameters:
///  * name - A string containing the Bonjour name for the server
///
/// Returns:
///  * The `hs.httpserver` object
///
/// Notes:
///  * This is not the hostname of the server, just its name in Bonjour service lists (e.g. Safari's Bonjour bookmarks menu)
private func httpserver_setName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, USERDATA_TAG, LS_TSTRING, LS_TBREAK)
    let server = getUserData(L, 1)
    server.setName(skin.toNSObject(atIndex: 2) as? String)
    lua_pushvalue(L, 1)
    return 1
}

// MARK: - GC / Meta

private func httpserver_objectGC(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let httpServer = get_item_arg(L, 1)
    let server = Unmanaged<HSHTTPServer>.fromOpaque(httpServer.pointee.server!).takeRetainedValue()
    server.stop()
    server.fn = skin.luaUnref(refTable, ref: server.fn)
    server.wsCallback = skin.luaUnref(refTable, ref: server.wsCallback)
    return 0
}

private func userdata_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let server = getUserData(L, 1)
    let theName = server.name() ?? "unnamed"
    let thePort = server.listeningPort()

    let str = "\(USERDATA_TAG): \(theName):\(thePort) (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, str)
    return 1
}

// MARK: - Registration

private let httpserverLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: httpserver_new),
    luaL_Reg(name: nil, func: nil),
]

private let httpserverObjectLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("websocket"),    func: httpserver_websocket),
    luaL_Reg(name: strdup("send"),         func: httpserver_send),
    luaL_Reg(name: strdup("start"),        func: httpserver_start),
    luaL_Reg(name: strdup("stop"),         func: httpserver_stop),
    luaL_Reg(name: strdup("getPort"),      func: httpserver_getPort),
    luaL_Reg(name: strdup("setPort"),      func: httpserver_setPort),
    luaL_Reg(name: strdup("getInterface"), func: httpserver_getInterface),
    luaL_Reg(name: strdup("setInterface"), func: httpserver_setInterface),
    luaL_Reg(name: strdup("getName"),      func: httpserver_getName),
    luaL_Reg(name: strdup("setName"),      func: httpserver_setName),
    luaL_Reg(name: strdup("setCallback"),  func: httpserver_setCallback),
    luaL_Reg(name: strdup("setPassword"),  func: httpserver_setPassword),
    luaL_Reg(name: strdup("maxBodySize"),  func: httpserver_maxBodySize),
    luaL_Reg(name: strdup("__tostring"),   func: userdata_tostring),
    luaL_Reg(name: strdup("__gc"),         func: httpserver_objectGC),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhttpserver")
public func luaopen_hs_libhttpserver(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary(withObject: "hs.httpserver", functions: httpserverLib, metaFunctions: nil, objectFunctions: httpserverObjectLib)

    return 1
}
