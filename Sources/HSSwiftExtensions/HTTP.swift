import Foundation
import CLua
import Lua
import Cocoa
import Carbon
import os.log
import WebKit

// MARK: - Module State

private var refTable: Int32 = 0
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
        let L = lua_getCurrentState()!

        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fn))
        lua_pushinteger(L, lua_Integer(httpResponse?.statusCode ?? 0))
        lua_pushany(L, responseBodyToId(httpResponse, receivedData as Data) as? NSObject)
        lua_pushany(L, httpResponse?.allHeaderFields as? NSDictionary)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }

        remove_delegate(L, self)
    }

    func connection(_ connection: NSURLConnection, didFailWithError error: Error) {
        if fn == LUA_NOREF { return }
        let L = lua_getCurrentState()!

        let errorMessage = "Connection failed: \(error.localizedDescription) - \((error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] ?? "")"
        lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fn))
        lua_pushinteger(L, -1)
        lua_pushany(L, errorMessage as NSString)
        if lua_pcall(L, 2, 0, 0) != LUA_OK { lua_pop(L, 1) }
        remove_delegate(L, self)
    }

    func connection(_ connection: NSURLConnection, willSend request: URLRequest, redirectResponse response: URLResponse?) -> URLRequest? {
        if fn == LUA_NOREF { return nil }

        if let httpResp = response as? HTTPURLResponse, !enableRedirect {
            let L = lua_getCurrentState()!

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(fn))
            lua_pushinteger(L, lua_Integer(httpResp.statusCode))
            lua_pushany(L, responseBodyToId(httpResponse, receivedData as Data) as? NSObject)
            lua_pushany(L, httpResp.allHeaderFields as NSDictionary)
            if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }

            remove_delegate(L, self)

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
    delegate.connection?.cancel()
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, delegate.fn)

    delegate.fn = LUA_NOREF
    delegates.remove(delegate)
}

// MARK: - Request Helpers

/// If the user specified a request body, get it from stack, add it to the request and add the content length header field
private func getBodyFromStack(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32, _ request: NSMutableURLRequest) {
    if !lua_isnoneornil(L, index) {
        var postData: Data?
        if lua_type(L, index) == LUA_TSTRING {
            // Get the raw bytes from the Lua string (preserving binary data)
            var len: Int = 0
            if let ptr = lua_tolstring(L, index, &len) {
                postData = Data(bytes: ptr, count: len)
            }
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
            os_log(.error, "%{public}s","hs.http - getBodyFromStack - non-nil entry at stack index \(index) but unable to convert to NSData")
        }
    }
}

