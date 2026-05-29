// Pure Swift replacement for the vendored lsqlite3 C library.
// Implements the same Lua API surface as http://lua.sqlite.org/ (lsqlite3 0.9.5)
// using Swift's system sqlite3 module directly.

import SQLite3
import CLua

// MARK: - Metatable names (must match what Lua code expects)

private let sqliteDbMeta = ":sqlite3"
private let sqliteVmMeta = ":sqlite3:vm"
private let sqliteBuMeta = ":sqlite3:bu"
private let sqliteCtxMeta = ":sqlite3:ctx"
private var sqliteCtxMetaRef: Int32 = LUA_NOREF

// MARK: - SQLITE_TRANSIENT helper
// SQLITE_TRANSIENT is ((sqlite3_destructor_type)-1) in C; replicate it in Swift.
private let SQLITE_TRANSIENT_VALUE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Database userdata

/// Stored in Lua userdata for each open database handle.
private struct SDB {
    var L: UnsafeMutablePointer<lua_State>!   // associated lua state (for callbacks)
    var db: OpaquePointer?      // sqlite3*
    var busyCb: Int32 = LUA_NOREF
    var busyUdata: Int32 = LUA_NOREF
    var progressCb: Int32 = LUA_NOREF
    var progressUdata: Int32 = LUA_NOREF
    var traceCb: Int32 = LUA_NOREF
    var traceUdata: Int32 = LUA_NOREF
    var updateHookCb: Int32 = LUA_NOREF
    var updateHookUdata: Int32 = LUA_NOREF
    var commitHookCb: Int32 = LUA_NOREF
    var commitHookUdata: Int32 = LUA_NOREF
    var rollbackHookCb: Int32 = LUA_NOREF
    var rollbackHookUdata: Int32 = LUA_NOREF
    // Linked list of registered SQL functions
    var funcHead: UnsafeMutablePointer<SDBFunc>? = nil
}

/// Registered SQL function metadata.
private struct SDBFunc {
    var fnStep: Int32 = LUA_NOREF
    var fnFinalize: Int32 = LUA_NOREF
    var udata: Int32 = LUA_NOREF
    var db: UnsafeMutablePointer<SDB>!
    var aggregate: Bool = false
    var next: UnsafeMutablePointer<SDBFunc>? = nil
}

// MARK: - Statement (virtual machine) userdata

private struct SDBVM {
    var db: UnsafeMutablePointer<SDB>!  // owning database
    var vm: OpaquePointer?              // sqlite3_stmt*
    var columns: Int32 = 0
    var hasValues: Bool = false
    var temp: Bool = false              // temporary vm used in db:rows
}

// MARK: - Backup userdata

private struct SDBBackup {
    var bu: OpaquePointer?  // sqlite3_backup*
}

// MARK: - Context userdata (for create_function / create_aggregate)

private struct LContext {
    var ctx: OpaquePointer?  // sqlite3_context*
    var ud: Int32 = LUA_NOREF
}

// MARK: - Helper: push an Int64 appropriately

private func pushInt64(_ L: UnsafeMutablePointer<lua_State>!, _ value: Int64) {
    let asLuaInt = lua_Integer(value)
    if Int64(asLuaInt) == value {
        lua_pushinteger(L, asLuaInt)
    } else {
        let asNumber = lua_Number(value)
        if Int64(asNumber) == value {
            lua_pushnumber(L, asNumber)
        } else {
            let s = String(value)
            lua_pushstring(L, s)
        }
    }
}

// MARK: - Helper: push a column value

private func vmPushColumn(_ L: UnsafeMutablePointer<lua_State>!, _ vm: OpaquePointer!, _ idx: Int32) {
    switch sqlite3_column_type(vm, idx) {
    case SQLITE_INTEGER:
        pushInt64(L, sqlite3_column_int64(vm, idx))
    case SQLITE_FLOAT:
        lua_pushnumber(L, sqlite3_column_double(vm, idx))
    case SQLITE_TEXT:
        let text = sqlite3_column_text(vm, idx)
        let len = sqlite3_column_bytes(vm, idx)
        lua_pushlstring(L, text, Int(len))
    case SQLITE_BLOB:
        let blob = sqlite3_column_blob(vm, idx)
        let len = sqlite3_column_bytes(vm, idx)
        lua_pushlstring(L, blob?.assumingMemoryBound(to: CChar.self), Int(len))
    case SQLITE_NULL:
        lua_pushnil(L)
    default:
        lua_pushnil(L)
    }
}

// MARK: - Database helpers

private func getDB(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<SDB> {
    let p = luaL_checkudata(L, index, sqliteDbMeta)!
    return p.assumingMemoryBound(to: SDB.self)
}

private func checkDB(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<SDB> {
    let sdb = getDB(L, index)
    if sdb.pointee.db == nil {
        luaL_argerror(L, index, "attempt to use closed sqlite database")
    }
    return sdb
}

private func newDB(_ L: UnsafeMutablePointer<lua_State>!) -> UnsafeMutablePointer<SDB> {
    let p = lua_newuserdata(L, MemoryLayout<SDB>.size)!
    let sdb = p.assumingMemoryBound(to: SDB.self)
    sdb.initialize(to: SDB())
    sdb.pointee.L = L

    luaL_getmetatable(L, sqliteDbMeta)
    lua_setmetatable(L, -2)

    // Create a table in the registry to track open VMs for this db
    lua_pushlightuserdata(L, sdb)
    lua_newtable(L)
    lua_rawset(L, LUA_REGISTRYINDEX_VALUE)

    return sdb
}

private func cleanupDB(_ L: UnsafeMutablePointer<lua_State>!, _ sdb: UnsafeMutablePointer<SDB>) -> Int32 {
    // Close all associated VMs
    lua_pushlightuserdata(L, sdb)
    lua_rawget(L, LUA_REGISTRYINDEX_VALUE)

    let top = lua_gettop(L)
    lua_pushnil(L)
    while lua_next(L, -2) != 0 {
        let svmPtr = lua_touserdata(L, -2)
        if let svmPtr = svmPtr {
            let svm = svmPtr.assumingMemoryBound(to: SDBVM.self)
            _ = cleanupVM(L, svm)
        }
        lua_settop(L, top)
        lua_pushnil(L)
    }
    lua_pop(L, 1)

    // Remove registry entry
    lua_pushlightuserdata(L, sdb)
    lua_pushnil(L)
    lua_rawset(L, LUA_REGISTRYINDEX_VALUE)

    // Unref all callbacks
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyCb)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyUdata)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.progressCb)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.progressUdata)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.traceCb)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.traceUdata)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.updateHookCb)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.updateHookUdata)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.commitHookCb)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.commitHookUdata)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.rollbackHookCb)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.rollbackHookUdata)

    // Close the database
    let result = sqlite3_close(sdb.pointee.db)
    sdb.pointee.db = nil

    // Free registered SQL functions
    var funcPtr = sdb.pointee.funcHead
    while let f = funcPtr {
        let next = f.pointee.next
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, f.pointee.fnStep)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, f.pointee.fnFinalize)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, f.pointee.udata)
        f.deallocate()
        funcPtr = next
    }
    sdb.pointee.funcHead = nil

    return result
}

// MARK: - VM helpers

private func newVM(_ L: UnsafeMutablePointer<lua_State>!, _ sdb: UnsafeMutablePointer<SDB>) -> UnsafeMutablePointer<SDBVM> {
    let p = lua_newuserdata(L, MemoryLayout<SDBVM>.size)!
    let svm = p.assumingMemoryBound(to: SDBVM.self)
    svm.initialize(to: SDBVM())
    svm.pointee.db = sdb

    luaL_getmetatable(L, sqliteVmMeta)
    lua_setmetatable(L, -2)

    // Register this VM in the db's VM tracking table
    lua_pushlightuserdata(L, sdb)
    lua_rawget(L, LUA_REGISTRYINDEX_VALUE)
    lua_pushlightuserdata(L, svm)
    lua_pushvalue(L, -5) // db userdata
    lua_rawset(L, -3)
    lua_pop(L, 1)

    return svm
}

private func cleanupVM(_ L: UnsafeMutablePointer<lua_State>!, _ svm: UnsafeMutablePointer<SDBVM>) -> Int32 {
    lua_pushlightuserdata(L, svm.pointee.db)
    lua_rawget(L, LUA_REGISTRYINDEX_VALUE)
    lua_pushlightuserdata(L, svm)
    lua_pushnil(L)
    lua_rawset(L, -3)
    lua_pop(L, 1)

    svm.pointee.columns = 0
    svm.pointee.hasValues = false

    guard let vm = svm.pointee.vm else { return 0 }

    let result = sqlite3_finalize(vm)
    svm.pointee.vm = nil
    lua_pushinteger(L, lua_Integer(result))
    return 1
}

