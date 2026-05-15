import Foundation
import Cocoa
import Carbon
import LuaSkin
import WebKit

// MARK: - Module State

private var refTable: LSRefTable = 0
private var delegates: NSMutableArray = NSMutableArray()

// MARK: - Helper Functions

/// Convert a response body to data we can send to Lua
private func responseBodyToId(_ httpResponse: HTTPURLResponse?, _ bodyData: Data?) -> Any? {
    guard let httpResponse = httpResponse, let bodyData = bodyData else { return bodyData }
    let contentType = httpResponse.allHeaderFields["Content-Type"] as? String ?? ""

    // If the response falls in the text/* content type, convert it to a string, otherwise
    // leave it as raw data
    if contentType.hasPrefix("text/") {
        return String(data: bodyData, encoding: .utf8)
    }
    return bodyData
}

// MARK: - Connection Delegate

/// Definition of the connection delegate to receive callbacks from NSURLConnection
@objc private class ConnectionDelegate: NSObject, NSURLConnectionDelegate, NSURLConnectionDataDelegate {
    var fn: Int32 = LUA_NOREF
    var enableRedirect: Bool = true
    var receivedData: NSMutableData = NSMutableData()
    var httpResponse: HTTPURLResponse?
    var connection: NSURLConnection?

    func connection(_ connection: NSURLConnection, didReceive response: URLResponse) {
        receivedData.length = 0
        httpResponse = response as? HTTPURLResponse
    }

    func connection(_ connection: NSURLConnection, didReceive data: Data) {
        receivedData.append(data)
    }

    func connectionDidFinishLoading(_ connection: NSURLConnection) {
        if fn == LUA_NOREF { return }
        let skin = LuaSkin.skin(with: nil)
        let L = skin.l!
        _lua_stackguard_entry(L)

        skin.pushLuaRef(refTable, ref: fn)
        lua_pushinteger(L, lua_Integer(httpResponse?.statusCode ?? 0))
        skin.pushNSObject(responseBodyToId(httpResponse, receivedData as Data) as? NSObject)
        skin.pushNSObject(httpResponse?.allHeaderFields as? NSDictionary)
        skin.protectedCallAndError("hs.http connectionDelegate:didFinishLoading", nargs: 3, nresults: 0)

        remove_delegate(L, self)
        _lua_stackguard_exit(L)
    }

    func connection(_ connection: NSURLConnection, didFailWithError error: Error) {
        if fn == LUA_NOREF { return }
        let skin = LuaSkin.skin(with: nil)
        _lua_stackguard_entry(skin.l)

        let errorMessage = "Connection failed: \(error.localizedDescription) - \((error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] ?? "")"
        skin.pushLuaRef(refTable, ref: fn)
        lua_pushinteger(skin.l, -1)
        skin.pushNSObject(errorMessage as NSString)
        skin.protectedCallAndError("hs.http connectionDelegate:didFailWithError", nargs: 2, nresults: 0)
        remove_delegate(skin.l, self)
        _lua_stackguard_exit(skin.l)
    }

    func connection(_ connection: NSURLConnection, willSend request: URLRequest, redirectResponse response: URLResponse?) -> URLRequest? {
        if fn == LUA_NOREF { return nil }

        if let httpResp = response as? HTTPURLResponse, !enableRedirect {
            let skin = LuaSkin.skin(with: nil)
            let L = skin.l!
            _lua_stackguard_entry(L)

            skin.pushLuaRef(refTable, ref: fn)
            lua_pushinteger(L, lua_Integer(httpResp.statusCode))
            skin.pushNSObject(responseBodyToId(httpResponse, receivedData as Data) as? NSObject)
            skin.pushNSObject(httpResp.allHeaderFields as NSDictionary)
            skin.protectedCallAndError("hs.http connectionDelegate:didFinishLoading during redirection", nargs: 3, nresults: 0)

            remove_delegate(L, self)
            _lua_stackguard_exit(L)

            connection.cancel()
            return nil
        }

        return request
    }
}

