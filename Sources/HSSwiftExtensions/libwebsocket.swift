import Foundation
import Cocoa
import Carbon
import LuaSkin

private struct WebSocketUserData {
    var selfRef: Int32
    var ws: UnsafeMutableRawPointer?
}

private let WS_USERDATA_TAG = "hs.websocket"
private var refTable: Int32 = 0

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

            switch result {
            case .failure(let error):
                if strongSelf.isOpen { return }
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: strongSelf.fn)
                skin.pushNSObject("fail" as NSString)
                skin.pushNSObject(error.localizedDescription as NSString)
                skin.protectedCallAndError("hs.websocket callback", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)

            case .success(let message):
                let skin = LuaSkin.skin(with: nil)
                _lua_stackguard_entry(skin.l)
                skin.pushLuaRef(refTable, ref: strongSelf.fn)
                skin.pushNSObject("received" as NSString)
                switch message {
                case .string(let text):
                    skin.pushNSObject(text as NSString)
                case .data(let data):
                    skin.pushNSObject(data as NSData)
                @unknown default:
                    lua_pushnil(skin.l)
                }
                skin.protectedCallAndError("hs.websocket callback", nargs: 2, nresults: 0)
                _lua_stackguard_exit(skin.l)

                strongSelf.listenForMessages()
            }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isOpen = true
        if fn == LUA_NOREF { return }
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        skin.pushLuaRef(refTable, ref: fn)
        skin.pushNSObject("open" as NSString)
        skin.protectedCallAndError("hs.websocket callback", nargs: 1, nresults: 0)
        _lua_stackguard_exit(skin.l)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        isOpen = false
        if fn == LUA_NOREF { return }
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)
        skin.pushLuaRef(refTable, ref: fn)
        skin.pushNSObject("closed" as NSString)
        skin.protectedCallAndError("hs.websocket callback", nargs: 1, nresults: 0)
        _lua_stackguard_exit(skin.l)
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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TFUNCTION, LS_TBREAK)

    let urlString = skin.toNSObject(atIndex: 1) as! String
    let ws = HSWebSocketDelegate(url: URL(string: urlString)!)

    lua_pushvalue(L, 2)
    ws.fn = skin.luaRef(refTable)

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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, WS_USERDATA_TAG, LS_TSTRING, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let ws = getWsUserData(L, 1)

    let isData: Bool = (lua_gettop(L) > 2) ? (lua_toboolean(L, 3) != 0) : true

    let options: LS_NSConversionOptions = isData ? .nsLuaStringAsDataOnly : .nsPreserveLuaStringExactly

    let message: URLSessionWebSocketTask.Message
    if isData {
        let data = skin.toNSObject(atIndex: 2, withOptions: options) as! Data
        message = .data(data)
    } else {
        let str = skin.toNSObject(atIndex: 2, withOptions: options) as! String
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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, WS_USERDATA_TAG, LS_TBREAK)
    let ws = getWsUserData(L, 1)

    switch ws.webSocket?.state {
    case .running:
        skin.pushNSObject((ws.isOpen ? "open" : "connecting") as NSString)
    case .canceling:
        skin.pushNSObject("closing" as NSString)
    case .completed:
        skin.pushNSObject("closed" as NSString)
    default:
        skin.pushNSObject("unknown" as NSString)
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
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TUSERDATA, WS_USERDATA_TAG, LS_TBREAK)
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
    ws.fn = LuaSkin.skin(with: L).luaUnref(refTable, ref: ws.fn)

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
    let skin = LuaSkin.skin(with: L)

    refTable = skin.registerLibrary(WS_USERDATA_TAG, functions: &websocketlib, metaFunctions: &metalib)
    skin.registerObject(WS_USERDATA_TAG, objectFunctions: &wsMetalib)

    return 1
}