private func getVM(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<SDBVM> {
    let p = luaL_checkudata(L, index, sqliteVmMeta)!
    return p.assumingMemoryBound(to: SDBVM.self)
}

private func checkVM(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<SDBVM> {
    let svm = getVM(L, index)
    if svm.pointee.vm == nil {
        luaL_argerror(L, index, "attempt to use closed sqlite virtual machine")
    }
    return svm
}

// MARK: - Bind helper

private func bindIndex(_ L: UnsafeMutablePointer<lua_State>!, _ vm: OpaquePointer!, _ index: Int32, _ lindex: Int32) -> Int32 {
    switch lua_type(L, lindex) {
    case LUA_TSTRING:
        let s = lua_tostring(L, lindex)
        let len: Int = lua_rawlen(L, lindex)
        return sqlite3_bind_text(vm, index, s, Int32(len), SQLITE_TRANSIENT_VALUE)
    case LUA_TNUMBER:
        if lua_isinteger(L, lindex) != 0 {
            return sqlite3_bind_int64(vm, index, sqlite3_int64(lua_tointeger(L, lindex)))
        }
        return sqlite3_bind_double(vm, index, lua_tonumber(L, lindex))
    case LUA_TBOOLEAN:
        return sqlite3_bind_int(vm, index, lua_toboolean(L, lindex) != 0 ? 1 : 0)
    case LUA_TNIL, LUA_TNONE:
        return sqlite3_bind_null(vm, index)
    default:
        let typeName = String(cString: lua_typename(L, lua_type(L, lindex)))
        luaL_error(L, "index (\(index)) - invalid data type for bind (\(typeName))")
        return SQLITE_MISUSE
    }
}

// MARK: - VM methods

private let dbvm_isopen: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = getVM(L, 1)
    lua_pushboolean(L, svm.pointee.vm != nil ? 1 : 0)
    return 1
}

private let dbvm_tostring: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = getVM(L, 1)
    if svm.pointee.vm == nil {
        lua_pushstring(L, "sqlite virtual machine (closed)")
    } else {
        let p = UnsafeMutableRawPointer(svm)
        let desc = String(format: "sqlite virtual machine (%p)", Int(bitPattern: p))
        lua_pushstring(L, desc)
    }
    return 1
}

private let dbvm_gc: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = getVM(L, 1)
    if svm.pointee.vm != nil {
        _ = cleanupVM(L, svm)
    }
    return 0
}

private let dbvm_step: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let result = sqlite3_step(svm.pointee.vm)
    svm.pointee.hasValues = result == SQLITE_ROW
    svm.pointee.columns = sqlite3_data_count(svm.pointee.vm)
    lua_pushinteger(L, lua_Integer(result))
    return 1
}

private let dbvm_finalize: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    return Int32(cleanupVM(L, svm))
}

private let dbvm_reset: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    sqlite3_reset(svm.pointee.vm)
    lua_pushinteger(L, lua_Integer(sqlite3_errcode(svm.pointee.db.pointee.db)))
    return 1
}

private let dbvm_columns: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    lua_pushinteger(L, lua_Integer(sqlite3_column_count(svm.pointee.vm)))
    return 1
}

private let dbvm_get_value: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let index = Int32(luaL_checkinteger(L, 2))
    guard svm.pointee.hasValues else { return Int32(luaL_error(L, "misuse of function")) }
    guard index >= 0 && index < svm.pointee.columns else {
        let msg = "index out of range [0..\(svm.pointee.columns - 1)]"
        return Int32(luaL_error(L, msg))
    }
    vmPushColumn(L, svm.pointee.vm, index)
    return 1
}

private let dbvm_get_values: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    guard svm.pointee.hasValues else { return Int32(luaL_error(L, "misuse of function")) }
    let columns = svm.pointee.columns
    lua_createtable(L, columns, 0)
    for i in 0..<columns {
        vmPushColumn(L, svm.pointee.vm, i)
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    return 1
}

private let dbvm_get_name: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let index = Int32(luaL_checkinteger(L, 2))
    guard index >= 0 && index < sqlite3_column_count(svm.pointee.vm) else {
        let msg = "index out of range [0..\(sqlite3_column_count(svm.pointee.vm) - 1)]"
        return Int32(luaL_error(L, msg))
    }
    lua_pushstring(L, sqlite3_column_name(svm.pointee.vm, index))
    return 1
}

private let dbvm_get_names: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let columns = sqlite3_column_count(svm.pointee.vm)
    lua_createtable(L, columns, 0)
    for i in 0..<columns {
        lua_pushstring(L, sqlite3_column_name(svm.pointee.vm, i))
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    return 1
}

private let dbvm_get_type: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let index = Int32(luaL_checkinteger(L, 2))
    guard index >= 0 && index < sqlite3_column_count(svm.pointee.vm) else {
        let msg = "index out of range [0..\(sqlite3_column_count(svm.pointee.vm) - 1)]"
        return Int32(luaL_error(L, msg))
    }
    lua_pushstring(L, sqlite3_column_decltype(svm.pointee.vm, index))
    return 1
}

private let dbvm_get_types: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let columns = sqlite3_column_count(svm.pointee.vm)
    lua_createtable(L, columns, 0)
    for i in 0..<columns {
        lua_pushstring(L, sqlite3_column_decltype(svm.pointee.vm, i))
        lua_rawseti(L, -2, lua_Integer(i + 1))
    }
    return 1
}

private let dbvm_get_uvalues: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    guard svm.pointee.hasValues else { return Int32(luaL_error(L, "misuse of function")) }
    let columns = svm.pointee.columns
    lua_checkstack(L, columns)
    for i in 0..<columns {
        vmPushColumn(L, svm.pointee.vm, i)
    }
    return columns
}

private let dbvm_get_unames: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let columns = sqlite3_column_count(svm.pointee.vm)
    lua_checkstack(L, columns)
    for i in 0..<columns {
        lua_pushstring(L, sqlite3_column_name(svm.pointee.vm, i))
    }
    return columns
}

private let dbvm_get_utypes: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let columns = sqlite3_column_count(svm.pointee.vm)
    lua_checkstack(L, columns)
    for i in 0..<columns {
        lua_pushstring(L, sqlite3_column_decltype(svm.pointee.vm, i))
    }
    return columns
}

private let dbvm_get_named_values: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    guard svm.pointee.hasValues else { return Int32(luaL_error(L, "misuse of function")) }
    let columns = svm.pointee.columns
    lua_createtable(L, 0, columns)
    for i in 0..<columns {
        lua_pushstring(L, sqlite3_column_name(svm.pointee.vm, i))
        vmPushColumn(L, svm.pointee.vm, i)
        lua_rawset(L, -3)
    }
    return 1
}

private let dbvm_get_named_types: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let columns = sqlite3_column_count(svm.pointee.vm)
    lua_createtable(L, 0, columns)
    for i in 0..<columns {
        lua_pushstring(L, sqlite3_column_name(svm.pointee.vm, i))
        lua_pushstring(L, sqlite3_column_decltype(svm.pointee.vm, i))
        lua_rawset(L, -3)
    }
    return 1
}

// MARK: - VM bind methods

private let dbvm_bind: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let index = Int32(luaL_checkinteger(L, 2))
    let count = sqlite3_bind_parameter_count(svm.pointee.vm)
    guard index >= 1 && index <= count else {
        let msg = "bind index out of range [1..\(count)]"
        return Int32(luaL_error(L, msg))
    }
    let result = bindIndex(L, svm.pointee.vm, index, 3)
    lua_pushinteger(L, lua_Integer(result))
    return 1
}

private let dbvm_bind_blob: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let index = Int32(luaL_checkinteger(L, 2))
    let _ = luaL_checkstring(L, 3)
    let value = lua_tostring(L, 3)
    let blobLen: Int = lua_rawlen(L, 3)
    let len = Int32(blobLen)
    let result = sqlite3_bind_blob(svm.pointee.vm, index, value, len, SQLITE_TRANSIENT_VALUE)
    lua_pushinteger(L, lua_Integer(result))
    return 1
}