// MARK: - Delegate Storage

/// Store a created delegate so we can cancel it on garbage collection
private func store_delegate(_ delegate: ConnectionDelegate) {
    delegates.add(delegate)
}

/// Remove a delegate either if loading has finished or if it needs to be garbage collected.
private func remove_delegate(_ L: UnsafeMutablePointer<lua_State>!, _ delegate: ConnectionDelegate) {
    let skin = LuaSkin.skin(with: L)
    delegate.connection?.cancel()
    delegate.fn = skin.luaUnref(refTable, ref: delegate.fn)
    delegates.remove(delegate)
}

// MARK: - Request Helpers

/// If the user specified a request body, get it from stack, add it to the request and add the content length header field
private func getBodyFromStack(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32, _ request: NSMutableURLRequest) {
    if !lua_isnoneornil(L, index) {
        var postData: Data?
        if lua_type(L, index) == LUA_TSTRING {
            postData = LuaSkin.skin(with: L).toNSObject(atIndex: index, withOptions: .nsLuaStringAsDataOnly) as? Data
        } else {
            if let cstr = lua_tostring(L, index),
               let body = String(cString: cstr, encoding: .ascii) {
                postData = body.data(using: .ascii, allowLossyConversion: true)
            }
        }
        if let postData = postData {
            let postLength = "\(postData.count)"
            request.setValue(postLength, forHTTPHeaderField: "Content-Length")
            request.httpBody = postData
        } else {
            LuaSkin.skin(with: nil).logError("hs.http - getBodyFromStack - non-nil entry at stack index \(index) but unable to convert to NSData")
        }
    }
}

/// Gets all information for the request from the stack and creates a request
private func getRequestFromStack(_ L: UnsafeMutablePointer<lua_State>!, _ cachePolicy: String?) -> NSMutableURLRequest {
    let skin = LuaSkin.skin(with: L)
    let url: String = skin.toNSObject(atIndex: 1) as! String
    let method: String = skin.toNSObject(atIndex: 2) as! String

    let selectedCachePolicy: NSURLRequest.CachePolicy
    switch cachePolicy {
    case "protocolCachePolicy":        selectedCachePolicy = .useProtocolCachePolicy
    case "ignoreLocalCache":           selectedCachePolicy = .reloadIgnoringLocalCacheData
    case "ignoreLocalAndRemoteCache":  selectedCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    case "returnCacheOrLoad":          selectedCachePolicy = .returnCacheDataElseLoad
    case "returnCacheDontLoad":        selectedCachePolicy = .returnCacheDataDontLoad
    case "reloadRevalidatingCache":    selectedCachePolicy = .reloadRevalidatingCacheData
    default:                           selectedCachePolicy = .useProtocolCachePolicy
    }

    let request = NSMutableURLRequest(
        url: URL(string: url)!,
        cachePolicy: selectedCachePolicy,
        timeoutInterval: 60.0
    )
    request.httpMethod = method
    return request
}

/// Gets the table for the headers from stack and adds the key value pairs to the request object
private func extractHeadersFromStack(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32, _ request: NSMutableURLRequest) {
    if !lua_isnoneornil(L, index) {
        lua_pushnil(L)
        while lua_next(L, index) != 0 {
            let key = String(cString: luaL_checkstring(L, -2))
            let value = String(cString: luaL_checkstring(L, -1))
            request.setValue(value, forHTTPHeaderField: key)
            lua_pop(L, 1)
        }
    }
}

// MARK: - Module Functions

