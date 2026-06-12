import Cocoa
import CLua
import Lua
import os.log

private let USERDATA_TAG = "hs.sharing"

// MARK: - Support Functions and Classes

private func toNSURLFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> NSURL? {
    let absIdx = lua_absindex(L, idx)

    if lua_type(L, absIdx) == LUA_TSTRING {
        let str = lua_tovalue(L, at: absIdx) as! String
        return NSURL(string: str)
    } else if lua_type(L, absIdx) == LUA_TTABLE {
        if lua_getfield(L, absIdx, "url") == LUA_TSTRING {
            let str = lua_tovalue(L, at: -1) as! String
            lua_pop(L, 1)
            return NSURL(string: str)
        }
        lua_pop(L, 1)
    }

    os_log(.error, "%{public}s", "expected string or table describing an NSURL, found \(String(cString: lua_typename(L, lua_type(L, absIdx))))")
    return nil
}

func sharingItemFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Any? {
    let absIdx = lua_absindex(L, idx)

    if lua_type(L, absIdx) == LUA_TUSERDATA {
        if let image = toNSImage(L, at: absIdx) { return image }
        if let styledText = toNSAttributedString(L, at: absIdx) { return styledText }
        return nil
    }

    if lua_type(L, absIdx) == LUA_TTABLE {
        var isURL = false
        if lua_getfield(L, absIdx, "__luaSkinType") == LUA_TSTRING,
           let typeName = lua_tostring(L, -1),
           String(cString: typeName) == "NSURL" {
            isURL = true
        }
        lua_pop(L, 1)

        if !isURL {
            isURL = lua_getfield(L, absIdx, "url") == LUA_TSTRING
            lua_pop(L, 1)
        }

        if isURL {
            return toNSURLFromLua(L, absIdx)
        }
    }

    return lua_tovalue(L, at: absIdx)
}

func sharingItemsFromLua(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> [Any]? {
    let absIdx = lua_absindex(L, idx)
    guard lua_type(L, absIdx) == LUA_TTABLE else { return nil }

    var items: [Any] = []
    let count = Int(luaL_len(L, absIdx))
    if count == 0 { return items }

    for i in 1...count {
        lua_rawgeti(L, absIdx, lua_Integer(i))
        guard let item = sharingItemFromLua(L, -1) else {
            lua_pop(L, 1)
            return nil
        }
        items.append(item)
        lua_pop(L, 1)
    }
    return items
}

func pushSharingImageOrNil(_ L: UnsafeMutablePointer<lua_State>!, _ image: NSImage?) {
    guard let image, NSImage_tolua(L, image) == 1 else {
        lua_pushnil(L)
        return
    }
}

func pushSharingItem(_ L: UnsafeMutablePointer<lua_State>!, _ item: Any?) {
    switch item {
    case let image as NSImage:
        pushSharingImageOrNil(L, image)
    case let styledText as NSAttributedString:
        _ = NSAttributedString_toLua(L, obj: styledText)
    case let url as NSURL:
        pushNSURL(L, obj: url)
    case let url as URL:
        pushNSURL(L, obj: url as NSURL)
    default:
        lua_pushany(L, item)
    }
}

func pushSharingItems(_ L: UnsafeMutablePointer<lua_State>!, _ items: [Any]) {
    lua_newtable(L)
    for (idx, item) in items.enumerated() {
        pushSharingItem(L, item)
        lua_rawseti(L, -2, lua_Integer(idx + 1))
    }
}

func pushSharingURLs(_ L: UnsafeMutablePointer<lua_State>!, _ urls: [URL]?) {
    guard let urls else {
        lua_pushnil(L)
        return
    }

    lua_newtable(L)
    for (idx, url) in urls.enumerated() {
        pushNSURL(L, obj: url as NSURL)
        lua_rawseti(L, -2, lua_Integer(idx + 1))
    }
}

// MARK: - HSSharingService

class HSSharingService: NSObject, NSSharingServiceDelegate {
    var sharingService: NSSharingService?
    var callback: LuaValue?
    var generation: UInt64 = 0
    private var tornDown = false

    init(serviceName: String) {
        super.init()
        sharingService = NSSharingService(named: NSSharingService.Name(rawValue: serviceName))
        if sharingService != nil {
            sharingService!.delegate = self
        }
    }

    /// Idempotent teardown: drop the Lua callback reference, clear the delegate,
    /// and nil out the sharing service.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        callback = nil
        sharingService?.delegate = nil
        sharingService = nil
    }

    // MARK: NSSharingServiceDelegate

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard callback != nil else { return }
        if !lua_isStateGenerationValid(generation) {
            teardown()
            return
        }
        let L = lua_getCurrentState()!
        callback!.push(onto: L)
        L.push(userdata: self)
        lua_pushany(L, "didFail" as NSString)
        pushSharingItems(L, items)
        lua_pushany(L, error.localizedDescription as NSString)
        if lua_pcall(L, 4, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard callback != nil else { return }
        if !lua_isStateGenerationValid(generation) {
            teardown()
            return
        }
        let L = lua_getCurrentState()!
        callback!.push(onto: L)
        L.push(userdata: self)
        lua_pushany(L, "didShare" as NSString)
        pushSharingItems(L, items)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }

    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        guard callback != nil else { return }
        if !lua_isStateGenerationValid(generation) {
            teardown()
            return
        }
        let L = lua_getCurrentState()!
        callback!.push(onto: L)
        L.push(userdata: self)
        lua_pushany(L, "willShare" as NSString)
        pushSharingItems(L, items)
        if lua_pcall(L, 3, 0, 0) != LUA_OK { lua_pop(L, 1) }
    }
}