private let dbvm_bind_values: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let top = lua_gettop(L)
    let paramCount = sqlite3_bind_parameter_count(svm.pointee.vm)
    guard top - 1 == paramCount else {
        let msg = "incorrect number of parameters to bind (\(top - 1) given, \(paramCount) to bind)"
        return Int32(luaL_error(L, msg))
    }
    for n in 2...top {
        let result = bindIndex(L, svm.pointee.vm, n - 1, n)
        if result != SQLITE_OK {
            lua_pushinteger(L, lua_Integer(result))
            return 1
        }
    }
    lua_pushinteger(L, lua_Integer(SQLITE_OK))
    return 1
}

private let dbvm_bind_names: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let count = sqlite3_bind_parameter_count(svm.pointee.vm)
    luaL_checktype(L, 2, LUA_TTABLE)

    for n: Int32 in 1...count {
        let name = sqlite3_bind_parameter_name(svm.pointee.vm, n)
        var result: Int32
        if let name = name, (name[0] == UInt8(ascii: ":") || name[0] == UInt8(ascii: "$")) {
            lua_pushstring(L, name.advanced(by: 1))
            lua_gettable(L, 2)
            result = bindIndex(L, svm.pointee.vm, n, -1)
            lua_pop(L, 1)
        } else {
            lua_pushinteger(L, lua_Integer(n))
            lua_gettable(L, 2)
            result = bindIndex(L, svm.pointee.vm, n, -1)
            lua_pop(L, 1)
        }
        if result != SQLITE_OK {
            lua_pushinteger(L, lua_Integer(result))
            return 1
        }
    }
    lua_pushinteger(L, lua_Integer(SQLITE_OK))
    return 1
}

private let dbvm_bind_parameter_count: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    lua_pushinteger(L, lua_Integer(sqlite3_bind_parameter_count(svm.pointee.vm)))
    return 1
}

private let dbvm_bind_parameter_name: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    let index = Int32(luaL_checkinteger(L, 2))
    let count = sqlite3_bind_parameter_count(svm.pointee.vm)
    guard index >= 1 && index <= count else {
        let msg = "bind index out of range [1..\(count)]"
        return Int32(luaL_error(L, msg))
    }
    lua_pushstring(L, sqlite3_bind_parameter_name(svm.pointee.vm, index))
    return 1
}

private let dbvm_last_insert_rowid: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let svm = checkVM(L, 1)
    pushInt64(L, sqlite3_last_insert_rowid(svm.pointee.db.pointee.db))
    return 1
}

private let dbvm_rows: lua_CFunction = { L in
    guard let L = L else { return 0 }
    _ = checkVM(L, 1)
    lua_pushvalue(L, 1)
    lua_pushcclosure(L, db_next_packed_row, 0)
    lua_insert(L, -2)
    return 2
}

private let dbvm_nrows: lua_CFunction = { L in
    guard let L = L else { return 0 }
    _ = checkVM(L, 1)
    lua_pushvalue(L, 1)
    lua_pushcclosure(L, db_next_named_row, 0)
    lua_insert(L, -2)
    return 2
}

private let dbvm_urows: lua_CFunction = { L in
    guard let L = L else { return 0 }
    _ = checkVM(L, 1)
    lua_pushvalue(L, 1)
    lua_pushcclosure(L, db_next_row, 0)
    lua_insert(L, -2)
    return 2
}

// MARK: - Row iteration functions

private func dbDoNextRow(_ L: UnsafeMutablePointer<lua_State>!, _ packed: Int32) -> Int32 {
    let svm = checkVM(L, 1)
    let result = sqlite3_step(svm.pointee.vm)
    svm.pointee.hasValues = result == SQLITE_ROW
    svm.pointee.columns = sqlite3_data_count(svm.pointee.vm)

    if result == SQLITE_ROW {
        let columns = svm.pointee.columns
        if packed != 0 {
            if packed == 1 {
                lua_createtable(L, columns, 0)
                for i in 0..<columns {
                    vmPushColumn(L, svm.pointee.vm, i)
                    lua_rawseti(L, -2, lua_Integer(i + 1))
                }
            } else {
                lua_createtable(L, 0, columns)
                for i in 0..<columns {
                    lua_pushstring(L, sqlite3_column_name(svm.pointee.vm, i))
                    vmPushColumn(L, svm.pointee.vm, i)
                    lua_rawset(L, -3)
                }
            }
            return 1
        } else {
            lua_checkstack(L, columns)
            for i in 0..<columns {
                vmPushColumn(L, svm.pointee.vm, i)
            }
            return columns
        }
    }

    var finalResult = result
    if svm.pointee.temp {
        finalResult = sqlite3_finalize(svm.pointee.vm)
        svm.pointee.vm = nil
        _ = cleanupVM(L, svm)
    } else if result == SQLITE_DONE {
        finalResult = sqlite3_reset(svm.pointee.vm)
    }

    if finalResult != SQLITE_OK {
        lua_pushstring(L, sqlite3_errmsg(svm.pointee.db.pointee.db))
        lua_error(L)
    }
    return 0
}

private let db_next_row: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbDoNextRow(L, 0)
}

private let db_next_packed_row: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbDoNextRow(L, 1)
}

private let db_next_named_row: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbDoNextRow(L, 2)
}

// MARK: - Database methods

private let db_isopen: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = getDB(L, 1)
    lua_pushboolean(L, sdb.pointee.db != nil ? 1 : 0)
    return 1
}

private let db_last_insert_rowid: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    pushInt64(L, sqlite3_last_insert_rowid(sdb.pointee.db))
    return 1
}

private let db_changes: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    lua_pushinteger(L, lua_Integer(sqlite3_changes(sdb.pointee.db)))
    return 1
}

private let db_total_changes: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    lua_pushinteger(L, lua_Integer(sqlite3_total_changes(sdb.pointee.db)))
    return 1
}

private let db_errcode: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    lua_pushinteger(L, lua_Integer(sqlite3_errcode(sdb.pointee.db)))
    return 1
}

private let db_errmsg: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    lua_pushstring(L, sqlite3_errmsg(sdb.pointee.db))
    return 1
}

private let db_interrupt: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    sqlite3_interrupt(sdb.pointee.db)
    return 0
}

private let db_db_filename: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    let dbName = luaL_checkstring(L, 2)
    lua_pushstring(L, sqlite3_db_filename(sdb.pointee.db, dbName))
    return 1
}

// MARK: - Database exec

/// Helper class for exec callback (needs reference semantics for the C callback)
private class ExecCallbackContext {
    let L: UnsafeMutablePointer<lua_State>

    init(L: UnsafeMutablePointer<lua_State>) {
        self.L = L
    }

    func callback(columns: Int32, data: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                  names: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
        var result: Int32 = SQLITE_ABORT
        let top = lua_gettop(L)

        lua_pushvalue(L, 3)  // callback function
        lua_pushvalue(L, 4)  // user data
        lua_pushinteger(L, lua_Integer(columns))

        // Column values
        lua_pushvalue(L, 6)
        for i in 0..<Int(columns) {
            if let d = data?[i] {
                lua_pushstring(L, d)
            } else {
                lua_pushnil(L)
            }
            lua_rawseti(L, -2, lua_Integer(i + 1))
        }

        // Column names (only set once)
        lua_pushvalue(L, 5)
        if lua_isnil(L, -1) {
            lua_pop(L, 1)
            lua_createtable(L, columns, 0)
            lua_pushvalue(L, -1)
            lua_replace(L, 5)
            for i in 0..<Int(columns) {
                if let n = names?[i] {
                    lua_pushstring(L, n)
                } else {
                    lua_pushnil(L)
                }
                lua_rawseti(L, -2, lua_Integer(i + 1))
            }
        }

        if lua_pcall(L, 4, 1, 0) == 0 {
            if lua_isinteger(L, -1) != 0 {
                result = Int32(lua_tointeger(L, -1))
            } else if lua_isnumber(L, -1) {
                result = Int32(lua_tonumber(L, -1))
            }
        }

        lua_settop(L, top)
        return result
    }
}