/// hs.http.doAsyncRequest(url, method, data, headers, callback, [cachePolicy|enableRedirect])
/// Function
/// Creates an HTTP request and executes it asynchronously
///
/// Parameters:
///  * url - A string containing the URL
///  * method - A string containing the HTTP method to use (e.g. "GET", "POST", etc)
///  * data - A string containing the request body, or nil to send no body
///  * headers - A table containing string keys and values representing request header keys and values, or nil to add no headers
///  * callback - A function to called when the response is received. The function should accept three arguments:
///   * code - A number containing the HTTP response code
///   * body - A string containing the body of the response
///   * headers - A table containing the HTTP headers of the response
///  * cachePolicy - An optional string containing the cache policy ("protocolCachePolicy", "ignoreLocalCache", "ignoreLocalAndRemoteCache", "returnCacheOrLoad", "returnCacheDontLoad" or "reloadRevalidatingCache"). Defaults to `protocolCachePolicy`.
///  * enableRedirect - An optional boolean to indicate whether to redirect the http request. Defaults to true.
///
/// Returns:
///  * None
///
/// Notes:
///  * If authentication is required in order to download the request, the required credentials must be specified as part of the URL (e.g. "http://user:password@host.com/"). If authentication fails, or credentials are missing, the connection will attempt to continue without credentials.
///  * If the Content-Type response header begins `text/` then the response body return value is a UTF8 string. Any other content type passes the response body, unaltered, as a stream of bytes.
///  * If enableRedirect is set to true, response body will be empty string. Http body will be dropped even though response has the body. This seems the limitation of 'connection:willSendRequest:redirectResponse' method.
private func http_doAsyncRequest(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TSTRING | LS_TNIL, LS_TTABLE | LS_TNIL, LS_TFUNCTION, LS_TSTRING | LS_TBOOLEAN | LS_TOPTIONAL, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)

    var cachePolicy: String? = nil
    var enableRedirect = true
    if lua_type(L, 6) == LUA_TSTRING {
        cachePolicy = skin.toNSObject(atIndex: 6) as? String
    } else if lua_type(L, 6) == LUA_TBOOLEAN {
        enableRedirect = lua_toboolean(L, 6) != 0
    }
    if lua_type(L, 7) == LUA_TBOOLEAN {
        enableRedirect = lua_toboolean(L, 7) != 0
    }

    let request = getRequestFromStack(L, cachePolicy)
    getBodyFromStack(L, 3, request)
    extractHeadersFromStack(L, 4, request)

    luaL_checktype(L, 5, LUA_TFUNCTION)
    lua_pushvalue(L, 5)

    let delegate = ConnectionDelegate()
    delegate.enableRedirect = enableRedirect
    delegate.receivedData = NSMutableData()
    delegate.fn = skin.luaRef(refTable)

    store_delegate(delegate)

    let connection = NSURLConnection(request: request as URLRequest, delegate: delegate)
    delegate.connection = connection

    return 0
}

/// hs.http.doRequest(url, method, [data, headers, cachePolicy]) -> int, string, table
/// Function
/// Creates an HTTP request and executes it synchronously
///
/// Parameters:
///  * url - A string containing the URL
///  * method - A string containing the HTTP method to use (e.g. "GET", "POST", etc)
///  * data - An optional string containing the data to POST to the URL, or nil to send no data
///  * headers - An optional table of string keys and values used as headers for the request, or nil to add no headers
///  * cachePolicy - An optional string containing the cache policy ("protocolCachePolicy", "ignoreLocalCache", "ignoreLocalAndRemoteCache", "returnCacheOrLoad", "returnCacheDontLoad" or "reloadRevalidatingCache"). Defaults to `protocolCachePolicy`.
///
/// Returns:
///  * A number containing the HTTP response status code
///  * A string containing the response body
///  * A table containing the response headers
///
/// Notes:
///  * If authentication is required in order to download the request, the required credentials must be specified as part of the URL (e.g. "http://user:password@host.com/"). If authentication fails, or credentials are missing, the connection will attempt to continue without credentials.
///
///  * This function is synchronous and will therefore block all Lua execution until it completes. You are encouraged to use the asynchronous functions.
///  * If you attempt to connect to a local Hammerspoon server created with `hs.httpserver`, then Hammerspoon will block until the connection times out (60 seconds), return a failed result due to the timeout, and then the `hs.httpserver` callback function will be invoked (so any side effects of the function will occur, but it's results will be lost).  Use [hs.http.doAsyncRequest](#doAsyncRequest) to avoid this.
///  * If the Content-Type response header begins `text/` then the response body return value is a UTF8 string. Any other content type passes the response body, unaltered, as a stream of bytes.
private func http_doRequest(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TSTRING | LS_TNIL | LS_TOPTIONAL, LS_TTABLE | LS_TNIL | LS_TOPTIONAL, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)

    let cachePolicy: String? = skin.toNSObject(atIndex: 5) as? String

    let request = getRequestFromStack(L, cachePolicy)
    getBodyFromStack(L, 3, request)
    extractHeadersFromStack(L, 4, request)

    var response: URLResponse?
    let dataReply = try? NSURLConnection.sendSynchronousRequest(request as URLRequest, returning: &response)

    let httpResponse = response as? HTTPURLResponse

    lua_pushinteger(L, lua_Integer(httpResponse?.statusCode ?? 0))
    skin.pushNSObject(responseBodyToId(httpResponse, dataReply) as? NSObject)
    skin.pushNSObject(httpResponse?.allHeaderFields as? NSDictionary)

    return 3
}