/// Gets all information for the request from the stack and creates a request
private func getRequestFromStack(_ L: UnsafeMutablePointer<lua_State>!, _ cachePolicy: String?) -> NSMutableURLRequest {
    let url: String = lua_tovalue(L, at: 1) as! String
    let method: String = lua_tovalue(L, at: 2) as! String

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
private func http_doAsyncRequest(_ L: LuaState) throws -> CInt {

    var cachePolicy: String? = nil
    var enableRedirect = true
    if lua_type(L, 6) == LUA_TSTRING {
        cachePolicy = lua_tovalue(L, at: 6) as? String
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
    delegate.fn = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

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
///  * If you attempt to connect to a local Cosmic Hammer server created with `hs.httpserver`, then Cosmic Hammer will block until the connection times out (60 seconds), return a failed result due to the timeout, and then the `hs.httpserver` callback function will be invoked (so any side effects of the function will occur, but it's results will be lost).  Use [hs.http.doAsyncRequest](#doAsyncRequest) to avoid this.
///  * If the Content-Type response header begins `text/` then the response body return value is a UTF8 string. Any other content type passes the response body, unaltered, as a stream of bytes.
private func http_doRequest(_ L: LuaState) throws -> CInt {

    let cachePolicy: String? = lua_tovalue(L, at: 5) as? String

    let request = getRequestFromStack(L, cachePolicy)
    getBodyFromStack(L, 3, request)
    extractHeadersFromStack(L, 4, request)

    var response: URLResponse?
    let dataReply = try? NSURLConnection.sendSynchronousRequest(request as URLRequest, returning: &response)

    let httpResponse = response as? HTTPURLResponse

    lua_pushinteger(L, lua_Integer(httpResponse?.statusCode ?? 0))
    lua_pushany(L, responseBodyToId(httpResponse, dataReply) as? NSObject)
    lua_pushany(L, httpResponse?.allHeaderFields as? NSDictionary)

    return 3
}

// NOTE: this function is wrapped in init.lua
private func http_encodeForQuery(_ L: LuaState) throws -> CInt {
    _ = luaL_checkstring(L, 1)
    let value: String = lua_tovalue(L, at: 1) as! String

    let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    lua_pushany(L, encoded as NSString)
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
private func http_urlParts(_ L: LuaState) throws -> CInt {

    let theURL: NSURL
    if lua_type(L, 1) == LUA_TUSERDATA {
        // this only works if the userdata is an NSWindow or subclass with a contentView that is a WKWebView or subclass
        // hs.webview meets this criteria
        let ptr = lua_touserdata(L, 1)!.load(as: AnyObject.self)
        let theWindow = ptr as! NSWindow
        let theView = theWindow.contentView as! WKWebView
        theURL = theView.url! as NSURL
    } else {
        _ = luaL_checkstring(L, 1)
        theURL = NSURL(string: lua_tovalue(L, at: 1) as! String)!
    }

    lua_newtable(L)
    lua_pushany(L, theURL.absoluteString as NSString?);     lua_setfield(L, -2, "absoluteString")
    lua_pushany(L, theURL.absoluteURL as NSURL?);           lua_setfield(L, -2, "absoluteURL")
    lua_pushany(L, theURL.baseURL as NSURL?);               lua_setfield(L, -2, "baseURL")
    lua_pushstring(L, theURL.fileSystemRepresentation);        lua_setfield(L, -2, "fileSystemRepresentation")
    lua_pushany(L, theURL.fragment as NSString?);           lua_setfield(L, -2, "fragment")
    lua_pushany(L, theURL.host as NSString?);               lua_setfield(L, -2, "host")
    lua_pushany(L, theURL.lastPathComponent as NSString?);  lua_setfield(L, -2, "lastPathComponent")
    lua_pushany(L, theURL.parameterString as NSString?);    lua_setfield(L, -2, "parameterString")
    lua_pushany(L, theURL.password as NSString?);           lua_setfield(L, -2, "password")
    lua_pushany(L, theURL.path as NSString?);               lua_setfield(L, -2, "path")
    lua_pushany(L, theURL.pathComponents as NSArray?);      lua_setfield(L, -2, "pathComponents")
    lua_pushany(L, theURL.pathExtension as NSString?);      lua_setfield(L, -2, "pathExtension")
    lua_pushany(L, theURL.port);                            lua_setfield(L, -2, "port")
    lua_pushany(L, theURL.query as NSString?);              lua_setfield(L, -2, "query")
    lua_pushany(L, theURL.relativePath as NSString?);       lua_setfield(L, -2, "relativePath")
    lua_pushany(L, theURL.relativeString as NSString?);     lua_setfield(L, -2, "relativeString")
    lua_pushany(L, theURL.resourceSpecifier as NSString?);  lua_setfield(L, -2, "resourceSpecifier")
    lua_pushany(L, theURL.scheme as NSString?);             lua_setfield(L, -2, "scheme")
    lua_pushany(L, theURL.standardized as NSURL?);          lua_setfield(L, -2, "standardizedURL")
    lua_pushany(L, theURL.user as NSString?);               lua_setfield(L, -2, "user")
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
                        lua_pushany(L, value as NSString)
                        lua_setfield(L, -2, item.name)
                    } else {
                        lua_pushany(L, item.name as NSString)
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
    let theResponse = obj as! URLResponse

    lua_newtable(L)
    lua_pushinteger(L, lua_Integer(theResponse.expectedContentLength)); lua_setfield(L, -2, "expectedContentLength")
    lua_pushany(L, theResponse.suggestedFilename as NSString?);      lua_setfield(L, -2, "suggestedFilename")
    lua_pushany(L, theResponse.mimeType as NSString?);               lua_setfield(L, -2, "MIMEType")
    lua_pushany(L, theResponse.textEncodingName as NSString?);       lua_setfield(L, -2, "textEncodingName")
    lua_pushany(L, theResponse.url as NSURL?);                       lua_setfield(L, -2, "URL")

    if let httpResponse = obj as? HTTPURLResponse {
        lua_pushinteger(L, lua_Integer(httpResponse.statusCode)); lua_setfield(L, -2, "statusCode")
        lua_pushany(L, HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode) as NSString)
        lua_setfield(L, -2, "statusCodeDescription")
        lua_pushany(L, httpResponse.allHeaderFields as NSDictionary); lua_setfield(L, -2, "allHeaderFields")
    }

    return 1
}

private func NSURLRequest_toLua(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any) -> Int32 {
    let request = obj as! URLRequest

    lua_newtable(L)
    lua_pushany(L, request.mainDocumentURL as NSURL?);         lua_setfield(L, -2, "mainDocumentURL")
    lua_pushany(L, request.url as NSURL?);                     lua_setfield(L, -2, "URL")
    lua_pushany(L, request.allHTTPHeaderFields as NSDictionary?); lua_setfield(L, -2, "HTTPHeaderFields")
    lua_pushany(L, request.httpBody as NSData?);               lua_setfield(L, -2, "HTTPBody")
    lua_pushany(L, request.httpMethod as NSString?);           lua_setfield(L, -2, "HTTPMethod")

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
    var request = NSMutableURLRequest()

    lua_pushvalue(L, idx)
    switch lua_type(L, idx) {
    case LUA_TTABLE:
        if lua_getfield(L, -1, "URL") == LUA_TSTRING {
            request.url = URL(string: lua_tovalue(L, at: -1) as! String)
        } else {
            lua_pop(L, 2)
            os_log(.error, "%{public}s", "URL field missing in NSURLRequest table")
            return nil
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "mainDocumentURL") == LUA_TSTRING {
            request.mainDocumentURL = URL(string: lua_tovalue(L, at: -1) as! String)
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "HTTPBody") == LUA_TSTRING {
            var size: Int = 0
            let block = lua_tolstring(L, -1, &size)
            request.httpBody = Data(bytes: block!, count: size)
        }
        lua_pop(L, 1)

        if lua_getfield(L, -1, "HTTPMethod") == LUA_TSTRING {
            request.httpMethod = (lua_tovalue(L, at: -1) as? String) ?? "GET"
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
            let cp: String = lua_tovalue(L, at: -1) as! String
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
            let nst: String = lua_tovalue(L, at: -1) as! String
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
            if var fields = lua_tovalue(L, at: -1) as? [String: Any] {
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
        request = NSMutableURLRequest(url: URL(string: lua_tovalue(L, at: idx) as! String)!)

    default:
        os_log(.error, "%{public}s", "Unexpected type passed as a NSURLRequest: \(String(cString: lua_typename(L, lua_type(L, idx))))")
        lua_pop(L, 1)
        return nil
    }

    lua_pop(L, 1)
    return request
}

// MARK: - GC

private func http_gc(_ L: LuaState) throws -> CInt {
    let delegatesCopy = NSMutableArray(array: delegates)
    for delegate in delegatesCopy {
        remove_delegate(L, delegate as! ConnectionDelegate)
    }
    return 0
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libhttp")
public func luaopen_hs_libhttp(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        delegates = NSMutableArray()

        // Create ref table in registry
        lua_newtable(L)
        refTable = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        // Create module table
        lua_createtable(L, 0, 4)
        L.push(http_doRequest)
        lua_setfield(L, -2, "doRequest")
        L.push(http_doAsyncRequest)
        lua_setfield(L, -2, "doAsyncRequest")
        L.push(http_urlParts)
        lua_setfield(L, -2, "urlParts")
        L.push(http_encodeForQuery)
        lua_setfield(L, -2, "encodeForQuery")

        // Set module metatable (for __gc)
        lua_createtable(L, 0, 1)
        L.push(http_gc)
        lua_setfield(L, -2, "__gc")
        lua_setmetatable(L, -2)
    }
}