private let db_exec: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    let sql = luaL_checkstring(L, 2)

    var result: Int32
    if lua_type(L, 3) != LUA_TNIL && lua_type(L, 3) != LUA_TNONE {
        luaL_checktype(L, 3, LUA_TFUNCTION)
        lua_settop(L, 4)   // trap userdata
        lua_pushnil(L)      // 5: column names (filled on first callback)
        lua_newtable(L)     // 6: reusable column values table

        let callbackCtx = ExecCallbackContext(L: L)
        let ctxPtr = Unmanaged.passRetained(callbackCtx).toOpaque()

        result = sqlite3_exec(sdb.pointee.db, sql, { (user, columns, data, names) -> Int32 in
            guard let user = user else { return SQLITE_ABORT }
            let ctx = Unmanaged<ExecCallbackContext>.fromOpaque(user).takeUnretainedValue()
            return ctx.callback(columns: columns, data: data, names: names)
        }, ctxPtr, nil)

        Unmanaged<ExecCallbackContext>.fromOpaque(ctxPtr).release()
    } else {
        result = sqlite3_exec(sdb.pointee.db, sql, nil, nil, nil)
    }

    lua_pushinteger(L, lua_Integer(result))
    return 1
}

// MARK: - Database prepare

private let db_prepare: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    let sql = luaL_checkstring(L, 2)
    let sqlRawLen: Int = lua_rawlen(L, 2)
    let sqlLen = Int32(sqlRawLen)
    var sqltail: UnsafePointer<CChar>?

    lua_settop(L, 2)
    let svm = newVM(L, sdb)

    if sqlite3_prepare_v2(sdb.pointee.db, sql, sqlLen, &svm.pointee.vm, &sqltail) != SQLITE_OK {
        lua_pushnil(L)
        lua_pushinteger(L, lua_Integer(sqlite3_errcode(sdb.pointee.db)))
        if cleanupVM(L, svm) == 1 {
            lua_pop(L, 1)
        }
        return 2
    }

    lua_pushstring(L, sqltail)
    return 2
}

// MARK: - Database row iterators

private func dbDoRows(_ L: UnsafeMutablePointer<lua_State>!, _ f: @escaping lua_CFunction) -> Int32 {
    let sdb = checkDB(L, 1)
    let sql = luaL_checkstring(L, 2)
    lua_settop(L, 2)
    let svm = newVM(L, sdb)
    svm.pointee.temp = true

    if sqlite3_prepare_v2(sdb.pointee.db, sql, -1, &svm.pointee.vm, nil) != SQLITE_OK {
        lua_pushstring(L, sqlite3_errmsg(sdb.pointee.db))
        if cleanupVM(L, svm) == 1 {
            lua_pop(L, 1)
        }
        return Int32(lua_error(L))
    }

    lua_pushcclosure(L, f, 0)
    lua_insert(L, -2)
    return 2
}

private let db_rows: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbDoRows(L, db_next_packed_row)
}

private let db_nrows: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbDoRows(L, db_next_named_row)
}

private let db_urows: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbDoRows(L, db_next_row)
}

// MARK: - Database close, gc, tostring

private let db_close: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    lua_pushinteger(L, lua_Integer(cleanupDB(L, sdb)))
    return 1
}

private let db_close_vm: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    let temp = lua_toboolean(L, 2) != 0

    lua_pushlightuserdata(L, sdb)
    lua_rawget(L, LUA_REGISTRYINDEX_VALUE)

    lua_pushnil(L)
    while lua_next(L, -2) != 0 {
        let svmPtr = lua_touserdata(L, -2)
        if let svmPtr = svmPtr {
            let svm = svmPtr.assumingMemoryBound(to: SDBVM.self)
            if (!temp || svm.pointee.temp) && svm.pointee.vm != nil {
                sqlite3_finalize(svm.pointee.vm)
                svm.pointee.vm = nil
            }
        }
        lua_pop(L, 1)
    }
    return 0
}

private let db_tostring: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = getDB(L, 1)
    if sdb.pointee.db == nil {
        lua_pushstring(L, "sqlite database (closed)")
    } else {
        let p = lua_touserdata(L, 1)!
        let desc = String(format: "sqlite database (%p)", Int(bitPattern: p))
        lua_pushstring(L, desc)
    }
    return 1
}

private let db_gc: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = getDB(L, 1)
    if sdb.pointee.db != nil {
        _ = cleanupDB(L, sdb)
    }
    return 0
}

private let db_get_ptr: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    lua_pushlightuserdata(L, UnsafeMutableRawPointer(sdb.pointee.db))
    return 1
}

// MARK: - Busy handling

private let db_busy_timeout: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    let timeout = Int32(luaL_checkinteger(L, 2))
    sqlite3_busy_timeout(sdb.pointee.db, timeout)

    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyCb)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyUdata)
    sdb.pointee.busyCb = LUA_NOREF
    sdb.pointee.busyUdata = LUA_NOREF

    return 0
}

private let db_busy_handler: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)

    if lua_gettop(L) < 2 || lua_type(L, 2) == LUA_TNIL {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyUdata)
        sdb.pointee.busyCb = LUA_NOREF
        sdb.pointee.busyUdata = LUA_NOREF
        sqlite3_busy_handler(sdb.pointee.db, nil, nil)
    } else {
        luaL_checktype(L, 2, LUA_TFUNCTION)
        lua_settop(L, 3)

        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.busyUdata)

        sdb.pointee.busyUdata = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        sdb.pointee.busyCb = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        sqlite3_busy_handler(sdb.pointee.db, { (user, tries) -> Int32 in
            guard let user = user else { return 0 }
            let sdb = user.assumingMemoryBound(to: SDB.self)
            let L = sdb.pointee.L!
            var retry: Int32 = 0
            let top = lua_gettop(L)

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.busyCb))
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.busyUdata))
            lua_pushinteger(L, lua_Integer(tries))

            if lua_pcall(L, 2, 1, 0) == 0 {
                retry = lua_toboolean(L, -1)
            }
            lua_settop(L, top)
            return retry
        }, sdb)
    }
    return 0
}

// MARK: - Trace

private let db_trace: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)

    if lua_gettop(L) < 2 || lua_type(L, 2) == LUA_TNIL {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.traceCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.traceUdata)
        sdb.pointee.traceCb = LUA_NOREF
        sdb.pointee.traceUdata = LUA_NOREF
        sqlite3_trace(sdb.pointee.db, nil, nil)
    } else {
        luaL_checktype(L, 2, LUA_TFUNCTION)
        lua_settop(L, 3)

        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.traceCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.traceUdata)

        sdb.pointee.traceUdata = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        sdb.pointee.traceCb = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        sqlite3_trace(sdb.pointee.db, { (user, sql) in
            guard let user = user else { return }
            let sdb = user.assumingMemoryBound(to: SDB.self)
            let L = sdb.pointee.L!
            let top = lua_gettop(L)

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.traceCb))
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.traceUdata))
            lua_pushstring(L, sql)
            lua_pcall(L, 2, 0, 0)

            lua_settop(L, top)
        }, sdb)
    }
    return 0
}

// MARK: - Progress handler

private let db_progress_handler: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)

    if lua_gettop(L) < 2 || lua_type(L, 2) == LUA_TNIL {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.progressCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.progressUdata)
        sdb.pointee.progressCb = LUA_NOREF
        sdb.pointee.progressUdata = LUA_NOREF
        sqlite3_progress_handler(sdb.pointee.db, 0, nil, nil)
    } else {
        let nop = Int32(luaL_checkinteger(L, 2))
        luaL_checktype(L, 3, LUA_TFUNCTION)
        lua_settop(L, 4)

        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.progressCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.progressUdata)

        sdb.pointee.progressUdata = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        sdb.pointee.progressCb = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        sqlite3_progress_handler(sdb.pointee.db, nop, { user -> Int32 in
            guard let user = user else { return 1 }
            let sdb = user.assumingMemoryBound(to: SDB.self)
            let L = sdb.pointee.L!
            var result: Int32 = 1
            let top = lua_gettop(L)

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.progressCb))
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.progressUdata))

            if lua_pcall(L, 1, 1, 0) == 0 {
                result = lua_toboolean(L, -1)
            }
            lua_settop(L, top)
            return result
        }, sdb)
    }
    return 0
}

// MARK: - Update / Commit / Rollback hooks