// MARK: - Module Constants

private func pushBuiltinSharingServices(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_newtable(L)
    lua_pushany(L, NSSharingService.Name.addToAperture.rawValue as NSString);             lua_setfield(L, -2, "addToAperture")
    lua_pushany(L, NSSharingService.Name.addToIPhoto.rawValue as NSString);               lua_setfield(L, -2, "addToIPhoto")
    lua_pushany(L, NSSharingService.Name.addToSafariReadingList.rawValue as NSString);    lua_setfield(L, -2, "addToSafariReadingList")
    lua_pushany(L, NSSharingService.Name.composeEmail.rawValue as NSString);              lua_setfield(L, -2, "composeEmail")
    lua_pushany(L, NSSharingService.Name.composeMessage.rawValue as NSString);            lua_setfield(L, -2, "composeMessage")
    lua_pushany(L, NSSharingService.Name.sendViaAirDrop.rawValue as NSString);            lua_setfield(L, -2, "sendViaAirDrop")
    lua_pushany(L, NSSharingService.Name.useAsDesktopPicture.rawValue as NSString);       lua_setfield(L, -2, "useAsDesktopPicture")
    return 1
}

// MARK: - Lua<->NSObject Conversion

@discardableResult
private func pushNSURL(_ L: UnsafeMutablePointer<lua_State>!, obj: Any!) -> Int32 {
    let url = obj as! NSURL
    lua_newtable(L)
    lua_pushany(L, url.absoluteString as NSString?)
    lua_setfield(L, -2, "url")
    if url.isFileURL {
        lua_pushany(L, url.path as NSString?)
        lua_setfield(L, -2, "filePath")
    }
    lua_pushstring(L, "NSURL")
    lua_setfield(L, -2, "__luaSkinType")
    return 1
}