// NOTE: this function is wrapped in init.lua
private func http_encodeForQuery(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    luaL_checkstring(L, 1)
    let value: String = skin.toNSObject(atIndex: 1) as! String

    let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    skin.pushNSObject(encoded as NSString)
    return 1
}

/// hs.http.urlParts(url) -> table
/// Function
/// Returns a table of keys containing the individual components of the provided url.
///
/// Parameters:
///  * url - the url to parse into it's individual components
///
/// Returns:
///  * a table containing any of the following keys which apply to the specified url:
///    * absoluteString           - The URL string for the URL as an absolute URL.
///    * absoluteURL              - An absolute URL that refers to the same resource as the provided URL.
///    * baseURL                  - the base URL, if the URL is relative
///    * fileSystemRepresentation - the URL's unescaped path specified as a file system path
///    * fragment                 - the fragment, if specified in the URL
///    * host                     - the host for the URL
///    * isFileURL                - a boolean value indicating whether or not the URL represents a local file
///    * lastPathComponent        - the last path component specified in the URL
///    * parameterString          - the parameter string, if specified in the URL
///    * password                 - the password, if specified in the URL
///    * path                     - the unescaped path specified in the URL
///    * pathComponents           - an array containing the path components of the URL
///    * pathExtension            - the file extension, if specified in the URL
///    * port                     - the port, if specified in the URL
///    * query                    - the query, if specified in the URL
///    * queryItems               - if the URL contains a query string, then this field contains an array of the unescaped key-value pairs for each item.
///    * relativePath             - the relative path of the URL without resolving against its base URL.
///    * relativeString           - a string representation of the relative portion of the URL.
///    * resourceSpecifier        - the resource specified in the URL
///    * scheme                   - the scheme of the URL
///    * standardizedURL          - the URL with any instances of ".." or "." removed from its path
///    * user                     - the username, if specified in the URL
private func http_urlParts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    let theURL: NSURL
    if lua_type(L, 1) == LUA_TUSERDATA {
        // this only works if the userdata is an NSWindow or subclass with a contentView that is a WKWebView or subclass
        // hs.webview meets this criteria
        let ptr = lua_touserdata(L, 1)!.load(as: AnyObject.self)
        let theWindow = ptr as! NSWindow
        let theView = theWindow.contentView as! WKWebView
        theURL = theView.url! as NSURL
    } else {
        luaL_checkstring(L, 1)
        theURL = NSURL(string: skin.toNSObject(atIndex: 1) as! String)!
    }

    lua_newtable(L)
    skin.pushNSObject(theURL.absoluteString as NSString?);     lua_setfield(L, -2, "absoluteString")
    skin.pushNSObject(theURL.absoluteURL as NSURL?);           lua_setfield(L, -2, "absoluteURL")
    skin.pushNSObject(theURL.baseURL as NSURL?);               lua_setfield(L, -2, "baseURL")
    lua_pushstring(L, theURL.fileSystemRepresentation);        lua_setfield(L, -2, "fileSystemRepresentation")
    skin.pushNSObject(theURL.fragment as NSString?);           lua_setfield(L, -2, "fragment")
    skin.pushNSObject(theURL.host as NSString?);               lua_setfield(L, -2, "host")
    skin.pushNSObject(theURL.lastPathComponent as NSString?);  lua_setfield(L, -2, "lastPathComponent")
    skin.pushNSObject(theURL.parameterString as NSString?);    lua_setfield(L, -2, "parameterString")
    skin.pushNSObject(theURL.password as NSString?);           lua_setfield(L, -2, "password")
    skin.pushNSObject(theURL.path as NSString?);               lua_setfield(L, -2, "path")
    skin.pushNSObject(theURL.pathComponents as NSArray?);      lua_setfield(L, -2, "pathComponents")
    skin.pushNSObject(theURL.pathExtension as NSString?);      lua_setfield(L, -2, "pathExtension")
    skin.pushNSObject(theURL.port);                            lua_setfield(L, -2, "port")
    skin.pushNSObject(theURL.query as NSString?);              lua_setfield(L, -2, "query")
    skin.pushNSObject(theURL.relativePath as NSString?);       lua_setfield(L, -2, "relativePath")
    skin.pushNSObject(theURL.relativeString as NSString?);     lua_setfield(L, -2, "relativeString")
    skin.pushNSObject(theURL.resourceSpecifier as NSString?);  lua_setfield(L, -2, "resourceSpecifier")
    skin.pushNSObject(theURL.scheme as NSString?);             lua_setfield(L, -2, "scheme")
    skin.pushNSObject(theURL.standardized as NSURL?);          lua_setfield(L, -2, "standardizedURL")
    skin.pushNSObject(theURL.user as NSString?);               lua_setfield(L, -2, "user")
    lua_pushboolean(L, theURL.isFileURL ? 1 : 0);             lua_setfield(L, -2, "isFileURL")

    if theURL.query != nil {
        if var components = URLComponents(url: theURL as URL, resolvingAgainstBaseURL: true) {
            // NSQueryItem doesn't properly handle + as space in a query string.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")

            lua_newtable(L)
            if let queryItems = components.queryItems {
                for item in queryItems {
                    lua_newtable(L)
                    if let value = item.value {
                        skin.pushNSObject(value as NSString)
                        lua_setfield(L, -2, item.name)
                    } else {
                        skin.pushNSObject(item.name as NSString)
                        lua_rawseti(L, -2, 1)
                    }
                    lua_rawseti(L, -2, luaL_len(L, -2) + 1)
                }
            }
            lua_setfield(L, -2, "queryItems")
        }
    }

    return 1
}

