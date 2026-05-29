import LuaSkin

// MARK: - LuaSkin Swift Bridge

extension LuaSkin {
    static func skin(with L: UnsafeMutablePointer<lua_State>!) -> LuaSkin {
        shared(with: L) as! LuaSkin
    }

    func checkArgs(_ specs: Any...) {
        let L = self.l
        var idx: Int32 = 1
        var i = 0

        while i < specs.count {
            if let tag = specs[i] as? String {
                i += 1
                continue
            }
            guard let spec = specs[i] as? Int32 else { i += 1; continue }

            if spec & LS_TBREAK != 0 {
                if spec & LS_TVARARG == 0 {
                    let numArgs = lua_gettop(L)
                    if numArgs > idx - 1 {
                        lua_pushstring(L, "ERROR: incorrect number of arguments. Expected \(idx - 1), got \(numArgs)")
                        lua_error(L)
                    }
                }
                break
            }

            let luaType = lua_type(L, idx)

            if spec & LS_TANY != 0 && luaType != LUA_TNONE {
                idx += 1
                i += 1
                if spec & LS_TUSERDATA != 0, i < specs.count, specs[i] is String { i += 1 }
                continue
            }

            var lsType: Int32 = 0
            switch luaType {
            case LUA_TNONE:
                if spec & LS_TOPTIONAL != 0 {
                    idx += 1
                    i += 1
                    if spec & LS_TUSERDATA != 0, i < specs.count, specs[i] is String { i += 1 }
                    continue
                }
                lsType = LS_TNIL
            case LUA_TNIL:          lsType = LS_TNIL
            case LUA_TBOOLEAN:      lsType = LS_TBOOLEAN
            case LUA_TNUMBER:       lsType = LS_TNUMBER
            case LUA_TSTRING:       lsType = LS_TSTRING
            case LUA_TTABLE:        lsType = LS_TTABLE
            case LUA_TFUNCTION:     lsType = LS_TFUNCTION
            case LUA_TUSERDATA:     lsType = LS_TUSERDATA
            case LUA_TLIGHTUSERDATA: lsType = LS_TUSERDATA
            default:                lsType = 0
            }

            if spec & lsType == 0 && spec & LS_TOPTIONAL == 0 {
                let typeName = String(cString: lua_typename(L, luaType))
                lua_pushstring(L, "ERROR: incorrect type '\(typeName)' for argument \(idx)")
                lua_error(L)
            }

            if spec & LS_TUSERDATA != 0, i + 1 < specs.count, let tag = specs[i + 1] as? String {
                if luaType == LUA_TUSERDATA {
                    tag.withCString { cstr in
                        if luaL_testudata(L, idx, cstr) == nil && spec & LS_TOPTIONAL == 0 {
                            lua_pushstring(L, "ERROR: incorrect userdata type for argument \(idx)")
                            lua_error(L)
                        }
                    }
                }
                i += 1
            }

            idx += 1
            i += 1
        }
    }

    func toNSObject(atIndex idx: Int32) -> Any? {
        toNSObject(at: idx)
    }

    func toNSObject(atIndex idx: Int32, withOptions options: LS_NSConversionOptions) -> Any? {
        toNSObject(at: idx, withOptions: UInt(options.rawValue))
    }

    func logError(_ message: String) {
        log(atLevel: Int32(LS_LOG_ERROR), withMessage: message)
    }

    func logWarn(_ message: String) {
        log(atLevel: Int32(LS_LOG_WARN), withMessage: message)
    }

    func logDebug(_ message: String) {
        log(atLevel: Int32(LS_LOG_DEBUG), withMessage: message)
    }

    func logInfo(_ message: String) {
        log(atLevel: Int32(LS_LOG_INFO), withMessage: message)
    }

    func logVerbose(_ message: String) {
        log(atLevel: Int32(LS_LOG_VERBOSE), withMessage: message)
    }

    func logBreadcrumb(_ message: String) {
        log(atLevel: Int32(LS_LOG_BREADCRUMB), withMessage: message)
    }
}

// MARK: - Free-standing wrappers (keeps LuaSkin out of extension files)