private let db_update_hook: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)

    if lua_gettop(L) < 2 || lua_type(L, 2) == LUA_TNIL {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.updateHookCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.updateHookUdata)
        sdb.pointee.updateHookCb = LUA_NOREF
        sdb.pointee.updateHookUdata = LUA_NOREF
        sqlite3_update_hook(sdb.pointee.db, nil, nil)
    } else {
        luaL_checktype(L, 2, LUA_TFUNCTION)
        lua_settop(L, 3)

        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.updateHookCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.updateHookUdata)

        sdb.pointee.updateHookUdata = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        sdb.pointee.updateHookCb = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        sqlite3_update_hook(sdb.pointee.db, { (user, op, dbname, tblname, rowid) in
            guard let user = user else { return }
            let sdb = user.assumingMemoryBound(to: SDB.self)
            let L = sdb.pointee.L!
            let top = lua_gettop(L)

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.updateHookCb))
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.updateHookUdata))
            lua_pushinteger(L, lua_Integer(op))
            lua_pushstring(L, dbname)
            lua_pushstring(L, tblname)
            pushInt64(L, rowid)
            lua_pcall(L, 5, 0, 0)

            lua_settop(L, top)
        }, sdb)
    }
    return 0
}

private let db_commit_hook: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)

    if lua_gettop(L) < 2 || lua_type(L, 2) == LUA_TNIL {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.commitHookCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.commitHookUdata)
        sdb.pointee.commitHookCb = LUA_NOREF
        sdb.pointee.commitHookUdata = LUA_NOREF
        sqlite3_commit_hook(sdb.pointee.db, nil, nil)
    } else {
        luaL_checktype(L, 2, LUA_TFUNCTION)
        lua_settop(L, 3)

        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.commitHookCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.commitHookUdata)

        sdb.pointee.commitHookUdata = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        sdb.pointee.commitHookCb = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        sqlite3_commit_hook(sdb.pointee.db, { user -> Int32 in
            guard let user = user else { return 0 }
            let sdb = user.assumingMemoryBound(to: SDB.self)
            let L = sdb.pointee.L!
            var rollback: Int32 = 0
            let top = lua_gettop(L)

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.commitHookCb))
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.commitHookUdata))

            if lua_pcall(L, 1, 1, 0) == 0 {
                rollback = lua_toboolean(L, -1)
            }
            lua_settop(L, top)
            return rollback
        }, sdb)
    }
    return 0
}

private let db_rollback_hook: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)

    if lua_gettop(L) < 2 || lua_type(L, 2) == LUA_TNIL {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.rollbackHookCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.rollbackHookUdata)
        sdb.pointee.rollbackHookCb = LUA_NOREF
        sdb.pointee.rollbackHookUdata = LUA_NOREF
        sqlite3_rollback_hook(sdb.pointee.db, nil, nil)
    } else {
        luaL_checktype(L, 2, LUA_TFUNCTION)
        lua_settop(L, 3)

        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.rollbackHookCb)
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, sdb.pointee.rollbackHookUdata)

        sdb.pointee.rollbackHookUdata = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        sdb.pointee.rollbackHookCb = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        sqlite3_rollback_hook(sdb.pointee.db, { user in
            guard let user = user else { return }
            let sdb = user.assumingMemoryBound(to: SDB.self)
            let L = sdb.pointee.L!
            let top = lua_gettop(L)

            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.rollbackHookCb))
            lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sdb.pointee.rollbackHookUdata))
            lua_pcall(L, 1, 0, 0)

            lua_settop(L, top)
        }, sdb)
    }
    return 0
}

// MARK: - Create function / aggregate

private let db_create_function: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbRegisterFunction(L, aggregate: false)
}

private let db_create_aggregate: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return dbRegisterFunction(L, aggregate: true)
}

private func dbRegisterFunction(_ L: UnsafeMutablePointer<lua_State>, aggregate: Bool) -> Int32 {
    let sdb = checkDB(L, 1)
    let name = luaL_checkstring(L, 2)
    let args = Int32(luaL_checkinteger(L, 3))
    luaL_checktype(L, 4, LUA_TFUNCTION)
    if aggregate { luaL_checktype(L, 5, LUA_TFUNCTION) }

    let funcPtr = UnsafeMutablePointer<SDBFunc>.allocate(capacity: 1)
    funcPtr.initialize(to: SDBFunc())
    funcPtr.pointee.db = sdb
    funcPtr.pointee.aggregate = aggregate

    let result = sqlite3_create_function(
        sdb.pointee.db, name, args, SQLITE_UTF8, funcPtr,
        aggregate ? nil : { ctx, argc, argv in dbSqlNormalFunction(ctx, argc, argv) },
        aggregate ? { ctx, argc, argv in dbSqlNormalFunction(ctx, argc, argv) } : nil,
        aggregate ? { ctx in dbSqlFinalizeFunction(ctx) } : nil
    )

    if result == SQLITE_OK {
        lua_settop(L, aggregate ? 6 : 5)
        funcPtr.pointee.next = sdb.pointee.funcHead
        sdb.pointee.funcHead = funcPtr

        lua_pushvalue(L, 4)
        funcPtr.pointee.fnStep = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        lua_pushvalue(L, aggregate ? 6 : 5)
        funcPtr.pointee.udata = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        if aggregate {
            lua_pushvalue(L, 5)
            funcPtr.pointee.fnFinalize = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
        }
    } else {
        funcPtr.deallocate()
    }

    lua_pushboolean(L, result == SQLITE_OK ? 1 : 0)
    return 1
}

private func dbSqlNormalFunction(_ context: OpaquePointer?, _ argc: Int32, _ argv: UnsafeMutablePointer<OpaquePointer?>?) {
    guard let context = context else { return }
    let funcPtr = sqlite3_user_data(context).assumingMemoryBound(to: SDBFunc.self)
    let L = funcPtr.pointee.db.pointee.L!
    let top = lua_gettop(L)

    lua_checkstack(L, argc + 3)
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(funcPtr.pointee.fnStep))

    let ctxPtr: UnsafeMutablePointer<LContext>
    if !funcPtr.pointee.aggregate {
        ctxPtr = makeLuaContext(L)
    } else {
        let p = sqlite3_aggregate_context(context, 1)!
        lua_pushlightuserdata(L, p)
        lua_rawget(L, LUA_REGISTRYINDEX_VALUE)
        if lua_isnil(L, -1) {
            lua_pop(L, 1)
            let newCtx = makeLuaContext(L)
            lua_pushlightuserdata(L, p)
            lua_pushvalue(L, -2)
            lua_rawset(L, LUA_REGISTRYINDEX_VALUE)
            ctxPtr = newCtx
        } else {
            ctxPtr = luaL_checkudata(L, -1, sqliteCtxMeta)!.assumingMemoryBound(to: LContext.self)
        }
    }

    for i in 0..<Int(argc) {
        dbPushValue(L, argv![i])
    }

    ctxPtr.pointee.ctx = context

    if lua_pcall(L, argc + 1, 0, 0) != 0 {
        let errmsg = lua_tostring(L, -1)
        let errLen: Int = lua_rawlen(L, -1)
        sqlite3_result_error(context, errmsg, Int32(errLen))
    }

    ctxPtr.pointee.ctx = nil
    if !funcPtr.pointee.aggregate {
        luaL_unref(L, LUA_REGISTRYINDEX_VALUE, ctxPtr.pointee.ud)
    }

    lua_settop(L, top)
}

private func dbSqlFinalizeFunction(_ context: OpaquePointer?) {
    guard let context = context else { return }
    let funcPtr = sqlite3_user_data(context).assumingMemoryBound(to: SDBFunc.self)
    let L = funcPtr.pointee.db.pointee.L!
    let p = sqlite3_aggregate_context(context, 1)!
    let top = lua_gettop(L)

    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(funcPtr.pointee.fnFinalize))

    lua_pushlightuserdata(L, p)
    lua_rawget(L, LUA_REGISTRYINDEX_VALUE)

    let ctxPtr: UnsafeMutablePointer<LContext>
    if lua_isnil(L, -1) {
        lua_pop(L, 1)
        ctxPtr = makeLuaContext(L)
        lua_pushlightuserdata(L, p)
        lua_pushvalue(L, -2)
        lua_rawset(L, LUA_REGISTRYINDEX_VALUE)
    } else {
        ctxPtr = luaL_checkudata(L, -1, sqliteCtxMeta)!.assumingMemoryBound(to: LContext.self)
    }

    ctxPtr.pointee.ctx = context

    if lua_pcall(L, 1, 0, 0) != 0 {
        sqlite3_result_error(context, lua_tostring(L, -1), -1)
    }

    ctxPtr.pointee.ctx = nil
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, ctxPtr.pointee.ud)

    lua_pushlightuserdata(L, p)
    lua_pushnil(L)
    lua_rawset(L, LUA_REGISTRYINDEX_VALUE)

    lua_settop(L, top)
}