// MARK: - Push/Convert Helpers

// not used here yet... but they are used in hs.webview. This seems a more logical location for them.

private func NSURLResponse_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let theResponse = obj as! URLResponse

    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(theResponse.expectedContentLength)); lua_setfield(L, -2, "expectedContentLength")
    skin.pushNSObject(theResponse.suggestedFilename as NSString?);      lua_setfield(L, -2, "suggestedFilename")
    skin.pushNSObject(theResponse.mimeType as NSString?);               lua_setfield(L, -2, "MIMEType")
    skin.pushNSObject(theResponse.textEncodingName as NSString?);       lua_setfield(L, -2, "textEncodingName")
    skin.pushNSObject(theResponse.url as NSURL?);                       lua_setfield(L, -2, "URL")

    if let httpResponse = obj as? HTTPURLResponse {
        lua_pushinteger(L, lua_Integer(httpResponse.statusCode)); lua_setfield(L, -2, "statusCode")
        skin.pushNSObject(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode) as NSString)
        lua_setfield(L, -2, "statusCodeDescription")
        skin.pushNSObject(httpResponse.allHeaderFields as NSDictionary); lua_setfield(L, -2, "allHeaderFields")
    }

    return 1
}

private func NSURLRequest_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let request = obj as! URLRequest

    lua_newtable(L)
    skin.pushNSObject(request.mainDocumentURL as NSURL?);         lua_setfield(L, -2, "mainDocumentURL")
    skin.pushNSObject(request.url as NSURL?);                     lua_setfield(L, -2, "URL")
    skin.pushNSObject(request.allHTTPHeaderFields as NSDictionary?); lua_setfield(L, -2, "HTTPHeaderFields")
    skin.pushNSObject(request.httpBody as NSData?);               lua_setfield(L, -2, "HTTPBody")
    skin.pushNSObject(request.httpMethod as NSString?);           lua_setfield(L, -2, "HTTPMethod")

    lua_pushnumber(L, lua_Number(request.timeoutInterval));       lua_setfield(L, -2, "timeoutInterval")
    lua_pushboolean(L, request.httpShouldHandleCookies ? 1 : 0); lua_setfield(L, -2, "HTTPShouldHandleCookies")
    lua_pushboolean(L, request.httpShouldUsePipelining ? 1 : 0); lua_setfield(L, -2, "HTTPShouldUsePipelining")

    let cachePolicyStr: String
    switch request.cachePolicy {
    case .useProtocolCachePolicy:       cachePolicyStr = "protocolCachePolicy"
    case .reloadIgnoringLocalCacheData: cachePolicyStr = "ignoreLocalCache"
    case .returnCacheDataElseLoad:      cachePolicyStr = "returnCacheOrLoad"
    case .returnCacheDataDontLoad:      cachePolicyStr = "returnCacheDontLoad"
    default:                            cachePolicyStr = "unknown"
    }
    lua_pushstring(L, cachePolicyStr); lua_setfield(L, -2, "cachePolicy")

    let networkServiceStr: String
    switch request.networkServiceType {
    case .default:    networkServiceStr = "default"
    case .voip:       networkServiceStr = "VoIP"
    case .video:      networkServiceStr = "video"
    case .background: networkServiceStr = "background"
    case .voice:      networkServiceStr = "voice"
    default:          networkServiceStr = "unknown"
    }
    lua_pushstring(L, networkServiceStr); lua_setfield(L, -2, "networkServiceType")

    return 1
}