/// Validate Lua argument types at the top of a module function.
func lsCheckArgs(_ L: UnsafeMutablePointer<lua_State>!, _ specs: Any...) {
    let skin = LuaSkin.skin(with: L)
    // Forward to the variadic-style checkArgs implemented above.
    // We replicate the logic here because Swift cannot splat an array into
    // a variadic parameter.
    let specArray = specs
    var idx: Int32 = 1
    var i = 0
    while i < specArray.count {
        if let tag = specArray[i] as? String {
            i += 1
            continue
        }
        guard let spec = specArray[i] as? Int32 else { i += 1; continue }
        if spec & LS_TBREAK != 0 {
            if spec & LS_TVARARG == 0 {
                let numArgs = lua_gettop(L)
                if numArgs > idx - 1 {
                    lua_pushstring(L, "ERROR: incorrect number of arguments. Expected \(idx - 1), got \(numArgs)")
                    lua_error(L)
                }
            }
            break
        }
        let luaType = lua_type(L, idx)
        if spec & LS_TANY != 0 && luaType != LUA_TNONE {
            idx += 1; i += 1
            if spec & LS_TUSERDATA != 0, i < specArray.count, specArray[i] is String { i += 1 }
            continue
        }
        var lsType: Int32 = 0
        switch luaType {
        case LUA_TNONE:
            if spec & LS_TOPTIONAL != 0 {
                idx += 1; i += 1
                if spec & LS_TUSERDATA != 0, i < specArray.count, specArray[i] is String { i += 1 }
                continue
            }
            lsType = LS_TNIL
        case LUA_TNIL:          lsType = LS_TNIL
        case LUA_TBOOLEAN:      lsType = LS_TBOOLEAN
        case LUA_TNUMBER:       lsType = LS_TNUMBER
        case LUA_TSTRING:       lsType = LS_TSTRING
        case LUA_TTABLE:        lsType = LS_TTABLE
        case LUA_TFUNCTION:     lsType = LS_TFUNCTION
        case LUA_TUSERDATA:     lsType = LS_TUSERDATA
        case LUA_TLIGHTUSERDATA: lsType = LS_TUSERDATA
        default:                lsType = 0
        }
        if spec & lsType == 0 && spec & LS_TOPTIONAL == 0 {
            let typeName = String(cString: lua_typename(L, luaType))
            lua_pushstring(L, "ERROR: incorrect type '\(typeName)' for argument \(idx)")
            lua_error(L)
        }
        if spec & LS_TUSERDATA != 0, i + 1 < specArray.count, let tag = specArray[i + 1] as? String {
            if luaType == LUA_TUSERDATA {
                tag.withCString { cstr in
                    if luaL_testudata(L, idx, cstr) == nil && spec & LS_TOPTIONAL == 0 {
                        lua_pushstring(L, "ERROR: incorrect userdata type for argument \(idx)")
                        lua_error(L)
                    }
                }
            }
            i += 1
        }
        idx += 1; i += 1
    }
}

/// Push an NSObject onto the Lua stack via LuaSkin's ObjC bridge.
func lsPushNSObject(_ L: UnsafeMutablePointer<lua_State>!, _ obj: Any?) {
    LuaSkin.skin(with: L).pushNSObject(obj)
}

/// Convert a Lua value at the given stack index to an NSObject via LuaSkin.
func lsToNSObject(_ L: UnsafeMutablePointer<lua_State>!, atIndex idx: Int32) -> Any? {
    LuaSkin.skin(with: L).toNSObject(atIndex: idx)
}

/// Convert a Lua value at the given stack index to an NSObject with options.
func lsToNSObject(_ L: UnsafeMutablePointer<lua_State>!, atIndex idx: Int32, withOptions options: LS_NSConversionOptions) -> Any? {
    LuaSkin.skin(with: L).toNSObject(atIndex: idx, withOptions: options)
}

/// Convert a Lua userdata at the given stack index to an NSObject of the given class.
func lsLuaObjectAtIndex(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, toClass cls: String) -> Any? {
    LuaSkin.skin(with: L).luaObject(at: idx, toClass: cls)
}

/// Push a Lua reference onto the stack.
func lsPushLuaRef(_ L: UnsafeMutablePointer<lua_State>!, _ refTable: Int32, ref: Int32) {
    LuaSkin.skin(with: L).pushLuaRef(refTable, ref: ref)
}

/// Release a Lua reference.  Returns LUA_NOREF.
@discardableResult
func lsLuaUnref(_ L: UnsafeMutablePointer<lua_State>!, _ refTable: Int32, ref: Int32) -> Int32 {
    LuaSkin.skin(with: L).luaUnref(refTable, ref: ref)
}

/// Log a warning through the LuaSkin logging delegate.
func lsLogWarn(_ L: UnsafeMutablePointer<lua_State>!, _ message: String) {
    LuaSkin.skin(with: L).logWarn(message)
}

// MARK: - Lua C Macros (not importable to Swift)