private func dbPushValue(_ L: UnsafeMutablePointer<lua_State>!, _ value: OpaquePointer?) {
    guard let value = value else { lua_pushnil(L); return }
    switch sqlite3_value_type(value) {
    case SQLITE_TEXT:
        lua_pushlstring(L, sqlite3_value_text(value), Int(sqlite3_value_bytes(value)))
    case SQLITE_INTEGER:
        pushInt64(L, sqlite3_value_int64(value))
    case SQLITE_FLOAT:
        lua_pushnumber(L, sqlite3_value_double(value))
    case SQLITE_BLOB:
        lua_pushlstring(L, sqlite3_value_blob(value)?.assumingMemoryBound(to: CChar.self), Int(sqlite3_value_bytes(value)))
    case SQLITE_NULL:
        lua_pushnil(L)
    default:
        lua_pushnil(L)
    }
}

// MARK: - Context methods

private func makeLuaContext(_ L: UnsafeMutablePointer<lua_State>!) -> UnsafeMutablePointer<LContext> {
    let p = lua_newuserdata(L, MemoryLayout<LContext>.size)!
    let ctx = p.assumingMemoryBound(to: LContext.self)
    ctx.initialize(to: LContext())
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(sqliteCtxMetaRef))
    lua_setmetatable(L, -2)
    return ctx
}

private func getLuaContext(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<LContext> {
    let p = luaL_checkudata(L, index, sqliteCtxMeta)!
    return p.assumingMemoryBound(to: LContext.self)
}

private func checkLuaContext(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<LContext> {
    let ctx = getLuaContext(L, index)
    if ctx.pointee.ctx == nil {
        luaL_argerror(L, index, "invalid sqlite context")
    }
    return ctx
}

private let lcontext_user_data: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    let funcPtr = sqlite3_user_data(ctx.pointee.ctx).assumingMemoryBound(to: SDBFunc.self)
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(funcPtr.pointee.udata))
    return 1
}

private let lcontext_get_aggregate_context: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    let funcPtr = sqlite3_user_data(ctx.pointee.ctx).assumingMemoryBound(to: SDBFunc.self)
    if !funcPtr.pointee.aggregate {
        return Int32(luaL_error(L, "attempt to call aggregate method from scalar function"))
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(ctx.pointee.ud))
    return 1
}

private let lcontext_set_aggregate_context: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    let funcPtr = sqlite3_user_data(ctx.pointee.ctx).assumingMemoryBound(to: SDBFunc.self)
    if !funcPtr.pointee.aggregate {
        return Int32(luaL_error(L, "attempt to call aggregate method from scalar function"))
    }
    lua_settop(L, 2)
    luaL_unref(L, LUA_REGISTRYINDEX_VALUE, ctx.pointee.ud)
    ctx.pointee.ud = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)
    return 0
}

private let lcontext_aggregate_count: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    let funcPtr = sqlite3_user_data(ctx.pointee.ctx).assumingMemoryBound(to: SDBFunc.self)
    if !funcPtr.pointee.aggregate {
        return Int32(luaL_error(L, "attempt to call aggregate method from scalar function"))
    }
    // sqlite3_aggregate_count is deprecated/unavailable; use sqlite3_aggregate_context size as proxy
    // The original C code also suppressed the deprecation warning.
    // Return 0 as a safe fallback since this API is rarely used.
    lua_pushinteger(L, 0)
    return 1
}

private let lcontext_result: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    switch lua_type(L, 2) {
    case LUA_TNUMBER:
        if lua_isinteger(L, 2) != 0 {
            sqlite3_result_int64(ctx.pointee.ctx, luaL_checkinteger(L, 2))
        } else {
            sqlite3_result_double(ctx.pointee.ctx, luaL_checknumber(L, 2))
        }
    case LUA_TSTRING:
        let s = luaL_checkstring(L, 2)
        let sLen: Int = lua_rawlen(L, 2)
        sqlite3_result_text(ctx.pointee.ctx, s, Int32(sLen), SQLITE_TRANSIENT_VALUE)
    case LUA_TNIL, LUA_TNONE:
        sqlite3_result_null(ctx.pointee.ctx)
    default:
        let typeName = String(cString: lua_typename(L, lua_type(L, 2)))
        return Int32(luaL_error(L, "invalid result type \(typeName)"))
    }
    return 0
}

private let lcontext_result_blob: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    let _ = luaL_checkstring(L, 2)
    let blob = lua_tostring(L, 2)
    let blobSize: Int = lua_rawlen(L, 2)
    sqlite3_result_blob(ctx.pointee.ctx, blob, Int32(blobSize), SQLITE_TRANSIENT_VALUE)
    return 0
}

private let lcontext_result_double: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    sqlite3_result_double(ctx.pointee.ctx, luaL_checknumber(L, 2))
    return 0
}

private let lcontext_result_error: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    let err = luaL_checkstring(L, 2)
    let errSize: Int = lua_rawlen(L, 2)
    sqlite3_result_error(ctx.pointee.ctx, err, Int32(errSize))
    return 0
}

private let lcontext_result_int: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    sqlite3_result_int(ctx.pointee.ctx, Int32(luaL_checkinteger(L, 2)))
    return 0
}

private let lcontext_result_null: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    sqlite3_result_null(ctx.pointee.ctx)
    return 0
}

private let lcontext_result_text: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = checkLuaContext(L, 1)
    let text = luaL_checkstring(L, 2)
    let textSize: Int = lua_rawlen(L, 2)
    sqlite3_result_text(ctx.pointee.ctx, text, Int32(textSize), SQLITE_TRANSIENT_VALUE)
    return 0
}

private let lcontext_tostring: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let ctx = getLuaContext(L, 1)
    if ctx.pointee.ctx == nil {
        lua_pushstring(L, "sqlite function context (closed)")
    } else {
        let p = UnsafeMutableRawPointer(ctx.pointee.ctx!)
        let desc = String(format: "sqlite function context (%p)", Int(bitPattern: p))
        lua_pushstring(L, desc)
    }
    return 1
}

// MARK: - Create collation

private struct CollationContext {
    var L: UnsafeMutablePointer<lua_State>!
    var ref: Int32
}

private let db_create_collation: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sdb = checkDB(L, 1)
    let collname = luaL_checkstring(L, 2)
    lua_settop(L, 3)

    if lua_isfunction(L, 3) {
        let co = UnsafeMutablePointer<CollationContext>.allocate(capacity: 1)
        co.initialize(to: CollationContext(L: L, ref: LUA_NOREF))
        co.pointee.ref = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

        sqlite3_create_collation_v2(
            sdb.pointee.db, collname, SQLITE_UTF8, co,
            { (user, l1, p1, l2, p2) -> Int32 in
                guard let user = user else { return 0 }
                let co = user.assumingMemoryBound(to: CollationContext.self)
                let L = co.pointee.L!
                var res: Int32 = 0
                lua_rawgeti(L, LUA_REGISTRYINDEX_VALUE, lua_Integer(co.pointee.ref))
                lua_pushlstring(L, p1?.assumingMemoryBound(to: CChar.self), Int(l1))
                lua_pushlstring(L, p2?.assumingMemoryBound(to: CChar.self), Int(l2))
                if lua_pcall(L, 2, 1, 0) == 0 {
                    res = Int32(lua_tonumber(L, -1))
                }
                lua_pop(L, 1)
                return res
            },
            { user in
                guard let user = user else { return }
                let co = user.assumingMemoryBound(to: CollationContext.self)
                luaL_unref(co.pointee.L, LUA_REGISTRYINDEX_VALUE, co.pointee.ref)
                co.deallocate()
            }
        )
    } else if !lua_isnil(L, 3) {
        luaL_error(L, "create_collation: function or nil expected")
    } else {
        sqlite3_create_collation_v2(sdb.pointee.db, collname, SQLITE_UTF8, nil, nil, nil)
    }

    return 0
}

// MARK: - Backup API