private func toNSURLFromLuaHelper(_ L: UnsafeMutablePointer<lua_State>!, idx: Int32) -> Any! {
    return toNSURLFromLua(L, idx)
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_libsharing")
public func luaopen_hs_libsharing(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    L.register(Metatable<HSSharingService>(
        fields: [
            // hs.sharing:shareItems(items) -> sharingObject
            "shareItems": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TTABLE)

                guard let items = sharingItemsFromLua(L, 2) else {
                    throw LuaCallError("bad argument #2 (unrecognized element in array)")
                }

                if wrapper.sharingService?.canPerform(withItems: items) ?? false {
                    if let error: String = catchingObjCException({
                        wrapper.sharingService?.perform(withItems: items)
                    }) {
                        os_log(.error, "caught ObjC exception in NSSharingService.perform: \(error, privacy: .public)")
                        lua_pushnil(L)
                    } else {
                        lua_pushvalue(L, 1)
                    }
                } else {
                    lua_pushnil(L)
                }
                return 1
            },

            // hs.sharing:canShareItems(items) -> boolean
            "canShareItems": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                luaL_checktype(L, 2, LUA_TTABLE)

                guard let items = sharingItemsFromLua(L, 2) else {
                    throw LuaCallError("bad argument #2 (unrecognized element in array)")
                }

                lua_pushboolean(L, (wrapper.sharingService?.canPerform(withItems: items) ?? false) ? 1 : 0)
                return 1
            },

            // hs.sharing:callback(fn) -> sharingObject
            "callback": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)

                wrapper.callback = nil
                if lua_type(L, 2) == LUA_TFUNCTION {
                    wrapper.callback = L.ref(index: 2)
                }
                lua_pushvalue(L, 1)
                return 1
            },

            // hs.sharing:recipients([recipients]) -> current value | sharingObject
            "recipients": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)

                if lua_gettop(L) == 1 {
                    lua_pushany(L, wrapper.sharingService?.recipients as NSArray?)
                } else {
                    guard let recipients = lua_tovalue(L, at: 2) as? [Any] else {
                        throw LuaCallError("bad argument #2 (expected table of strings)")
                    }

                    for (idx, obj) in recipients.enumerated() {
                        if !(obj is String) {
                            throw LuaCallError("bad argument #2 (expected string at index \(idx + 1))")
                        }
                    }

                    wrapper.sharingService?.recipients = recipients as? [String]
                    lua_pushvalue(L, 1)
                }
                return 1
            },

            // hs.sharing:subject([subject]) -> current value | sharingObject
            "subject": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)

                if lua_gettop(L) == 1 {
                    if let subject = wrapper.sharingService?.subject {
                        lua_pushany(L, subject as NSString)
                    } else {
                        lua_pushnil(L)
                    }
                } else {
                    wrapper.sharingService?.subject = lua_tovalue(L, at: 2) as? String
                    lua_pushvalue(L, 1)
                }
                return 1
            },

            // hs.sharing:attachments() -> table | nil
            "attachments": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                pushSharingURLs(L, wrapper.sharingService?.attachmentFileURLs)
                return 1
            },

            // hs.sharing:accountName() -> string | nil
            "accountName": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                if let name = wrapper.sharingService?.accountName {
                    lua_pushany(L, name as NSString)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },

            // hs.sharing:messageBody() -> string | nil
            "messageBody": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                if let body = wrapper.sharingService?.messageBody {
                    lua_pushany(L, body as NSString)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },

            // hs.sharing:title() -> string
            "title": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                lua_pushany(L, wrapper.sharingService?.title as NSString?)
                return 1
            },

            // hs.sharing:serviceName() -> string
            "serviceName": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)

                var label: String?
                if let service = wrapper.sharingService, service.responds(to: NSSelectorFromString("name")) {
                    label = service.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String
                }

                if let l = label {
                    lua_pushany(L, l as NSString)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },

            // hs.sharing:permanentLink() -> URL table | nil
            "permanentLink": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                if let url = wrapper.sharingService?.permanentLink {
                    pushNSURL(L, obj: url)
                } else {
                    lua_pushnil(L)
                }
                return 1
            },

            // hs.sharing:alternateImage() -> hs.image object | nil
            "alternateImage": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                pushSharingImageOrNil(L, wrapper.sharingService?.alternateImage)
                return 1
            },

            // hs.sharing:image() -> hs.image object | nil
            "image": .closure { L in
                let wrapper: HSSharingService = try L.checkArgument(1)
                pushSharingImageOrNil(L, wrapper.sharingService?.image)
                return 1
            },
        ],
        eq: .closure { L in
            let obj1: HSSharingService = try L.checkArgument(1)
            let obj2: HSSharingService = try L.checkArgument(2)
            lua_pushboolean(L, obj1.isEqual(obj2) ? 1 : 0)
            return 1
        },
        tostring: .closure { L in
            let obj: HSSharingService = try L.checkArgument(1)
            let title = obj.sharingService?.title ?? "unknown"
            lua_pushstring(L, "\(USERDATA_TAG): \(title) (\(String(describing: lua_topointer(L, 1)!)))")
            return 1
        }
    ))

    // -- Post-registration metatable patching --
    // Replace __gc with custom teardown + deinitialize
    L.pushMetatable(for: HSSharingService.self)

    lua_pushcclosure(L, { (L: LuaState!) -> CInt in
        if let obj: HSSharingService = L.touserdata(1) {
            obj.teardown()
        }
        let rawptr = lua_touserdata(L, 1)!
        rawptr.assumingMemoryBound(to: Any.self).deinitialize(count: 1)
        return 0
    }, 0)
    lua_setfield(L, -2, "__gc")

    // Set __type and __name for compat
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__type")
    lua_pushstring(L, USERDATA_TAG)
    lua_setfield(L, -2, "__name")

    // Alias the metatable under the legacy registry name
    lua_setfield(L, LUA_REGISTRYINDEX_VALUE, USERDATA_TAG)

    // Create module table
    lua_createtable(L, 0, 4)

    // hs.sharing.newShare(type) -> sharingObject
    L.push({ (L: LuaState) throws -> CInt in
        luaL_checktype(L, 1, LUA_TSTRING)
        let serviceName = lua_tovalue(L, at: 1) as! String
        let wrapper = HSSharingService(serviceName: serviceName)

        if wrapper.sharingService != nil {
            wrapper.generation = lua_currentStateGeneration()
            L.push(userdata: wrapper)
        } else {
            lua_pushnil(L)
        }
        return 1
    })
    lua_setfield(L, -2, "newShare")

    // hs.sharing.shareTypesFor(items) -> identifiersTable
    L.push({ (L: LuaState) throws -> CInt in
        var items: [Any]?
        if lua_gettop(L) == 1 {
            guard let arr = sharingItemsFromLua(L, 1) else {
                throw LuaCallError("bad argument #1 (unrecognized element in array)")
            }
            items = arr
        }

        lua_newtable(L)
        let services = NSSharingService.sharingServices(forItems: items ?? [])
        for aService in services {
            var label: String?
            if aService.responds(to: NSSelectorFromString("name")) {
                label = catchingObjCException {
                    aService.perform(NSSelectorFromString("name"))?.takeUnretainedValue() as? String
                }
            }
            if label == nil { label = aService.title }
            lua_pushany(L, (label ?? "") as NSString)
            lua_rawseti(L, -2, luaL_len(L, -2) + 1)
        }
        return 1
    })
    lua_setfield(L, -2, "shareTypesFor")

    // hs.sharing.URL(URL, [fileURL]) -> table
    L.push({ (L: LuaState) throws -> CInt in
        let shouldBeFileURL = lua_gettop(L) == 2 ? (lua_toboolean(L, 2) != 0) : false

        var theURL: NSURL?
        if shouldBeFileURL && lua_type(L, 1) == LUA_TSTRING {
            let path = lua_tovalue(L, at: 1) as! String
            if !path.hasPrefix("file:") && !path.hasPrefix("FILE:") {
                theURL = NSURL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            }
        }

        if theURL == nil {
            theURL = toNSURLFromLua(L, 1)
        }

        if let url = theURL {
            pushNSURL(L, obj: url)
        } else {
            lua_pushnil(L)
        }
        return 1
    })
    lua_setfield(L, -2, "URL")

    _ = pushBuiltinSharingServices(L)
    lua_setfield(L, -2, "builtinSharingServices")

    return 1
}