func lua_tonumber(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> lua_Number {
    lua_tonumberx(L, idx, nil)
}

func lua_tointeger(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> lua_Integer {
    lua_tointegerx(L, idx, nil)
}

func lua_pop(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) {
    lua_settop(L, -(n) - 1)
}

func lua_newtable(_ L: UnsafeMutablePointer<lua_State>!) {
    lua_createtable(L, 0, 0)
}

func lua_isnil(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TNIL
}

func lua_isstring(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TSTRING
}

func lua_isnumber(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TNUMBER
}

func lua_isboolean(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TBOOLEAN
}

func lua_istable(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TTABLE
}

func lua_isfunction(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TFUNCTION
}

func lua_isuserdata(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TUSERDATA
}

func lua_islightuserdata(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TLIGHTUSERDATA
}

func lua_tostring(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafePointer<CChar>? {
    lua_tolstring(L, idx, nil)
}

func lua_pcall(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32, _ r: Int32, _ f: Int32) -> Int32 {
    lua_pcallk(L, n, r, f, 0, nil)
}

func lua_pushcfunction(_ L: UnsafeMutablePointer<lua_State>!, _ f: lua_CFunction!) {
    lua_pushcclosure(L, f, 0)
}

func lua_register(_ L: UnsafeMutablePointer<lua_State>!, _ n: UnsafePointer<CChar>!, _ f: lua_CFunction!) {
    lua_pushcfunction(L, f)
    lua_setglobal(L, n)
}

let LUA_REGISTRYINDEX_VALUE: Int32 = -1001000

func lua_upvalueindex(_ i: Int32) -> Int32 {
    LUA_REGISTRYINDEX_VALUE - i
}

func luaL_dostring(_ L: UnsafeMutablePointer<lua_State>!, _ s: UnsafePointer<CChar>!) -> Int32 {
    let r = luaL_loadstring(L, s)
    return r != 0 ? r : lua_pcall(L, 0, LUA_MULTRET, 0)
}

func luaL_checkstring(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> UnsafePointer<CChar>! {
    luaL_checklstring(L, n, nil)
}

@discardableResult
func luaL_error(_ L: UnsafeMutablePointer<lua_State>!, _ fmt: String) -> Int32 {
    lua_pushstring(L, fmt)
    return lua_error(L)
}

func luaL_getmetatable(_ L: UnsafeMutablePointer<lua_State>!, _ n: UnsafePointer<CChar>!) {
    lua_getfield(L, LUA_REGISTRYINDEX_VALUE, n)
}

func lua_newuserdata(_ L: UnsafeMutablePointer<lua_State>!, _ size: Int) -> UnsafeMutableRawPointer! {
    lua_newuserdatauv(L, size, 1)
}

func lua_isnoneornil(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) <= 0
}

func lua_isnone(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32) -> Bool {
    lua_type(L, n) == LUA_TNONE
}

func lua_remove(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) {
    lua_rotate(L, idx, -1)
    lua_pop(L, 1)
}

func lua_call(_ L: UnsafeMutablePointer<lua_State>!, _ n: Int32, _ r: Int32) {
    lua_callk(L, n, r, 0, nil)
}

func lua_insert(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) {
    lua_rotate(L, idx, 1)
}

func lua_replace(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) {
    lua_copy(L, -1, idx)
    lua_pop(L, 1)
}

@_silgen_name("lua_rawlen")
private func c_lua_rawlen(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UInt

func lua_rawlen(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Int {
    Int(c_lua_rawlen(L, idx))
}

func lua_pushliteral(_ L: UnsafeMutablePointer<lua_State>!, _ s: UnsafePointer<CChar>!) {
    lua_pushstring(L, s)
}

func lua_pushglobaltable(_ L: UnsafeMutablePointer<lua_State>!) {
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(LUA_RIDX_GLOBALS))
}

func luaL_argcheck(_ L: UnsafeMutablePointer<lua_State>!, _ cond: Bool, _ arg: Int32, _ extramsg: UnsafePointer<CChar>!) {
    if !cond {
        luaL_argerror(L, arg, extramsg)
    }
}

func luaL_typename(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> UnsafePointer<CChar>! {
    lua_typename(L, lua_type(L, idx))
}

func luaL_checkversion(_ L: UnsafeMutablePointer<lua_State>!) {
    let numSizes = MemoryLayout<lua_Integer>.size * 16 + MemoryLayout<lua_Number>.size
    luaL_checkversion_(L, lua_Number(LUA_VERSION_NUM), numSizes)
}

func lua_absindex(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Int32 {
    if idx > 0 || idx <= LUA_REGISTRYINDEX_VALUE {
        return idx
    }
    return lua_gettop(L) + idx + 1
}

let LUA_RIDX_GLOBALS: Int = 2

#if DEBUG
/// Thread-local stack tracking expected Lua stack levels for stackguard pairs.
private var _stackguardLevels: [Int32] {
    get {
        Thread.current.threadDictionary["_lua_stackguard_levels"] as? [Int32] ?? []
    }
    set {
        Thread.current.threadDictionary["_lua_stackguard_levels"] = newValue
    }
}

func _lua_stackguard_entry(_ L: UnsafeMutablePointer<lua_State>!) {
    guard let L = L else { return }
    _stackguardLevels.append(lua_gettop(L))
}

func _lua_stackguard_exit(_ L: UnsafeMutablePointer<lua_State>!) {
    guard let L = L else { return }
    let expected = _stackguardLevels.removeLast()
    let actual = lua_gettop(L)
    assert(expected == actual,
           "Lua stack imbalance: expected \(expected), got \(actual)")
}
#else
func _lua_stackguard_entry(_ L: Any?) {}
func _lua_stackguard_exit(_ L: Any?) {}
#endif
