import Cocoa
import CLua
import Lua
import os.log

// MARK: - Constants

private let USERDATA_TAG = "hs.httpserver"

// MARK: - HSHTTPServer — wraps NWHTTPServer for Lua

private class HSHTTPServer {
    let nwServer = NWHTTPServer()

    var fn: LuaValue?
    var wsCallback: LuaValue?
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

    private var tornDown = false

    /// Idempotent teardown: stop the server, drop Lua callback references,
    /// mark as torn down.  Called from the explicit __gc closure while the
    /// lua_State is still alive.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        stop()
        fn = nil
        wsCallback = nil
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
            guard let cb = self.fn else { return }

            let L = lua_getCurrentState()!

            cb.push(onto: L)
            lua_pushstring(L, method)
            lua_pushstring(L, path)
            lua_pushany(L, headers as NSDictionary)
            // Push body as raw Lua string (binary data)
            body.withUnsafeBytes { rawBuf in
                lua_pushlstring(L, rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self), rawBuf.count)
            }

            if lua_pcall(L, 4, 3, 0) != LUA_OK {
                let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "unknown error"
                os_log(.error, "hs.httpserver:setCallback() callback error: %{public}s", errorMsg)
                responseCode = 503
                responseBody = Data("An error occurred during hs.httpserver callback handling".utf8)
                lua_pop(L, 1)
            } else {
                if !(lua_type(L, -3) == LUA_TSTRING && lua_type(L, -2) == LUA_TNUMBER && lua_type(L, -1) == LUA_TTABLE) {
                    os_log(.error, "hs.httpserver:setCallback() callbacks must return three values. A string for the response body, an integer response code, and a table of headers")
                    responseCode = 503
                    responseBody = Data("Callback handler returned invalid values".utf8)
                } else {
                    // Get response body as raw bytes
                    var bodyLen: Int = 0
                    if let bodyPtr = lua_tolstring(L, -3, &bodyLen) {
                        responseBody = Data(bytes: bodyPtr, count: bodyLen)
                    } else {
                        responseBody = Data()
                    }
                    responseCode = Int(lua_tointeger(L, -2))

                    var headerTypeError = false
                    lua_pushnil(L)
                    while lua_next(L, -2) != 0 {
                        if lua_type(L, -1) == LUA_TSTRING && lua_type(L, -2) == LUA_TSTRING {
                            let key = String(cString: lua_tostring(L, -2)!)
                            let value = String(cString: lua_tostring(L, -1)!)
                            responseHeaders[key] = value
                        } else {
                            headerTypeError = true
                        }
                        lua_pop(L, 1)
                    }
                    if headerTypeError {
                        os_log(.error, "hs.httpserver:setCallback() callback returned a header table that contains non-strings")
                    }
                }
                lua_pop(L, 3)
            }
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
            guard let cb = self.wsCallback else { return }

            let L = lua_getCurrentState()!
            cb.push(onto: L)
            lua_pushstring(L, message)

            if lua_pcall(L, 1, 1, 0) != LUA_OK {
                let errorMsg = lua_tostring(L, -1).map { String(cString: $0) } ?? "unknown error"
                os_log(.error, "hs.httpserver:websocket callback error: %{public}s", errorMsg)
                lua_pop(L, 1)
                return
            } else {
                if lua_type(L, -1) == LUA_TSTRING {
                    response = String(cString: lua_tostring(L, -1)!)
                }
            }

            lua_pop(L, 1)
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
private func httpserver_new(_ L: LuaState) throws -> CInt {

    let useSSL = (lua_type(L, 1) == LUA_TBOOLEAN) ? (lua_toboolean(L, 1) != 0) : false
    let useBonjour = (lua_type(L, 2) == LUA_TBOOLEAN) ? (lua_toboolean(L, 2) != 0) : true

    let server = HSHTTPServer()
    server.useSSL = useSSL
    server.useBonjour = useBonjour
    if useBonjour {
        server.setType("_http._tcp.")
    }

    L.push(userdata: server)
    return 1
}

// MARK: - Registration

