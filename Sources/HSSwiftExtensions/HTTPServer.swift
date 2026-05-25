import Cocoa
import LuaSkin
import os.log

// MARK: - Constants

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

// MARK: - HSHTTPServer — wraps NWHTTPServer for Lua

private class HSHTTPServer {
    let nwServer = NWHTTPServer()

    var fn: Int32 = LUA_NOREF
    var wsCallback: Int32 = LUA_NOREF
    var wsPath: String?
    var wsServer: NWWebSocketServer?

    /// Whether Bonjour advertisement is enabled (set at creation time).
    var useBonjour: Bool = true

    /// Whether SSL/TLS is enabled (set at creation time).
    var useSSL: Bool {
        get { nwServer.useSSL }
        set { nwServer.useSSL = newValue }
    }

    // Proxy properties to NWHTTPServer
    var maxBodySize: Int {
        get { nwServer.maxBodySize }
        set { nwServer.maxBodySize = newValue }
    }

    var httpPassword: String? {
        get { nwServer.password }
        set { nwServer.password = newValue }
    }

    func start() throws {
        // Wire up the request handler from the Lua callback
        nwServer.requestHandler = { [weak self] method, path, headers, body in
            guard let self = self else {
                return (Data("Server error".utf8), 503, [:])
            }
            return self.handleRequest(method: method, path: path, headers: headers, body: body)
        }

        // Wire up WebSocket if configured
        if let wsPath = wsPath {
            let ws = NWWebSocketServer(path: wsPath)
            ws.onMessage = { [weak self] message in
                self?.handleWebSocketMessage(message)
            }
            ws.onOpen = {
                os_log(.info, "Opened websocket connection")
            }
            ws.onClose = {
                os_log(.info, "Closed websocket connection")
            }
            wsServer = ws
            nwServer.webSocketHandler = ws
        }

        try nwServer.start()
    }

    func stop() {
        nwServer.stop()
        wsServer?.close()
    }

    func listeningPort() -> UInt16 {
        return nwServer.listeningPort() ?? 0
    }

    func setPort(_ port: UInt16) {
        nwServer.port = port
    }

    func interface() -> String? {
        return nwServer.interface
    }

    func setInterface(_ iface: String?) {
        nwServer.interface = iface
    }

    func name() -> String? {
        return nwServer.name
    }

    func setName(_ name: String?) {
        nwServer.name = name
    }

    func setType(_ type: String) {
        // Bonjour type is handled by NWHTTPServer internally via the name property.
        // Setting a name enables Bonjour advertisement.
    }

    // MARK: - Request Handling (Lua callback bridge)

    private func handleRequest(
        method: String,
        path: String,
        headers: [String: String],
        body: Data
    ) -> (Data, Int, [String: String]) {
        var responseCode: Int = 503
        var responseHeaders: [String: String] = [:]
        var responseBody = Data("An error occurred during hs.httpserver callback handling".utf8)

        let responseCallbackBlock = { [self] in
            guard self.fn != LUA_NOREF else { return }

            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)

            skin.pushLuaRef(refTable, ref: self.fn)
            lua_pushstring(L, method)
            lua_pushstring(L, path)
            skin.pushNSObject(headers as NSDictionary)
            skin.pushNSObject(body as NSData, withOptions: LS_NSConversionOptions.nsLuaStringAsDataOnly.rawValue)

            if !skin.protectedCallAndTraceback(4, nresults: 3) {
                let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "unknown error"
                skin.logError("hs.httpserver:setCallback() callback error: \(errorMsg)")
                responseCode = 503
                responseBody = Data("An error occurred during hs.httpserver callback handling".utf8)
                lua_pop(L, 1)
            } else {
                if !(lua_type(L, -3) == LUA_TSTRING && lua_type(L, -2) == LUA_TNUMBER && lua_type(L, -1) == LUA_TTABLE) {
                    skin.logError("hs.httpserver:setCallback() callbacks must return three values. A string for the response body, an integer response code, and a table of headers")
                    responseCode = 503
                    responseBody = Data("Callback handler returned invalid values".utf8)
                } else {
                    responseBody = (skin.toNSObject(at: -3, withOptions: LS_NSConversionOptions.nsLuaStringAsDataOnly.rawValue) as? Data) ?? Data()
                    responseCode = Int(lua_tointeger(L, -2))

                    var headerTypeError = false
                    lua_pushnil(L)
                    while lua_next(L, -2) != 0 {
                        if lua_type(L, -1) == LUA_TSTRING && lua_type(L, -2) == LUA_TSTRING {
                            let key: String = skin.toNSObject(atIndex: -2) as! String
                            let value: String = skin.toNSObject(atIndex: -1) as! String
                            responseHeaders[key] = value
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

        if Thread.isMainThread {
            responseCallbackBlock()
        } else {
            DispatchQueue.main.sync(execute: responseCallbackBlock)
        }

        return (responseBody, responseCode, responseHeaders)
    }

    // MARK: - WebSocket Message Handling (Lua callback bridge)

    private func handleWebSocketMessage(_ message: String) {
        var response: String? = nil

        let responseCallbackBlock = { [self] in
            guard self.wsCallback != LUA_NOREF else { return }

            let skin = LuaSkin.skin(with: nil)
            _lua_stackguard_entry(skin.l)
            skin.pushLuaRef(refTable, ref: self.wsCallback)
            lua_pushstring(skin.l, message)

            if !skin.protectedCallAndTraceback(1, nresults: 1) {
                let errorMsg = lua_tostring(skin.l, -1).map { String(cString: $0) } ?? "unknown error"
                skin.logError("hs.httpserver:websocket callback error: \(errorMsg)")
            } else {
                if let result = skin.toNSObject(atIndex: -1) as? String {
                    response = result
                } else if let data = skin.toNSObject(atIndex: -1) as? NSData {
                    response = String(data: data as Data, encoding: .utf8)
                }
            }

            lua_pop(skin.l, 1)
            _lua_stackguard_exit(skin.l)
        }

        if Thread.isMainThread {
            responseCallbackBlock()
        } else {
            DispatchQueue.main.sync(execute: responseCallbackBlock)
        }

        if let response = response {
            wsServer?.send(response)
        }
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
    server.useSSL = useSSL
    server.useBonjour = useBonjour
    if useBonjour {
        server.setType("_http._tcp.")
    }
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

    if let msg = skin.toNSObject(atIndex: 2) as? String {
        server.wsServer?.send(msg)
    }

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
        server.maxBodySize = Int(lua_tointeger(L, 2))
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
