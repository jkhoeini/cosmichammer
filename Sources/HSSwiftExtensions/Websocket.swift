import Foundation
import CLua
import Lua
import Cocoa

private let WS_USERDATA_TAG = "hs.websocket"

// MARK: - HSWebSocketDelegate

private class HSWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var callback: LuaValue?
    var webSocket: URLSessionWebSocketTask?
    var session: URLSession?
    // Lua state and websocket lifecycle flags are owned by the main run loop.
    // URLSession delegate callbacks must use performLuaWork before touching them.
    var isOpen: Bool = false
    var isExplicitlyClosing: Bool = false
    var stateGeneration: UInt64 = 0
    private var tornDown = false
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(url: URL) {
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        webSocket = session?.webSocketTask(with: url)
        isOpen = false
    }

    /// Idempotent teardown: cancel the websocket, invalidate the session,
    /// drop the Lua callback reference.  Called from __gc while the
    /// lua_State is still alive.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        close()
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        callback = nil
    }

    func open() {
        webSocket?.resume()
        listenForMessages()
    }

    func listenForMessages() {
        webSocket?.receive { [weak self] result in
            guard let strongSelf = self else { return }

            switch result {
            case .failure(let error):
                strongSelf.performLuaWork { [weak strongSelf] in
                    guard let strongSelf, !strongSelf.isOpen, !strongSelf.isExplicitlyClosing else { return }
                    strongSelf.invokeLuaCallback { L in
                        lua_pushstring(L, "fail")
                        lua_pushstring(L, error.localizedDescription)
                        return 2
                    }
                }

            case .success(let message):
                strongSelf.performLuaWork { [weak strongSelf] in
                    guard let strongSelf, !strongSelf.isExplicitlyClosing else { return }
                    strongSelf.invokeLuaCallback { L in
                        lua_pushstring(L, "received")
                        switch message {
                        case .string(let text):
                            lua_pushstring(L, text)
                        case .data(let data):
                            data.withUnsafeBytes { rawBuf in
                                _ = lua_pushlstring(L, rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self), rawBuf.count)
                            }
                        @unknown default:
                            lua_pushnil(L)
                        }
                        return 2
                    }
                    strongSelf.listenForMessages()
                }
            }
        }
    }

    private func performLuaWork(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            // The Lua host pumps the main run loop; DispatchQueue.main.async is
            // not reliably drained by the Swift test harness polling loop.
            RunLoop.main.perform(work)
        }
    }

    private func invokeLuaCallback(pushArguments: (UnsafeMutablePointer<lua_State>) -> Int32) {
        guard let cb = callback else { return }
        guard lua_isStateGenerationValid(stateGeneration) else { return }
        guard let L = lua_getCurrentState() else { return }
        cb.push(onto: L)
        let argumentCount = pushArguments(L)
        if lua_pcall(L, argumentCount, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        performLuaWork { [weak self] in
            guard let self else { return }
            guard !isExplicitlyClosing else { return }
            isOpen = true
            invokeLuaCallback { L in
                lua_pushstring(L, "open")
                return 1
            }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        performLuaWork { [weak self] in
            guard let self else { return }
            isOpen = false
            invokeLuaCallback { L in
                lua_pushstring(L, "closed")
                return 1
            }
        }
    }

    func close() {
        isExplicitlyClosing = true
        webSocket?.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Module Functions

/// hs.websocket.new(url, callback) -> object
/// Function
/// Creates a new websocket connection.
///
/// Parameters:
///  * url - The URL to the websocket
///  * callback - A function that's triggered by websocket actions.
///
/// Returns:
///  * The `hs.websocket` object
///
/// Notes:
///  * The callback should accept two parameters.
///  * The first parameter is a string with the following possible options:
///    * open - The websocket connection has been opened
///    * closed - The websocket connection has been closed
///    * fail - The websocket connection has failed
///    * received - The websocket has received a message
///    * pong - A pong request has been received
///  * The second parameter is a string with the received message or an error message.
///  * Given a path '/mysock' and a port of 8000, the websocket URL is as follows:
///    * ws://localhost:8000/mysock
///    * wss://localhost:8000/mysock (if SSL enabled)
private func websocket_new(_ L: LuaState) throws -> CInt {
    let urlString = String(cString: luaL_checkstring(L, 1))
    luaL_checktype(L, 2, LUA_TFUNCTION)
    let ws = HSWebSocketDelegate(url: URL(string: urlString)!)
    ws.stateGeneration = lua_currentStateGeneration()
    ws.callback = L.ref(index: 2)
    ws.open()
    L.push(userdata: ws)
    return 1
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libwebsocket")
public func luaopen_hs_libwebsocket(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    L.register(Metatable<HSWebSocketDelegate>(
        fields: [
            /// hs.websocket:send(message[, isData]) -> object
            /// Method
            /// Sends a message to the websocket client.
            ///
            /// Parameters:
            ///  * message - A string containing the message to send.
            ///  * isData - An optional boolean that sends the message as binary data (defaults to true).
            ///
            /// Returns:
            ///  * The `hs.websocket` object
            ///
            /// Notes:
            ///  * Forcing a text representation by setting isData to `false` may alter the data if it
            ///   contains invalid UTF8 character sequences (the default string behavior is to make
            ///   sure everything is "printable" by converting invalid sequences into the Unicode
            ///   Invalid Character sequence).
            "send": .closure { L in
                let ws: HSWebSocketDelegate = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TSTRING)
                let isData: Bool = (lua_gettop(L) > 2) ? (lua_toboolean(L, 3) != 0) : true
                let message: URLSessionWebSocketTask.Message
                if isData {
                    var len: Int = 0
                    let ptr = lua_tolstring(L, 2, &len)!
                    let data = Data(bytes: ptr, count: len)
                    message = .data(data)
                } else {
                    let str = String(cString: lua_tostring(L, 2)!)
                    message = .string(str)
                }
                ws.webSocket?.send(message) { _ in }
                lua_settop(L, 1)
                return 1
            },
            /// hs.websocket:close() -> object
            /// Method
            /// Closes a websocket connection.
            ///
            /// Parameters:
            ///  * None
            ///
            /// Returns:
            ///  * The `hs.websocket` object
            "close": .closure { L in
                let ws: HSWebSocketDelegate = try L.checkArgument(1)
                ws.close()
                lua_settop(L, 1)
                return 1
            },
            /// hs.websocket:status() -> string
            /// Method
            /// Gets the status of a websocket.
            ///
            /// Parameters:
            ///  * None
            ///
            /// Returns:
            ///  * A string containing one of the following options:
            ///   * connecting
            ///   * open
            ///   * closing
            ///   * closed
            ///   * unknown
            "status": .closure { L in
                let ws: HSWebSocketDelegate = try L.checkArgument(1)
                switch ws.webSocket?.state {
                case .running:
                    lua_pushstring(L, ws.isOpen ? "open" : "connecting")
                case .canceling:
                    lua_pushstring(L, "closing")
                case .completed:
                    lua_pushstring(L, "closed")
                default:
                    lua_pushstring(L, "unknown")
                }
                return 1
            },
        ],
        tostring: .closure { L in
            let ws: HSWebSocketDelegate = try L.checkArgument(1)
            let host = ws.isOpen ? "connected" : "disconnected"
            lua_pushstring(L, "\(WS_USERDATA_TAG): \(host) (\(lua_topointer(L, 1)!))")
            return 1
        }
    ))

    // Post-registration: custom __gc that calls teardown() before deinitializing the Any box
    L.pushMetatable(for: HSWebSocketDelegate.self)
    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let ws: HSWebSocketDelegate = L.touserdata(1) {
            ws.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        let anyPtr = rawptr.assumingMemoryBound(to: Any.self)
        anyPtr.deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for lsunit.lua assertIsUserdataOfType and tostring
    lua_pushstring(L, WS_USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    lua_pushstring(L, WS_USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name so that
    // core_getObjectMetatable("hs.websocket") still resolves.
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, WS_USERDATA_TAG)

    // Module table
    lua_createtable(L, 0, 1)
    L.push(websocket_new)
    lua_setfield(L, -2, "new")

    return 1
}