@_cdecl("luaopen_hs_libhttpserver")
public func luaopen_hs_libhttpserver(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    L.register(Metatable<HSHTTPServer>(
        fields: [
            "start": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                lua_settop(L, 1)
                if server.fn == nil && server.wsCallback == nil {
                    os_log(.error, "hs.httpserver:start() called with no callback set. You must call hs.httpserver:setCallback() or hs.httpserver:websocket() first.")
                } else {
                    do {
                        try server.start()
                    } catch {
                        os_log(.error, "hs.httpserver:start() Unable to start object: %{public}s", "\(error)")
                    }
                }
                return 1
            },
            "stop": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                lua_settop(L, 1)
                server.stop()
                return 1
            },
            "getPort": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                lua_pushinteger(L, lua_Integer(server.listeningPort()))
                return 1
            },
            "setPort": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                server.setPort(UInt16(luaL_checkinteger(L, 2)))
                lua_pushvalue(L, 1)
                return 1
            },
            "getInterface": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                if let iface = server.interface() {
                    lua_pushstring(L, iface)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },
            "setInterface": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                if lua_isnoneornil(L, 2) {
                    server.setInterface(nil)
                } else {
                    server.setInterface(String(cString: luaL_checkstring(L, 2)))
                }
                lua_pushvalue(L, 1)
                return 1
            },
            "getName": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                if let name = server.name() {
                    lua_pushstring(L, name)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },
            "setName": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                server.setName(String(cString: luaL_checkstring(L, 2)))
                lua_pushvalue(L, 1)
                return 1
            },
            "setCallback": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                switch lua_type(L, 2) {
                case LUA_TFUNCTION:
                    server.fn = L.ref(index: 2)
                case LUA_TNIL, LUA_TNONE:
                    server.fn = nil
                default:
                    os_log(.error, "Unknown type passed to hs.httpserver:setCallback(). Argument must be a function or nil")
                }
                lua_pushvalue(L, 1)
                return 1
            },
            "setPassword": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                switch lua_type(L, 2) {
                case LUA_TNIL, LUA_TNONE:
                    server.httpPassword = nil
                case LUA_TSTRING:
                    server.httpPassword = String(cString: lua_tostring(L, 2)!)
                default:
                    os_log(.error, "Unknown type passed to hs.httpserver:setPassword(). Argument must be a string or nil")
                }
                lua_pushvalue(L, 1)
                return 1
            },
            "maxBodySize": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                if lua_gettop(L) == 2 {
                    server.maxBodySize = Int(lua_tointeger(L, 2))
                    lua_pushvalue(L, 1)
                } else {
                    lua_pushinteger(L, lua_Integer(server.maxBodySize))
                }
                return 1
            },
            "websocket": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                server.wsPath = String(cString: luaL_checkstring(L, 2))
                luaL_checktype(L, 3, LUA_TFUNCTION)
                server.wsCallback = L.ref(index: 3)
                lua_pushvalue(L, 1)
                return 1
            },
            "send": .closure { L in
                let server: HSHTTPServer = try L.checkArgument(1)
                if lua_type(L, 2) == LUA_TSTRING {
                    let msg = String(cString: lua_tostring(L, 2)!)
                    server.wsServer?.send(msg)
                }
                lua_pushvalue(L, 1)
                return 1
            },
        ],
        tostring: .closure { L in
            let server: HSHTTPServer = try L.checkArgument(1)
            let theName = server.name() ?? "unnamed"
            let thePort = server.listeningPort()
            let str = "\(USERDATA_TAG): \(theName):\(thePort) (\(String(describing: lua_topointer(L, 1)!)))"
            lua_pushstring(L, str)
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // LuaSwift's register() always installs its own gcUserdata as __gc, which
    // only deinitializes the Any box. We MUST replace it with a custom __gc
    // that first calls teardown() (stop the server, drop LuaValue callbacks)
    // and THEN deinitializes the Any box.
    L.pushMetatable(for: HSHTTPServer.self)

    // Replace __gc with our explicit teardown + deinitialize
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let server: HSHTTPServer = L.touserdata(1) {
            server.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.httpserver") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 1)
    L.push(httpserver_new)
    lua_setfield(L, -2, "new")

    return 1
}