private func getBackup(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<SDBBackup> {
    let p = luaL_checkudata(L, index, sqliteBuMeta)!
    return p.assumingMemoryBound(to: SDBBackup.self)
}

private func checkBackup(_ L: UnsafeMutablePointer<lua_State>!, _ index: Int32) -> UnsafeMutablePointer<SDBBackup> {
    let sbu = getBackup(L, index)
    if sbu.pointee.bu == nil {
        luaL_argerror(L, index, "attempt to use closed sqlite database backup")
    }
    return sbu
}

private func cleanupBackup(_ L: UnsafeMutablePointer<lua_State>!, _ sbu: UnsafeMutablePointer<SDBBackup>) -> Int32 {
    guard let bu = sbu.pointee.bu else { return 0 }

    lua_pushlightuserdata(L, UnsafeMutableRawPointer(bu))
    lua_pushnil(L)
    lua_rawset(L, LUA_REGISTRYINDEX_VALUE)

    let result = sqlite3_backup_finish(bu)
    sbu.pointee.bu = nil
    lua_pushinteger(L, lua_Integer(result))
    return 1
}

private let lsqlite_backup_init: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let targetDb = checkDB(L, 1)
    let targetNm = luaL_checkstring(L, 2)
    let sourceDb = checkDB(L, 3)
    let sourceNm = luaL_checkstring(L, 4)

    guard let bu = sqlite3_backup_init(targetDb.pointee.db, targetNm, sourceDb.pointee.db, sourceNm) else {
        return 0
    }

    let p = lua_newuserdata(L, MemoryLayout<SDBBackup>.size)!
    let sbu = p.assumingMemoryBound(to: SDBBackup.self)
    sbu.initialize(to: SDBBackup(bu: bu))
    luaL_getmetatable(L, sqliteBuMeta)
    lua_setmetatable(L, -2)

    lua_pushlightuserdata(L, UnsafeMutableRawPointer(bu))
    lua_createtable(L, 2, 0)
    lua_pushvalue(L, 1)
    lua_rawseti(L, -2, 1)
    lua_pushvalue(L, 3)
    lua_rawseti(L, -2, 2)
    lua_rawset(L, LUA_REGISTRYINDEX_VALUE)

    return 1
}

private let dbbu_step: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sbu = checkBackup(L, 1)
    let nPage = Int32(luaL_checkinteger(L, 2))
    lua_pushinteger(L, lua_Integer(sqlite3_backup_step(sbu.pointee.bu, nPage)))
    return 1
}

private let dbbu_remaining: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sbu = checkBackup(L, 1)
    lua_pushinteger(L, lua_Integer(sqlite3_backup_remaining(sbu.pointee.bu)))
    return 1
}

private let dbbu_pagecount: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sbu = checkBackup(L, 1)
    lua_pushinteger(L, lua_Integer(sqlite3_backup_pagecount(sbu.pointee.bu)))
    return 1
}

private let dbbu_finish: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sbu = checkBackup(L, 1)
    return Int32(cleanupBackup(L, sbu))
}

private let dbbu_gc: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sbu = getBackup(L, 1)
    if sbu.pointee.bu != nil {
        _ = cleanupBackup(L, sbu)
        lua_pop(L, 1)
    }
    return 0
}

// MARK: - Library-level functions

private let lsqlite_version: lua_CFunction = { L in
    guard let L = L else { return 0 }
    lua_pushstring(L, sqlite3_libversion())
    return 1
}

private let lsqlite_lversion: lua_CFunction = { L in
    guard let L = L else { return 0 }
    lua_pushstring(L, "0.9.5")
    return 1
}

private let lsqlite_complete: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let sql = luaL_checkstring(L, 1)
    lua_pushboolean(L, sqlite3_complete(sql))
    return 1
}

private let lsqlite_temp_directory: lua_CFunction = { L in
    guard let L = L else { return 0 }
    lua_pushstring(L, sqlite3_temp_directory)
    if lua_type(L, 1) != LUA_TNONE {
        if sqlite3_temp_directory != nil {
            sqlite3_free(UnsafeMutableRawPointer(mutating: sqlite3_temp_directory))
        }
        if lua_type(L, 1) == LUA_TSTRING {
            if let temp = lua_tostring(L, 1) {
                let dup = strdup(temp)
                sqlite3_temp_directory = UnsafeMutablePointer(mutating: dup)
            }
        } else {
            sqlite3_temp_directory = nil
        }
    }
    return 1
}

private func doOpen(_ L: UnsafeMutablePointer<lua_State>!, _ filename: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    let sdb = newDB(L)

    if sqlite3_open_v2(filename, &sdb.pointee.db, flags, nil) == SQLITE_OK {
        return 1
    }

    lua_pushnil(L)
    lua_pushinteger(L, lua_Integer(sqlite3_errcode(sdb.pointee.db)))
    lua_pushstring(L, sqlite3_errmsg(sdb.pointee.db))
    _ = cleanupDB(L, sdb)
    return 3
}

private let lsqlite_open: lua_CFunction = { L in
    guard let L = L else { return 0 }
    let filename = luaL_checkstring(L, 1)!
    let flags = Int32(luaL_optinteger(L, 2, lua_Integer(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)))
    return doOpen(L, filename, flags)
}

private let lsqlite_open_memory: lua_CFunction = { L in
    guard let L = L else { return 0 }
    return doOpen(L, ":memory:", Int32(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE))
}

private let lsqlite_open_ptr: lua_CFunction = { L in
    guard let L = L else { return 0 }
    luaL_checktype(L, 1, LUA_TLIGHTUSERDATA)
    let dbPtr = lua_touserdata(L, 1)!.assumingMemoryBound(to: OpaquePointer?.self).pointee!
    let rc = sqlite3_exec(dbPtr, nil, nil, nil, nil)
    if rc != SQLITE_OK {
        luaL_argerror(L, 1, "not a valid SQLite3 pointer")
    }
    let sdb = newDB(L)
    sdb.pointee.db = dbPtr
    return 1
}

private let lsqlite_newindex: lua_CFunction = { L in
    guard let L = L else { return 0 }
    luaL_error(L, "attempt to change readonly table")
    return 0
}

// MARK: - Metatable creation helper

private func createMeta(_ L: UnsafeMutablePointer<lua_State>!, _ name: UnsafePointer<CChar>, _ lib: [(StaticString, lua_CFunction?)]) {
    luaL_newmetatable(L, name)
    lua_pushstring(L, "__index")
    lua_pushvalue(L, -2)
    lua_rawset(L, -3)

    for (methodName, fn) in lib {
        methodName.withUTF8Buffer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count + 1) { cstr in
                lua_pushcclosure(L, fn, 0)
                lua_setfield(L, -2, cstr)
            }
        }
    }

    lua_pop(L, 1)
}

// MARK: - Module entry point