private func table_toNSURLRequest(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    let skin = LuaSkin.skin(with: L)
    var request = NSMutableURLRequest()

    lua_pushvalue(L, idx)
    switch lua_type(L, idx) {
    case LUA_TTABLE:
        if lua_getfield(L, -1, "URL") == LUA_TSTRING {
            request.url = URL(string: skin.toNSObject(atIndex: -1) as! String)
        } else {
            lua_pop(L, 2)
            skin.logError("URL field missing in NSURLRequest table")
            return nil
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "mainDocumentURL") == LUA_TSTRING {
            request.mainDocumentURL = URL(string: skin.toNSObject(atIndex: -1) as! String)
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "HTTPBody") == LUA_TSTRING {
            var size: Int = 0
            let block = lua_tolstring(L, -1, &size)
            request.httpBody = Data(bytes: block!, count: size)
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "HTTPMethod") == LUA_TSTRING {
            request.httpMethod = (skin.toNSObject(atIndex: -1) as? String) ?? "GET"
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "timeoutInterval") == LUA_TNUMBER {
            request.timeoutInterval = lua_tonumber(L, -1)
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "HTTPShouldHandleCookies") == LUA_TBOOLEAN {
            request.httpShouldHandleCookies = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "HTTPShouldUsePipelining") == LUA_TBOOLEAN {
            request.httpShouldUsePipelining = lua_toboolean(L, -1) != 0
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "cachePolicy") == LUA_TSTRING {
            let cp: String = skin.toNSObject(atIndex: -1) as! String
            switch cp {
            case "protocolCachePolicy": request.cachePolicy = .useProtocolCachePolicy
            case "ignoreLocalCache":    request.cachePolicy = .reloadIgnoringLocalCacheData
            case "returnCacheOrLoad":   request.cachePolicy = .returnCacheDataElseLoad
            case "returnCacheDontLoad": request.cachePolicy = .returnCacheDataDontLoad
            default: break
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "networkServiceType") == LUA_TSTRING {
            let nst: String = skin.toNSObject(atIndex: -1) as! String
            switch nst {
            case "default":    request.networkServiceType = .default
            case "VoIP":       request.networkServiceType = .voip
            case "video":      request.networkServiceType = .video
            case "background": request.networkServiceType = .background
            case "voice":      request.networkServiceType = .voice
            default: break
            }
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "HTTPHeaderFields") == LUA_TTABLE {
            if var fields = skin.toNSObject(atIndex: -1) as? [String: Any] {
                var toRemove = [String]()

                for (key, value) in fields {
                    if let numValue = value as? NSNumber {
                        fields[key] = numValue.stringValue
                    }

                    guard let strValue = fields[key] as? String else {
                        toRemove.append(key)
                        continue
                    }

                    let reservedHeaders = ["Authorization", "Connection", "Host", "WWW-Authenticate", "Content-Length"]
                    for reserved in reservedHeaders {
                        if key.caseInsensitiveCompare(reserved) == .orderedSame {
                            toRemove.append(key)
                            break
                        }
                    }
                }

                for item in toRemove { fields.removeValue(forKey: item) }
                request.allHTTPHeaderFields = fields as? [String: String]
            }
        }
        lua_pop(L, 1)

    case LUA_TSTRING:
        request = NSMutableURLRequest(url: URL(string: skin.toNSObject(atIndex: idx) as! String)!)

    default:
        skin.logError("Unexpected type passed as a NSURLRequest: \(String(cString: lua_typename(L, lua_type(L, idx))))")
        lua_pop(L, 1)
        return nil
    }

    lua_pop(L, 1)
    return request
}

// MARK: - GC

private func http_gc(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let delegatesCopy = NSMutableArray(array: delegates)
    for delegate in delegatesCopy {
        remove_delegate(L, delegate as! ConnectionDelegate)
    }
    return 0
}

// MARK: - C Callback Wrappers

private let http_doRequest_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in http_doRequest(L) }
private let http_doAsyncRequest_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in http_doAsyncRequest(L) }
private let http_urlParts_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in http_urlParts(L) }
private let http_encodeForQuery_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in http_encodeForQuery(L) }
private let http_gc_C: @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32 = { L in http_gc(L) }

