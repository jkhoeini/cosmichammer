import Foundation
import CLua
import Cocoa
import Carbon

private struct WebSocketUserData {
    var selfRef: Int32
    var ws: UnsafeMutableRawPointer?
}

private let WS_USERDATA_TAG = "hs.websocket"
private var refTable: Int32 = LUA_NOREF

private func getWsUserData(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> HSWebSocketDelegate {
    let ud = lua_touserdata(L, idx)!.assumingMemoryBound(to: WebSocketUserData.self)
    return Unmanaged<HSWebSocketDelegate>.fromOpaque(ud.pointee.ws!).takeUnretainedValue()
}

// MARK: - HSWebSocketDelegate

private class HSWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var fn: Int32 = LUA_NOREF
    var webSocket: URLSessionWebSocketTask?
    var session: URLSession?
    var isOpen: Bool = false
    var stateGeneration: UInt64 = 0

    init(url: URL) {
        super.init()
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        webSocket = session?.webSocketTask(with: url)
        isOpen = false
    }

    func open() {
        webSocket?.resume()
        listenForMessages()
    }

    func listenForMessages() {
        weak let weakSelf = self
        webSocket?.receive { [weak weakSelf] result in
            guard let strongSelf = weakSelf else { return }
            if strongSelf.fn == LUA_NOREF { return }
            guard lua_isStateGenerationValid(strongSelf.stateGeneration) else { return }

            let L = lua_getCurrentState()!

            switch result {
            case .failure(let error):
                if strongSelf.isOpen { return }
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
                lua_rawgeti(L, -1, lua_Integer(strongSelf.fn))
                lua_remove(L, -2)
                lua_pushstring(L, "fail")
                lua_pushstring(L, error.localizedDescription)
                if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }

            case .success(let message):
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
                lua_rawgeti(L, -1, lua_Integer(strongSelf.fn))
                lua_remove(L, -2)
                lua_pushstring(L, "received")
                switch message {
                case .string(let text):
                    lua_pushstring(L, text)
                case .data(let data):
                    data.withUnsafeBytes { rawBuf in
                        lua_pushlstring(L, rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self), rawBuf.count)
                    }
                @unknown default:
                    lua_pushnil(L)
                }
                if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }

                strongSelf.listenForMessages()
            }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isOpen = true
        if fn == LUA_NOREF { return }
        guard lua_isStateGenerationValid(self.stateGeneration) else { return }
        let L = lua_getCurrentState()!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
        lua_rawgeti(L, -1, lua_Integer(fn))
        lua_remove(L, -2)
        lua_pushstring(L, "open")
        if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        isOpen = false
        if fn == LUA_NOREF { return }
        guard lua_isStateGenerationValid(self.stateGeneration) else { return }
        let L = lua_getCurrentState()!
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
        lua_rawgeti(L, -1, lua_Integer(fn))
        lua_remove(L, -2)
        lua_pushstring(L, "closed")
        if lua_pcall(L, 1, 0, 0) != LUA_OK { lua_pop(L, 1) }
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
private func websocket_new(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let urlString = String(cString: luaL_checkstring(L, 1))
    luaL_checktype(L, 2, LUA_TFUNCTION)
    let ws = HSWebSocketDelegate(url: URL(string: urlString)!)
    ws.stateGeneration = lua_currentStateGeneration()

    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
    lua_pushvalue(L, 2)
    ws.fn = luaL_ref(L, -2)
    lua_pop(L, 1)

    ws.open()

    let userData = lua_newuserdata(L, MemoryLayout<WebSocketUserData>.size)!
        .assumingMemoryBound(to: WebSocketUserData.self)
    memset(userData, 0, MemoryLayout<WebSocketUserData>.size)
    userData.pointee.ws = Unmanaged.passRetained(ws).toOpaque()
    luaL_getmetatable(L, WS_USERDATA_TAG)
    lua_setmetatable(L, -2)

    return 1
}

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
private func websocket_send(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ws = getWsUserData(L, 1)
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

    lua_pushvalue(L, 1)
    return 1
}

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
private func websocket_status(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ws = getWsUserData(L, 1)

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
}

/// hs.websocket:close() -> object
/// Method
/// Closes a websocket connection.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The `hs.websocket` object
private func websocket_close(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ws = getWsUserData(L, 1)

    ws.webSocket?.cancel(with: .normalClosure, reason: nil)

    lua_pushvalue(L, 1)
    return 1
}

private func websocket_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let userData = lua_touserdata(L, 1)!.assumingMemoryBound(to: WebSocketUserData.self)
    let ws = Unmanaged<HSWebSocketDelegate>.fromOpaque(userData.pointee.ws!).takeRetainedValue()
    userData.pointee.ws = nil

    ws.webSocket?.cancel(with: .normalClosure, reason: nil)
    ws.webSocket = nil
    ws.session?.invalidateAndCancel()
    ws.session = nil
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(refTable))
    luaL_unref(L, -1, ws.fn); ws.fn = LUA_NOREF
    lua_pop(L, 1)

    return 0
}

private func websocket_tostring(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let ws = getWsUserData(L, 1)
    let host = ws.isOpen ? "connected" : "disconnected"
    let str = "\(WS_USERDATA_TAG): \(host) (\(String(describing: lua_topointer(L, 1)!)))"
    lua_pushstring(L, str)
    return 1
}

private var websocketlib: [luaL_Reg] = [
    luaL_Reg(name: strdup("new"), func: websocket_new),
    luaL_Reg(name: nil, func: nil),
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: nil, func: nil),
]

private var wsMetalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("send"), func: websocket_send),
    luaL_Reg(name: strdup("close"), func: websocket_close),
    luaL_Reg(name: strdup("status"), func: websocket_status),
    luaL_Reg(name: strdup("__tostring"), func: websocket_tostring),
    luaL_Reg(name: strdup("__gc"), func: websocket_gc),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libwebsocket")
public func luaopen_hs_libwebsocket(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    // Create ref table in registry
    lua_newtable(L)
    refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Register userdata metatable
    luaL_newmetatable(L, WS_USERDATA_TAG)
    lua_pushvalue(L, -1)
    lua_setfield(L, -2, "__index")  // mt.__index = mt
    luaL_setfuncs(L, &wsMetalib, 0)
    lua_pop(L, 1)

    // Create module table
    lua_createtable(L, 0, Int32(websocketlib.count - 1))
    luaL_setfuncs(L, &websocketlib, 0)

    // Set module metatable (for __gc)
    lua_createtable(L, 0, Int32(metalib.count - 1))
    luaL_setfuncs(L, &metalib, 0)
    lua_setmetatable(L, -2)

    return 1
}