@_cdecl("luaopen_hs_liblsqlite3")
public func luaopen_hs_liblsqlite3(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {

    let dbMethods: [(StaticString, lua_CFunction?)] = [
        ("isopen",              db_isopen),
        ("last_insert_rowid",   db_last_insert_rowid),
        ("changes",             db_changes),
        ("total_changes",       db_total_changes),
        ("errcode",             db_errcode),
        ("error_code",          db_errcode),
        ("errmsg",              db_errmsg),
        ("error_message",       db_errmsg),
        ("interrupt",           db_interrupt),
        ("db_filename",         db_db_filename),
        ("create_function",     db_create_function),
        ("create_aggregate",    db_create_aggregate),
        ("create_collation",    db_create_collation),
        ("trace",               db_trace),
        ("progress_handler",    db_progress_handler),
        ("busy_timeout",        db_busy_timeout),
        ("busy_handler",        db_busy_handler),
        ("update_hook",         db_update_hook),
        ("commit_hook",         db_commit_hook),
        ("rollback_hook",       db_rollback_hook),
        ("prepare",             db_prepare),
        ("rows",                db_rows),
        ("urows",               db_urows),
        ("nrows",               db_nrows),
        ("exec",                db_exec),
        ("execute",             db_exec),
        ("close",               db_close),
        ("close_vm",            db_close_vm),
        ("get_ptr",             db_get_ptr),
        ("__tostring",          db_tostring),
        ("__gc",                db_gc),
    ]
    createMeta(L, sqliteDbMeta, dbMethods)

    let vmMethods: [(StaticString, lua_CFunction?)] = [
        ("isopen",              dbvm_isopen),
        ("step",                dbvm_step),
        ("reset",               dbvm_reset),
        ("finalize",            dbvm_finalize),
        ("columns",             dbvm_columns),
        ("bind",                dbvm_bind),
        ("bind_values",         dbvm_bind_values),
        ("bind_names",          dbvm_bind_names),
        ("bind_blob",           dbvm_bind_blob),
        ("bind_parameter_count", dbvm_bind_parameter_count),
        ("bind_parameter_name", dbvm_bind_parameter_name),
        ("get_value",           dbvm_get_value),
        ("get_values",          dbvm_get_values),
        ("get_name",            dbvm_get_name),
        ("get_names",           dbvm_get_names),
        ("get_type",            dbvm_get_type),
        ("get_types",           dbvm_get_types),
        ("get_uvalues",         dbvm_get_uvalues),
        ("get_unames",          dbvm_get_unames),
        ("get_utypes",          dbvm_get_utypes),
        ("get_named_values",    dbvm_get_named_values),
        ("get_named_types",     dbvm_get_named_types),
        ("rows",                dbvm_rows),
        ("urows",               dbvm_urows),
        ("nrows",               dbvm_nrows),
        ("last_insert_rowid",   dbvm_last_insert_rowid),
        ("idata",               dbvm_get_values),
        ("inames",              dbvm_get_names),
        ("itypes",              dbvm_get_types),
        ("data",                dbvm_get_named_values),
        ("type",                dbvm_get_named_types),
        ("__tostring",          dbvm_tostring),
        ("__gc",                dbvm_gc),
    ]
    createMeta(L, sqliteVmMeta, vmMethods)

    let buMethods: [(StaticString, lua_CFunction?)] = [
        ("step",        dbbu_step),
        ("remaining",   dbbu_remaining),
        ("pagecount",   dbbu_pagecount),
        ("finish",      dbbu_finish),
        ("__gc",        dbbu_gc),
    ]
    createMeta(L, sqliteBuMeta, buMethods)

    let ctxMethods: [(StaticString, lua_CFunction?)] = [
        ("user_data",               lcontext_user_data),
        ("get_aggregate_data",      lcontext_get_aggregate_context),
        ("set_aggregate_data",      lcontext_set_aggregate_context),
        ("aggregate_count",         lcontext_aggregate_count),
        ("result",                  lcontext_result),
        ("result_null",             lcontext_result_null),
        ("result_number",           lcontext_result_double),
        ("result_double",           lcontext_result_double),
        ("result_int",              lcontext_result_int),
        ("result_text",             lcontext_result_text),
        ("result_blob",             lcontext_result_blob),
        ("result_error",            lcontext_result_error),
        ("__tostring",              lcontext_tostring),
    ]
    createMeta(L, sqliteCtxMeta, ctxMethods)

    luaL_getmetatable(L, sqliteCtxMeta)
    sqliteCtxMetaRef = luaL_ref(L, LUA_REGISTRYINDEX_VALUE)

    // Create the module table
    lua_newtable(L)

    let libFuncs: [(StaticString, lua_CFunction?)] = [
        ("lversion",        lsqlite_lversion),
        ("version",         lsqlite_version),
        ("complete",        lsqlite_complete),
        ("temp_directory",  lsqlite_temp_directory),
        ("open",            lsqlite_open),
        ("open_memory",     lsqlite_open_memory),
        ("open_ptr",        lsqlite_open_ptr),
        ("backup_init",     lsqlite_backup_init),
        ("__newindex",      lsqlite_newindex),
    ]

    for (name, fn) in libFuncs {
        name.withUTF8Buffer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count + 1) { cstr in
                lua_pushcclosure(L, fn, 0)
                lua_setfield(L, -2, cstr)
            }
        }
    }

    // Constants
    let constants: [(StaticString, Int32)] = [
        ("OK",          SQLITE_OK), ("ERROR",       SQLITE_ERROR),
        ("INTERNAL",    SQLITE_INTERNAL), ("PERM",        SQLITE_PERM),
        ("ABORT",       SQLITE_ABORT), ("BUSY",        SQLITE_BUSY),
        ("LOCKED",      SQLITE_LOCKED), ("NOMEM",       SQLITE_NOMEM),
        ("READONLY",    SQLITE_READONLY), ("INTERRUPT",   SQLITE_INTERRUPT),
        ("IOERR",       SQLITE_IOERR), ("CORRUPT",     SQLITE_CORRUPT),
        ("NOTFOUND",    SQLITE_NOTFOUND), ("FULL",        SQLITE_FULL),
        ("CANTOPEN",    SQLITE_CANTOPEN), ("PROTOCOL",    SQLITE_PROTOCOL),
        ("EMPTY",       SQLITE_EMPTY), ("SCHEMA",      SQLITE_SCHEMA),
        ("TOOBIG",      SQLITE_TOOBIG), ("CONSTRAINT",  SQLITE_CONSTRAINT),
        ("MISMATCH",    SQLITE_MISMATCH), ("MISUSE",      SQLITE_MISUSE),
        ("NOLFS",       SQLITE_NOLFS), ("FORMAT",      SQLITE_FORMAT),
        ("NOTADB",      SQLITE_NOTADB),
        ("RANGE",       SQLITE_RANGE), ("ROW",         SQLITE_ROW),
        ("DONE",        SQLITE_DONE),
        ("INTEGER",     SQLITE_INTEGER), ("FLOAT",       SQLITE_FLOAT),
        ("TEXT",        SQLITE_TEXT), ("BLOB",        SQLITE_BLOB),
        ("NULL",        SQLITE_NULL),
        ("CREATE_INDEX",        SQLITE_CREATE_INDEX),
        ("CREATE_TABLE",        SQLITE_CREATE_TABLE),
        ("CREATE_TEMP_INDEX",   SQLITE_CREATE_TEMP_INDEX),
        ("CREATE_TEMP_TABLE",   SQLITE_CREATE_TEMP_TABLE),
        ("CREATE_TEMP_TRIGGER", SQLITE_CREATE_TEMP_TRIGGER),
        ("CREATE_TEMP_VIEW",    SQLITE_CREATE_TEMP_VIEW),
        ("CREATE_TRIGGER",      SQLITE_CREATE_TRIGGER),
        ("CREATE_VIEW",         SQLITE_CREATE_VIEW),
        ("DELETE",              SQLITE_DELETE),
        ("DROP_INDEX",          SQLITE_DROP_INDEX),
        ("DROP_TABLE",          SQLITE_DROP_TABLE),
        ("DROP_TEMP_INDEX",     SQLITE_DROP_TEMP_INDEX),
        ("DROP_TEMP_TABLE",     SQLITE_DROP_TEMP_TABLE),
        ("DROP_TEMP_TRIGGER",   SQLITE_DROP_TEMP_TRIGGER),
        ("DROP_TEMP_VIEW",      SQLITE_DROP_TEMP_VIEW),
        ("DROP_TRIGGER",        SQLITE_DROP_TRIGGER),
        ("DROP_VIEW",           SQLITE_DROP_VIEW),
        ("INSERT",              SQLITE_INSERT),
        ("PRAGMA",              SQLITE_PRAGMA),
        ("READ",                SQLITE_READ),
        ("SELECT",              SQLITE_SELECT),
        ("TRANSACTION",         SQLITE_TRANSACTION),
        ("UPDATE",              SQLITE_UPDATE),
        ("ATTACH",              SQLITE_ATTACH),
        ("DETACH",              SQLITE_DETACH),
        ("ALTER_TABLE",         SQLITE_ALTER_TABLE),
        ("REINDEX",             SQLITE_REINDEX),
        ("ANALYZE",             SQLITE_ANALYZE),
        ("CREATE_VTABLE",       SQLITE_CREATE_VTABLE),
        ("DROP_VTABLE",         SQLITE_DROP_VTABLE),
        ("FUNCTION",            SQLITE_FUNCTION),
        ("SAVEPOINT",           SQLITE_SAVEPOINT),
        ("OPEN_READONLY",       SQLITE_OPEN_READONLY),
        ("OPEN_READWRITE",      SQLITE_OPEN_READWRITE),
        ("OPEN_CREATE",         SQLITE_OPEN_CREATE),
        ("OPEN_URI",            SQLITE_OPEN_URI),
        ("OPEN_MEMORY",         SQLITE_OPEN_MEMORY),
        ("OPEN_NOMUTEX",        SQLITE_OPEN_NOMUTEX),
        ("OPEN_FULLMUTEX",      SQLITE_OPEN_FULLMUTEX),
        ("OPEN_SHAREDCACHE",    SQLITE_OPEN_SHAREDCACHE),
        ("OPEN_PRIVATECACHE",   SQLITE_OPEN_PRIVATECACHE),
    ]

    for (name, value) in constants {
        name.withUTF8Buffer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count + 1) { cstr in
                lua_pushstring(L, cstr)
                lua_pushinteger(L, lua_Integer(value))
                lua_rawset(L, -3)
            }
        }
    }

    // Set module table as its own metatable (for __newindex readonly guard)
    lua_pushvalue(L, -1)
    lua_setmetatable(L, -2)

    return 1
}