// Push/convert helper blocks for LuaSkin registration
private let NSURLRequest_toLua_block: pushNSHelperFunction = { L, obj in NSURLRequest_toLua(L!, obj!) }
private let NSURLResponse_toLua_block: pushNSHelperFunction = { L, obj in NSURLResponse_toLua(L!, obj!) }
private let table_toNSURLRequest_block: luaObjectHelperFunction = { L, idx in table_toNSURLRequest(L!, idx) as AnyObject? }

// MARK: - Module Registration

private var httplib: [luaL_Reg] = [
    luaL_Reg(name: strdup("doRequest"),      func: http_doRequest_C),
    luaL_Reg(name: strdup("doAsyncRequest"), func: http_doAsyncRequest_C),
    luaL_Reg(name: strdup("urlParts"),       func: http_urlParts_C),
    luaL_Reg(name: strdup("encodeForQuery"), func: http_encodeForQuery_C),
    luaL_Reg(name: nil, func: nil),
]

private var metalib: [luaL_Reg] = [
    luaL_Reg(name: strdup("__gc"), func: http_gc_C),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libhttp")
public func luaopen_hs_libhttp(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)

    delegates = NSMutableArray()
    refTable = skin.registerLibrary("hs.http", functions: &httplib, metaFunctions: &metalib)

    skin.registerPushNSHelper(NSURLRequest_toLua_block, forClass: "NSURLRequest")
    skin.registerPushNSHelper(NSURLResponse_toLua_block, forClass: "NSURLResponse")
    skin.registerLuaObjectHelper(table_toNSURLRequest_block, forClass: "NSURLRequest")

    return 1
}
