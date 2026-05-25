/*
 ** LuaFileSystem
 ** Copyright Kepler Project 2003 (http://www.keplerproject.org/luafilesystem)
 **
 ** File system manipulation library.
 ** This library offers these functions:
 **   lfs.attributes (filepath [, attributename])
 **   lfs.chdir (path)
 **   lfs.currentDir ()
 **   lfs.dir (path)
 **   lfs.lock (fh, mode)
 **   lfs.lock_dir (path)
 **   lfs.mkdir (path)
 **   lfs.rmdir (path)
 **   lfs.setmode (filepath, mode)
 **   lfs.symlinkAttributes (filepath [, attributename]) -- thanks to Sam Roberts
 **   lfs.touch (filepath [, atime [, mtime]])
 **   lfs.unlock (fh)
 **
 ** $Id: lfs.c,v 1.61 2009/07/04 02:10:16 mascarenhas Exp $
 */

import Cocoa
import LuaSkin

// MARK: - Constants

private let LFS_MAXPATHLEN = Int(MAXPATHLEN)

private let DIR_METATABLE = "directory metatable"
private let LOCK_METATABLE = "lock metatable"
private let USERDATA_TAG: StaticString = "hs.fs"

// MARK: - C Struct wrappers

private struct dir_data {
    var closed: Int32
    var dir: OpaquePointer? // DIR*
}

private struct lfs_Lock {
    var ln: UnsafeMutablePointer<CChar>?
}

// MARK: - Utility functions

func path_to_nsurl(_ path: NSString) -> NSURL {
    return NSURL(fileURLWithPath: path.expandingTildeInPath)
}

func path_at_index(_ L: UnsafeMutablePointer<lua_State>!, _ i: Int32) -> UnsafePointer<CChar>? {
    let path = LuaSkin.skin(with: L).toNSObject(atIndex: i) as! NSString
    return (path_to_nsurl(path).path as NSString?)?.utf8String
}

func tags_from_lua_stack(_ L: UnsafeMutablePointer<lua_State>!) -> NSArray {
    let tags = NSMutableSet()

    lua_pushnil(L)
    while lua_next(L, 2) != 0 {
        if lua_type(L, -1) == LUA_TSTRING {
            let tag = LuaSkin.skin(with: L).toNSObject(atIndex: -1) as! NSString
            tags.add(tag)
        }
        lua_pop(L, 1)
    }
    return tags.allObjects as NSArray
}

func tags_from_file(_ L: UnsafeMutablePointer<lua_State>!, _ filePath: NSString) -> NSArray? {
    let url = path_to_nsurl(filePath) as URL

    do {
        let values = try url.resourceValues(forKeys: [.tagNamesKey])
        return values.tagNames as NSArray?
    } catch {
        luaL_error(L, error.localizedDescription)
        return nil
    }
}

func tags_to_file(_ L: UnsafeMutablePointer<lua_State>!, _ filePath: NSString, _ tags: NSArray) -> Bool {
    let url = path_to_nsurl(filePath) as URL

    do {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    } catch {
        luaL_error(L, error.localizedDescription)
        return false
    }
    return true
}

private func pusherror(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<CChar>?) -> Int32 {
    lua_pushnil(L)
    if info == nil {
        lua_pushstring(L, strerror(errno))
    } else {
        let infoStr = String(cString: info!)
        let errStr = String(cString: strerror(errno)!)
        lua_pushstring(L, "\(infoStr): \(errStr)")
    }
    return 2
}

// MARK: - Directory / File operations

/// hs.fs.chdir(path) -> true or (nil,error)
/// Function
/// Changes the current working directory to the given path.
///
/// Parameters:
///  * path - A string containing the path to change working directory to
///
/// Returns:
///  * If successful, returns true, otherwise returns nil and an error string
private func change_dir(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TSTRING, LS_TBREAK)
    let path = path_at_index(L, 1)

    if chdir(path) != 0 {
        lua_pushnil(L)
        let pathStr = String(cString: path!)
        let errStr = String(cString: strerror(errno)!)
        lua_pushstring(L, "Unable to change working directory to '\(pathStr)'\n\(errStr)\n")
        return 2
    } else {
        lua_pushboolean(L, 1)
        return 1
    }
}

/// hs.fs.currentDir() -> string or (nil,error)
/// Function
/// Gets the current working directory
///
/// Parameters:
///  * None
///
/// Returns:
///  * A string containing the current working directory, or if an error occurred, nil and an error string
private func get_dir(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var path: UnsafeMutablePointer<CChar>? = nil
    var size = LFS_MAXPATHLEN
    var result: Int32

    while true {
        let path2 = realloc(path, size)
        if path2 == nil {
            result = pusherror(L, "get_dir realloc() failed")
            break
        }
        path = path2?.assumingMemoryBound(to: CChar.self)
        if getcwd(path, size) != nil {
            lua_pushstring(L, path)
            result = 1
            break
        }
        if errno != ERANGE {
            result = pusherror(L, "get_dir getcwd() failed")
            break
        }
        size *= 2
    }
    free(path)
    return result
}

/*
 ** Check if the given element on the stack is a file and returns it.
 */
private func check_file(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32, _ funcname: UnsafePointer<CChar>) -> OpaquePointer? {
    let fh = luaL_checkudata(L, idx, "FILE*")!.assumingMemoryBound(to: luaL_Stream.self)
    if fh.pointee.closef == nil || fh.pointee.f == nil {
        let name = String(cString: funcname)
        luaL_error(L, "\(name): closed file")
        return nil
    } else {
        return OpaquePointer(fh.pointee.f)
    }
}

/// hs.fs.lock(filehandle, mode[, start[, length]]) -> true or (nil,error)
/// Function
/// Locks a file, or part of it
///
/// Parameters:
///  * filehandle - An open file
///  * mode - A string containing either "r" for a shared read lock, or "w" for an exclusive write lock
///  * start - An optional number containing an offset into the file to start the lock at. Defaults to 0
///  * length - An optional number containing the length of the file to lock. Defaults to the full size of the file
///
/// Returns:
///  * True if the lock was obtained successfully, otherwise nil and an error string
private func _file_lock(_ L: UnsafeMutablePointer<lua_State>!, _ fh: OpaquePointer, _ mode: UnsafePointer<CChar>, _ start: CLong, _ len: CLong, _ funcname: UnsafePointer<CChar>) -> Bool {
    var f = flock()
    let modeChar = mode.pointee
    switch Int32(modeChar) {
    case Int32(UInt8(ascii: "w")):
        f.l_type = Int16(F_WRLCK)
    case Int32(UInt8(ascii: "r")):
        f.l_type = Int16(F_RDLCK)
    case Int32(UInt8(ascii: "u")):
        f.l_type = Int16(F_UNLCK)
    default:
        let name = String(cString: funcname)
        luaL_error(L, "\(name): invalid mode")
        return false
    }
    f.l_whence = Int16(SEEK_SET)
    f.l_start = off_t(start)
    f.l_len = off_t(len)
    let filePtr = UnsafeMutablePointer<FILE>(fh)
    let code = fcntl(fileno(filePtr), F_SETLK, &f)
    return code != -1
}

/// hs.fs.lockDir(path, [seconds_stale]) -> lock or (nil,error)
/// Function
/// Locks a directory
///
/// Parameters:
///  * path - A string containing the path to a directory
///  * seconds_stale - An optional number containing an age (in seconds) beyond which to consider an existing lock as stale. Defaults to INT_MAX (which is, broadly speaking, equivalent to "never")
///
/// Returns:
///  * If successful, a lock object, otherwise nil and an error string
///
/// Notes:
///  * This is not a low level OS feature, the lock is actually a file created in the path, called `lockfile.lfs`, so the directory must be writable for this function to succeed
///  * The returned lock object can be freed with ```lock:free()```
///  * If the lock already exists and is not stale, the error string returned will be "File exists"
private func lfs_lock_dir(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    var pathl: Int = 0
    let lockfile = "/lockfile.lfs"
    let path = luaL_checklstring(L, 1, &pathl)!
    let lock = lua_newuserdata(L, MemoryLayout<lfs_Lock>.size)!.assumingMemoryBound(to: lfs_Lock.self)
    let ln = UnsafeMutablePointer<CChar>.allocate(capacity: pathl + strlen(lockfile) + 1)
    strcpy(ln, path)
    strcat(ln, lockfile)
    if symlink("lock", ln) == -1 {
        ln.deallocate()
        lua_pushnil(L)
        lua_pushstring(L, strerror(errno))
        return 2
    }
    lock.pointee.ln = ln
    luaL_getmetatable(L, LOCK_METATABLE)
    lua_setmetatable(L, -2)
    return 1
}

private func lfs_unlock_dir(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let lock = luaL_checkudata(L, 1, LOCK_METATABLE)!.assumingMemoryBound(to: lfs_Lock.self)
    if lock.pointee.ln != nil {
        unlink(lock.pointee.ln)
        lock.pointee.ln?.deallocate()
        lock.pointee.ln = nil
    }
    return 0
}

/*
 ** Locks a file.
 ** @param #1 File handle.
 ** @param #2 String with lock mode ('w'rite, 'r'ead).
 ** @param #3 Number with start position (optional).
 ** @param #4 Number with length (optional).
 */
private func file_lock(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let fh = check_file(L, 1, "lock")!
    let mode = luaL_checkstring(L, 2)!
    let start = CLong(luaL_optinteger(L, 3, 0))
    let len = CLong(luaL_optinteger(L, 4, 0))
    if _file_lock(L, fh, mode, start, len, "lock") {
        lua_pushboolean(L, 1)
        return 1
    } else {
        lua_pushnil(L)
        lua_pushstring(L, strerror(errno))
        return 2
    }
}

/// hs.fs.unlock(filehandle[, start[, length]]) -> true or (nil,error)
/// Function
/// Unlocks a file or a part of it.
///
/// Parameters:
///  * filehandle - An open file
///  * start - An optional number containing an offset from the start of the file, to unlock. Defaults to 0
///  * length - An optional number containing the length of file to unlock. Defaults to the full size of the file
///
/// Returns:
///  * True if the unlock succeeded, otherwise nil and an error string
private func file_unlock(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let fh = check_file(L, 1, "unlock")!
    let start = CLong(luaL_optinteger(L, 2, 0))
    let len = CLong(luaL_optinteger(L, 3, 0))
    if _file_lock(L, fh, "u", start, len, "unlock") {
        lua_pushboolean(L, 1)
        return 1
    } else {
        lua_pushnil(L)
        lua_pushstring(L, strerror(errno))
        return 2
    }
}

/// hs.fs.link(old, new[, symlink]) -> true or (nil,error)
/// Function
/// Creates a link
///
/// Parameters:
///  * old - A string containing a path to a filesystem object to link from
///  * new - A string containing a path to create the link at
///  * symlink - An optional boolean, true to create a symlink, false to create a hard link. Defaults to false
///
/// Returns:
///  * True if the link was created, otherwise nil and an error string
private func make_link(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TSTRING, LS_TSTRING, LS_TBOOLEAN | LS_TOPTIONAL, LS_TBREAK)
    let oldpath = path_at_index(L, 1)
    let newpath = path_at_index(L, 2)
    var hasError: Bool

    if lua_toboolean(L, 3) != 0 {
        hasError = (symlink(oldpath, newpath) != 0)
    } else {
        hasError = (link(oldpath, newpath) != 0)
    }

    if hasError {
        lua_pushnil(L)
        lua_pushstring(L, strerror(errno))
        return 2
    } else {
        lua_pushboolean(L, 1)
    }

    return 1
}

/// hs.fs.mkdir(dirname) -> true or (nil,error)
/// Function
/// Creates a new directory
///
/// Parameters:
///  * dirname - A string containing the path of a directory to create
///
/// Returns:
///  * True if the directory was created, otherwise nil and an error string
private func make_dir(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TSTRING, LS_TBREAK)
    let path = path_at_index(L, 1)

    let fail = mkdir(path, S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP |
                     S_IWGRP | S_IXGRP | S_IROTH | S_IXOTH)
    if fail != 0 {
        lua_pushnil(L)
        lua_pushstring(L, strerror(errno))
        return 2
    }
    lua_pushboolean(L, 1)
    return 1
}

/// hs.fs.rmdir(dirname) -> true or (nil,error)
/// Function
/// Removes an existing directory
///
/// Parameters:
///  * dirname - A string containing the path to a directory to remove
///
/// Returns:
///  * True if the directory was removed, otherwise nil and an error string
private func remove_dir(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TSTRING, LS_TBREAK)
    let path = path_at_index(L, 1)

    let fail = rmdir(path)

    if fail != 0 {
        lua_pushnil(L)
        lua_pushstring(L, strerror(errno))
        return 2
    }
    lua_pushboolean(L, 1)
    return 1
}

// MARK: - Directory iterator

private func dir_iter(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let d = luaL_checkudata(L, 1, DIR_METATABLE)!.assumingMemoryBound(to: dir_data.self)
    luaL_argcheck(L, d.pointee.closed == 0, 1, "closed directory")

    let dirPtr = UnsafeMutablePointer<DIR>(d.pointee.dir!)
    if let entry = readdir(dirPtr) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { namePtr in
            namePtr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { ptr in
                String(cString: ptr)
            }
        }
        lua_pushstring(L, name)
        return 1
    } else {
        closedir(dirPtr)
        d.pointee.closed = 1
        return 0
    }
}

private func dir_close(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let d = lua_touserdata(L, 1)!.assumingMemoryBound(to: dir_data.self)
    if d.pointee.closed == 0, let dirPtr = d.pointee.dir {
        closedir(UnsafeMutablePointer<DIR>(dirPtr))
    }
    d.pointee.closed = 1
    return 0
}

/// hs.fs.dir(path) -> iter_fn, dir_obj, nil, dir_obj
/// Function
/// Creates an iterator for walking a filesystem path
///
/// Parameters:
///  * path - A string containing a directory to iterate
///
/// Returns:
///  * An iterator function
///  * A data object to pass to the iterator function or an error message as a string
///  * `nil` as the initial argument for the iterator (unused and unnecessary in this case, but conforms to Lua spec for iterators). Ignore this value if you are not using this function with `for` (see Notes).
///  * A second data object used by `for` to close the directory object immediately when the loop terminates. Ignore this value if you are not using this function with `for` (see Notes).
///
/// Notes:
///  * Unlike most functions in this module, `hs.fs.dir` will throw a Lua error if the supplied path cannot be iterated.
///
///  * The simplest way to use this function is with a `for` loop. When used in this manner, the `for` loop itself will take care of closing the directory stream for us, even if we break out of the loop early.
///    ```
///       for file in hs.fs.dir("/Users/Guest/Documents") do
///           print(file)
///       end
///    ```
///
///  * It is also possible to use the dir_obj directly if you wish:
///    ```
///       local iterFn, dirObj = hs.fs.dir("/Users/Guest/Documents")
///       local file = dirObj:next() -- get the first file in the directory
///       while (file) do
///           print(file)
///           file = dirObj:next() -- get the next file in the directory
///       end
///       dirObj:close() -- necessary to make sure that the directory stream is closed
///    ```
private func dir_iter_factory(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TSTRING, LS_TBREAK)
    let path = path_at_index(L, 1)
    lua_pushcfunction(L, dir_iter)
    let d = lua_newuserdata(L, MemoryLayout<dir_data>.size)!.assumingMemoryBound(to: dir_data.self)
    luaL_getmetatable(L, DIR_METATABLE)
    lua_setmetatable(L, -2)
    d.pointee.closed = 0
    if let dirp = opendir(path) {
        d.pointee.dir = OpaquePointer(dirp)
    } else {
        d.pointee.dir = nil
    }
    if d.pointee.dir == nil {
        let pathStr = String(cString: path!)
        let errStr = String(cString: strerror(errno)!)
        return luaL_error(L, "cannot open \(pathStr): \(errStr)")
    }

    // Lua 5.4: use __close to close dir if you break the iterator
    lua_pushnil(L)
    lua_pushvalue(L, -2) // forces "to-be-closed" when used with `for`
    return 4
}

private func dir_create_meta(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_newmetatable(L, DIR_METATABLE)

    // Method table
    lua_newtable(L)
    lua_pushcfunction(L, dir_iter)
    lua_setfield(L, -2, "next")
    lua_pushcfunction(L, dir_close)
    lua_setfield(L, -2, "close")

    // Metamethods
    lua_setfield(L, -2, "__index")
    lua_pushcfunction(L, dir_close)
    lua_setfield(L, -2, "__gc")

    lua_pushcfunction(L, dir_close)
    lua_setfield(L, -2, "__close")
    return 1
}

private func lock_create_meta(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    luaL_newmetatable(L, LOCK_METATABLE)

    // Method table
    lua_newtable(L)
    lua_pushcfunction(L, lfs_unlock_dir)
    lua_setfield(L, -2, "free")

    // Metamethods
    lua_setfield(L, -2, "__index")
    lua_pushcfunction(L, lfs_unlock_dir)
    lua_setfield(L, -2, "__gc")
    return 1
}

// MARK: - Stat helpers

private func mode2string(_ mode: mode_t) -> UnsafePointer<CChar> {
    if (mode & S_IFMT) == S_IFREG  { return makeCString("file") }
    if (mode & S_IFMT) == S_IFDIR  { return makeCString("directory") }
    if (mode & S_IFMT) == S_IFLNK  { return makeCString("link") }
    if (mode & S_IFMT) == S_IFSOCK { return makeCString("socket") }
    if (mode & S_IFMT) == S_IFIFO  { return makeCString("named pipe") }
    if (mode & S_IFMT) == S_IFCHR  { return makeCString("char device") }
    if (mode & S_IFMT) == S_IFBLK  { return makeCString("block device") }
    return makeCString("other")
}

// Helper to produce stable C string pointers for mode2string / perm2string
private func makeCString(_ s: StaticString) -> UnsafePointer<CChar> {
    return s.utf8Start.withMemoryRebound(to: CChar.self, capacity: s.utf8CodeUnitCount + 1) { $0 }
}

/// hs.fs.touch(filepath [, atime [, mtime]]) -> true or (nil,error)
/// Function
/// Updates the access and modification times of a file
///
/// Parameters:
///  * filepath - A string containing the path of a file to touch
///  * atime - An optional number containing the new access time of the file to set (as seconds since the Epoch). Defaults to now
///  * mtime - An optional number containing the new modification time of the file to set (as seconds since the Epoch). Defaults to the value of atime
///
/// Returns:
///  * True if the operation was successful, otherwise nil and an error string
private func file_utime(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TSTRING, LS_TNUMBER | LS_TOPTIONAL, LS_TNUMBER | LS_TOPTIONAL, LS_TBREAK)
    let file = path_at_index(L, 1)

    if lua_gettop(L) == 1 {
        // set to current date/time
        if utime(file, nil) != 0 {
            lua_pushnil(L)
            lua_pushstring(L, strerror(errno))
            return 2
        }
    } else {
        var utb = utimbuf()
        utb.actime = time_t(luaL_optinteger(L, 2, 0))
        utb.modtime = time_t(luaL_optinteger(L, 3, lua_Integer(utb.actime)))
        if utime(file, &utb) != 0 {
            lua_pushnil(L)
            lua_pushstring(L, strerror(errno))
            return 2
        }
    }
    lua_pushboolean(L, 1)
    return 1
}

// MARK: - Stat member pushers

private func push_st_mode(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushstring(L, mode2string(info.pointee.st_mode))
}
private func push_st_dev(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_dev))
}
private func push_st_ino(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_ino))
}
private func push_st_nlink(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_nlink))
}
private func push_st_uid(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_uid))
}
private func push_st_gid(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_gid))
}
private func push_st_rdev(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_rdev))
}
private func push_st_atime(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_atimespec.tv_sec))
}
private func push_st_mtime(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_mtimespec.tv_sec))
}
private func push_st_ctime(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_ctimespec.tv_sec))
}
private func push_st_birthtime(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_birthtimespec.tv_sec))
}
private func push_st_size(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_size))
}
private func push_st_blocks(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_blocks))
}
private func push_st_blksize(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    lua_pushinteger(L, lua_Integer(info.pointee.st_blksize))
}

private func perm2string(_ mode: mode_t) -> UnsafePointer<CChar> {
    // We need a stable buffer for the permission string
    let perms = UnsafeMutablePointer<CChar>.allocate(capacity: 10)
    for i in 0..<9 { perms[i] = Int8(UInt8(ascii: "-")) }
    perms[9] = 0
    if mode & S_IRUSR != 0 { perms[0] = Int8(UInt8(ascii: "r")) }
    if mode & S_IWUSR != 0 { perms[1] = Int8(UInt8(ascii: "w")) }
    if mode & S_IXUSR != 0 { perms[2] = Int8(UInt8(ascii: "x")) }
    if mode & S_IRGRP != 0 { perms[3] = Int8(UInt8(ascii: "r")) }
    if mode & S_IWGRP != 0 { perms[4] = Int8(UInt8(ascii: "w")) }
    if mode & S_IXGRP != 0 { perms[5] = Int8(UInt8(ascii: "x")) }
    if mode & S_IROTH != 0 { perms[6] = Int8(UInt8(ascii: "r")) }
    if mode & S_IWOTH != 0 { perms[7] = Int8(UInt8(ascii: "w")) }
    if mode & S_IXOTH != 0 { perms[8] = Int8(UInt8(ascii: "x")) }
    return UnsafePointer(perms)
}

private func push_st_perm(_ L: UnsafeMutablePointer<lua_State>!, _ info: UnsafePointer<stat>) {
    let perms = perm2string(info.pointee.st_mode)
    lua_pushstring(L, perms)
    perms.deallocate()
}

// MARK: - Stat member table

private typealias PushFunction = (UnsafeMutablePointer<lua_State>?, UnsafePointer<stat>) -> Void

private struct StatMember {
    let name: String
    let push: PushFunction
}

private let members: [StatMember] = [
    StatMember(name: "mode",         push: push_st_mode),
    StatMember(name: "dev",          push: push_st_dev),
    StatMember(name: "ino",          push: push_st_ino),
    StatMember(name: "nlink",        push: push_st_nlink),
    StatMember(name: "uid",          push: push_st_uid),
    StatMember(name: "gid",          push: push_st_gid),
    StatMember(name: "rdev",         push: push_st_rdev),
    StatMember(name: "access",       push: push_st_atime),
    StatMember(name: "modification", push: push_st_mtime),
    StatMember(name: "change",       push: push_st_ctime),
    StatMember(name: "creation",     push: push_st_birthtime),
    StatMember(name: "size",         push: push_st_size),
    StatMember(name: "permissions",  push: push_st_perm),
    StatMember(name: "blocks",       push: push_st_blocks),
    StatMember(name: "blksize",      push: push_st_blksize),
]

// MARK: - File info (attributes / symlinkAttributes)

/// hs.fs.attributes(filepath [, aName]) -> table or string or nil,error
/// Function
/// Gets the attributes of a file
///
/// Parameters:
///  * filepath - A string containing the path of a file to inspect
///  * aName - An optional attribute name. If this value is specified, only the attribute requested, is returned
///
/// Returns:
///  * A table with the file attributes corresponding to filepath (or nil followed by an error message in case of error). If the second optional argument is given, then a string is returned with the value of the named attribute. attribute mode is a string, all the others are numbers, and the time related attributes use the same time reference of os.time:
///   * dev - A number containing the device the file resides on
///   * ino - A number containing the inode of the file
///   * mode - A string containing the type of the file (possible values are: file, directory, link, socket, named pipe, char device, block device or other)
///   * nlink - A number containing a count of hard links to the file
///   * uid - A number containing the user-id of owner
///   * gid - A number containing the group-id of owner
///   * rdev - A number containing the type of device, for files that are char/block devices
///   * access - A number containing the time of last access modification (as seconds since the UNIX epoch)
///   * change - A number containing the time of last file status change (as seconds since the UNIX epoch)
///   * modification - A number containing the time of the last file contents change (as seconds since the UNIX epoch)
///   * permissions - A 9 character string specifying the user access permissions for the file. The first three characters represent Read/Write/Execute permissions for the file owner. The first character will be "r" if the user has read permissions, "-" if they do not; the second will be "w" if they have write permissions, "-" if they do not; the third will be "x" if they have execute permissions, "-" if they do not. The second group of three characters follow the same convention, but refer to whether or not the file's group have Read/Write/Execute permissions, and the final three characters follow the same convention, but apply to other system users not covered by the Owner or Group fields.
///   * creation - A number containing the time the file was created (as seconds since the UNIX epoch)
///   * size - A number containing the file size, in bytes
///   * blocks - A number containing the number of blocks allocated for file
///   * blksize - A number containing the optimal file system I/O blocksize
///
/// Notes:
///  * This function uses `stat()` internally thus if the given filepath is a symbolic link, it is followed (if it points to another link the chain is followed recursively) and the information is about the file it refers to. To obtain information about the link itself, see function `hs.fs.symlinkAttributes()`
private func _file_info_(_ L: UnsafeMutablePointer<lua_State>!, _ st: @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<stat>?) -> Int32) -> Int32 {
    LuaSkin.skin(with: L).checkArgs(LS_TSTRING, LS_TSTRING | LS_TOPTIONAL, LS_TBREAK)
    let file = path_at_index(L, 1)
    var info = stat()

    if st(file, &info) != 0 {
        lua_pushnil(L)
        let fileStr = String(cString: file!)
        let errStr = String(cString: strerror(errno)!)
        lua_pushstring(L, "cannot obtain information from file '\(fileStr)': \(errStr)")
        return 2
    }
    if lua_isstring(L, 2) {
        let member = String(cString: lua_tostring(L, 2)!)
        for m in members {
            if m.name == member {
                m.push(L, &info)
                return 1
            }
        }
        // member not found
        lua_pushnil(L)
        let attrName = String(cString: lua_tostring(L, 2)!)
        lua_pushstring(L, "invalid attribute name '\(attrName)'")
        return 2
    }
    // creates a table if none is given
    lua_settop(L, 2)
    if !lua_istable(L, 2) {
        lua_newtable(L)
    }
    // stores all members in table on top of the stack
    for m in members {
        lua_pushstring(L, m.name)
        m.push(L, &info)
        lua_rawset(L, -3)
    }
    return 1
}

private func _call_stat(_ path: UnsafePointer<CChar>?, _ buf: UnsafeMutablePointer<stat>?) -> Int32 {
    stat(path!, buf!)
}
private func _call_lstat(_ path: UnsafePointer<CChar>?, _ buf: UnsafeMutablePointer<stat>?) -> Int32 {
    lstat(path!, buf!)
}

private func file_info(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return _file_info_(L, _call_stat)
}

private func link_info(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    return _file_info_(L, _call_lstat)
}

// MARK: - Tags

/// hs.fs.tagsGet(filepath) -> table or nil
/// Function
/// Gets the Finder tags of a file
///
/// Parameters:
///  * filepath - A string containing the path of a file
///
/// Returns:
///  * A table containing the list of the file's tags, or nil if the file has no tags assigned; throws a lua error if an error accessing the file occurs
private func tagsGet(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let path = skin.toNSObject(atIndex: 1) as! NSString

    guard let tags = tags_from_file(L, path) else {
        lua_pushnil(L)
        return 1
    }

    lua_newtable(L)
    var i: lua_Integer = 1
    for tag in tags {
        lua_pushinteger(L, i)
        i += 1
        lua_pushstring(L, (tag as! NSString).utf8String)
        lua_settable(L, -3)
    }

    return 1
}

/// hs.fs.tagsAdd(filepath, tags)
/// Function
/// Adds one or more tags to the Finder tags of a file
///
/// Parameters:
///  * filepath - A string containing the path of a file
///  * tags - A table containing one or more strings, each containing a tag name
///
/// Returns:
///  * true if the tags were updated; throws a lua error if an error occurs updating the tags
private func tagsAdd(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBREAK)
    let path = skin.toNSObject(atIndex: 1) as! NSString

    let oldTags = NSMutableSet(array: tags_from_file(L, path) as! [Any])
    let newTags = NSMutableSet(array: tags_from_lua_stack(L) as [AnyObject])
    newTags.union(oldTags as Set)
    lua_pushboolean(L, tags_to_file(L, path, newTags.allObjects as NSArray) ? 1 : 0)

    return 1
}

/// hs.fs.tagsSet(filepath, tags)
/// Function
/// Sets the Finder tags of a file, removing any that are already set
///
/// Parameters:
///  * filepath - A string containing the path of a file
///  * tags - A table containing zero or more strings, each containing a tag name
///
/// Returns:
///  * true if the tags were set; throws a lua error if an error occurs setting the new tags
private func tagsSet(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBREAK)
    let path = skin.toNSObject(atIndex: 1) as! NSString

    let tags = tags_from_lua_stack(L)
    lua_pushboolean(L, tags_to_file(L, path, tags) ? 1 : 0)

    return 1
}

/// hs.fs.tagsRemove(filepath, tags)
/// Function
/// Removes Finder tags from a file
///
/// Parameters:
///  * filepath - A string containing the path of a file
///  * tags - A table containing one or more strings, each containing a tag name
///
/// Returns:
///  * true if the tags were updated; throws a lua error if an error occurs updating the tags
private func tagsRemove(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TTABLE, LS_TBREAK)
    let path = skin.toNSObject(atIndex: 1) as! NSString
    let removeTags = NSMutableSet(array: tags_from_lua_stack(L) as [AnyObject])

    let tags = NSMutableSet(array: tags_from_file(L, path) as! [Any])
    tags.minus(removeTags as Set)
    lua_pushboolean(L, tags_to_file(L, path, tags.allObjects as NSArray) ? 1 : 0)

    return 1
}

// MARK: - Misc functions

/// hs.fs.temporaryDirectory() -> string
/// Function
/// Returns the path of the temporary directory for the current user.
///
/// Parameters:
///  * None
///
/// Returns:
///  * The path to the system designated temporary directory for the current user.
private func hs_temporaryDirectory(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    lua_pushstring(L, NSTemporaryDirectory().cString(using: .utf8))
    return 1
}

/// hs.fs.fileUTI(path) -> string or nil
/// Function
/// Returns the Uniform Type Identifier for the file location specified.
///
/// Parameters:
///  * path - the path to the file to return the UTI for.
///
/// Returns:
///  * a string containing the Uniform Type Identifier for the file location specified or nil if an error occurred
private func hs_fileuti(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let path = NSString(utf8String: path_at_index(L, 1)!)! as String

    var error: NSError?
    var type: String?
    do {
        type = try NSWorkspace.shared.type(ofFile: path)
    } catch let err as NSError {
        error = err
    }
    if let error = error {
        lua_pushnil(L)
        skin.logError(error.localizedDescription)
    }
    skin.pushNSObject(type as NSString?)
    return 1
}

/// hs.fs.fileUTIalternate(fileUTI, type) -> string
/// Function
/// Returns the fileUTI's equivalent form in an alternate type specification format.
///
/// Parameters:
///  * a string containing a file UTI, such as one returned by `hs.fs.fileUTI`.
///  * a string specifying the alternate format for the UTI.  This string may be one of the following:
///     * `extension`  - as a file extension, commonly used for platform independent file sharing when file metadata can't be guaranteed to be cross-platform compatible.  Generally considered unreliable when other file type identification methods are available.
///    * `mime`       - as a mime-type, commonly used by Internet applications like web browsers and email applications.
///    * `pasteboard` - as an NSPasteboard type (see `hs.pasteboard`).
///    * `ostype`     - four character file type, most common pre OS X, but still used in some legacy APIs.
///
/// Returns:
///  * the file UTI in the alternate format or nil if the UTI does not have an alternate of the specified type.
private func hs_fileUTIalternate(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TBREAK)
    let fileUTI = skin.toNSObject(atIndex: 1) as! NSString
    let format = skin.toNSObject(atIndex: 2) as! NSString

    let convertTo: CFString
    if format.isEqual(to: "extension") {
        convertTo = kUTTagClassFilenameExtension
    } else if format.isEqual(to: "mime") {
        convertTo = kUTTagClassMIMEType
    } else if format.isEqual(to: "pasteboard") {
        convertTo = kUTTagClassNSPboardType
    } else if format.isEqual(to: "ostype") {
        convertTo = kUTTagClassOSType
    } else {
        return luaL_error(L, "invalid alternate type \(format) specified")
    }

    let result = UTTypeCopyPreferredTagWithClass(fileUTI as CFString, convertTo)?.takeRetainedValue()
    skin.pushNSObject(result as NSString?)
    return 1
}

/// hs.fs.pathToAbsolute(filepath) -> string
/// Function
/// Gets the absolute path of a given path
///
/// Parameters:
///  * filepath - Any kind of file or directory path, be it relative or not
///
/// Returns:
///  * A string containing the absolute path of `filepath` (i.e. one that doesn't include `.`, `..` or symlinks)
///  * Note that symlinks will be resolved to their target file
private func hs_pathToAbsolute(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let filePath = skin.toNSObject(atIndex: 1) as! NSString
    let absolutePath = realpath((filePath as String).expandingTildeInPath, nil)

    guard let absolutePath = absolutePath else {
        lua_pushnil(L)
        return 1
    }

    lua_pushstring(L, absolutePath)
    free(absolutePath)
    return 1
}

/// hs.fs.displayName(filepath) -> string
/// Function
/// Returns the display name of the file or directory at a specified path.
///
/// Parameters:
///  * filepath - The path to the file or directory
///
/// Returns:
///  * a string containing the display name of the file or directory at a specified path; returns nil if no file with the specified path exists.
private func fs_displayName(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)
    let filePath = skin.toNSObject(atIndex: 1) as! NSString
    if FileManager.default.fileExists(atPath: filePath.expandingTildeInPath) {
        skin.pushNSObject(FileManager.default.displayName(atPath: filePath.expandingTildeInPath) as NSString)
    } else {
        lua_pushnil(L)
    }
    return 1
}

/// hs.fs.pathToBookmark(path) -> string | nil
/// Function
/// Returns the path as binary encoded bookmark data.
///
/// Parameters:
///  * path - The path to encode
///
/// Returns:
///  * Bookmark data in a binary encoded string or `nil` if path is invalid.
private func fs_pathToBookmark(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let filePath = skin.toNSObject(atIndex: 1) as! NSString
    let absolutePath = realpath((filePath as String).expandingTildeInPath, nil)

    guard absolutePath != nil else {
        lua_pushnil(L)
        return 1
    }

    let bookmarkData = try? (NSURL(fileURLWithPath: filePath as String) as URL)
        .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    skin.pushNSObject(bookmarkData as NSData?)
    free(absolutePath)
    return 1
}

/// hs.fs.pathFromBookmark(data) -> string | nil, string
/// Function
/// Gets the file path from a binary encoded bookmark.
///
/// Parameters:
///  * data - The binary encoded Bookmark.
///
/// Returns:
///  * A string containing the path to the Bookmark URL or `nil` if an error occurs.
///  * An error message if an error occurs.
///
/// Notes:
///  * A bookmark provides a persistent reference to a file-system resource.
///    When you resolve a bookmark, you obtain a URL to the resource's current location.
///    A bookmark's association with a file-system resource (typically a file or folder)
///    usually continues to work if the user moves or renames the resource, or if the
///    user relaunches your app or restarts the system.
///  * No volumes are mounted during the resolution of the bookmark data.
private func fs_pathFromBookmark(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let data = lua_tostring(L, 1)
    let dataLength: Int = lua_rawlen(L, 1)
    let bookmarkData = NSData(bytes: data, length: dataLength)

    do {
        var isStale: Bool = false
        let url = try URL(resolvingBookmarkData: bookmarkData as Data,
                          options: .withoutMounting,
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)

        let NSURLPathKey = "_NSURLPathKey"
        let values = NSURL.resourceValues(forKeys: [URLResourceKey(rawValue: NSURLPathKey)],
                                          fromBookmarkData: bookmarkData as Data)
        if let path = values?[URLResourceKey(rawValue: NSURLPathKey)] as? NSString {
            skin.pushNSObject(path)
            return 1
        }
        // URL resolved but no path key found
        _ = url // suppress unused warning
        lua_pushnil(L)
        return 1
    } catch {
        let errorMessage = "Error resolving URL from bookmark: \(error)" as NSString
        lua_pushnil(L)
        skin.pushNSObject(errorMessage)
        return 2
    }
}

/// hs.fs.urlFromPath(path) -> string | nil
/// Function
/// Returns the encoded URL from a path.
///
/// Parameters:
///  * path - The path
///
/// Returns:
///  * A string or `nil` if path is invalid.
private func fs_urlFromPath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let filePath = skin.toNSObject(atIndex: 1) as! NSString
    let absolutePath = realpath((filePath as String).expandingTildeInPath, nil)

    guard absolutePath != nil else {
        lua_pushnil(L)
        return 1
    }

    let urlPath = ((filePath as String).standardizingPath as NSString).resolvingSymlinksInPath
    let fileURL = NSURL(fileURLWithPath: urlPath)

    skin.pushNSObject(fileURL.absoluteString as NSString?)
    free(absolutePath)
    return 1
}

/// hs.fs.fileListForPath(path, [options]) -> table, fileCount, dirCount
/// Function
/// Returns a table containing the paths to all of the files located at the specified path.
///
/// Parameters:
///  * `path`    - a string specifying the path to gather the files from. If this path specifies a file, then the return value is a table containing only this path. If the path specifies a directory, then the table contains the paths of all of the files found in the specified directory.
///  * `options` - an optional table with one or more key-value pairs determining how and what files are to be included in the table returned.
///    * The following keys are recognized:
///      * `subdirs`        - a boolean, default false, indicating whether or not subdirectories should be descended into and examined for files as well.
///      * `followSymlinks` - a boolean, default false, indicating whether or not symbolic links should be followed
///      * `expandSymlinks` - a boolean, default false, specifying whether or not the real path of any files discovered after following a symbolic link should be included in the list (true) or whether the path added to the list should remain relative to the starting path (false).
///      * `relativePath`   - a boolean, default false, specifying whether paths included in the result list should be relative to the starting path (true) or the full and complete path to the file (false).
///      * `ignore`         - a table of strings, specifying regular expression matches for files to exclude from the result list. If not provided, this value will be inherited from the module's variable [hs.fs.defaultPathListExcludes](#defaultPathListExcludes) which, by defualt, is set to ignore all files beginning with a period (often called dot-files). To include all files, set this option equal to the empty table (i.e. `{}`).
///      * `except`         - a table of strings, default empty, specifying regular expression matches for files that match an `ignore` rule, but should be included anyways. For example, if this option is set to `{ "^\\.gitignore$" }`, then a file named `.gitignore` would be included, even though it would normally be excluded by the default `ignore` ruleset.
///
/// Returns:
///  * a table containing the paths to the files discovered at the specified path. the number of files found, and the number of directories examined. Only files will be included in the results table-- directory names are not included in the resulting list. The table will be sorted as per the Objective-C NSString's `compare:` method.
///
/// Notes:
///  * `ignore` and `except` options require the use of actual regular expressions, not the simplified pattern matching used by Lua. More details about the proper syntax for the strings to use in the tables of these options can be found at https://unicode-org.github.io/icu/userguide/strings/regexp.html.
///    * note that this function only checks to see if the regular expression returns a match for each filename found (not the path, just the filename component of the path). Any captures are ignored.
private func fs_filesInPath(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING,
                   LS_TTABLE | LS_TOPTIONAL,
                   LS_TBREAK)

    var path = skin.toNSObject(atIndex: 1) as! NSString

    var subdirs = false
    var followSymlinks = false
    var expandSymlinks = false
    var relativePath = false
    var ignore: NSArray? = nil
    var except: NSArray? = nil

    if lua_type(L, 2) == LUA_TTABLE {
        lua_pushnil(L)
        while lua_next(L, 2) != 0 {
            if lua_type(L, -2) == LUA_TSTRING {
                let keyName = String(cString: lua_tostring(L, -2)!)
                switch keyName {
                case "subdirs":
                    guard lua_type(L, -1) == LUA_TBOOLEAN else {
                        return luaL_argerror(L, 2, "subdirs option expects boolean value")
                    }
                    subdirs = lua_toboolean(L, -1) != 0
                case "followSymlinks":
                    guard lua_type(L, -1) == LUA_TBOOLEAN else {
                        return luaL_argerror(L, 2, "followSymlinks option expects boolean value")
                    }
                    followSymlinks = lua_toboolean(L, -1) != 0
                case "expandSymlinks":
                    guard lua_type(L, -1) == LUA_TBOOLEAN else {
                        return luaL_argerror(L, 2, "expandSymlinks option expects boolean value")
                    }
                    expandSymlinks = lua_toboolean(L, -1) != 0
                case "relativePath":
                    guard lua_type(L, -1) == LUA_TBOOLEAN else {
                        return luaL_argerror(L, 2, "relativePath option expects boolean value")
                    }
                    relativePath = lua_toboolean(L, -1) != 0
                case "ignore":
                    ignore = skin.toNSObject(atIndex: -1) as? NSArray
                    if let arr = ignore {
                        for entry in arr {
                            guard entry is NSString else {
                                return luaL_argerror(L, 2, "ignore option table entries must be strings")
                            }
                        }
                    } else {
                        return luaL_argerror(L, 2, "ignore option expects table value")
                    }
                case "except":
                    except = skin.toNSObject(atIndex: -1) as? NSArray
                    if let arr = except {
                        for entry in arr {
                            guard entry is NSString else {
                                return luaL_argerror(L, 2, "except option table entries must be strings")
                            }
                        }
                    } else {
                        return luaL_argerror(L, 2, "except option expects table value")
                    }
                default:
                    return luaL_argerror(L, 2, "option \(keyName) not recognized")
                }
            } else {
                return luaL_argerror(L, 2, "option table keys must be strings")
            }
            lua_pop(L, 1)
        }
    }

    if except == nil { except = NSArray() }

    if ignore == nil {
        skin.requireModule("\(USERDATA_TAG)")
        lua_getfield(L, -1, "defaultPathListExcludes")
        ignore = skin.toNSObject(atIndex: -1) as? NSArray
        lua_pop(L, 2)
    }

    var excluders = [NSRegularExpression]()
    var exceptions = [NSRegularExpression]()

    for i in 0..<(ignore?.count ?? 0) {
        do {
            let p = try NSRegularExpression(pattern: ignore![i] as! String,
                                            options: .useUnicodeWordBoundaries)
            excluders.append(p)
        } catch {
            return luaL_argerror(L, 2, "invalid regex (\(error.localizedDescription)) at index \(i + 1) of ignore option")
        }
    }
    for i in 0..<(except?.count ?? 0) {
        do {
            let p = try NSRegularExpression(pattern: except![i] as! String,
                                            options: .useUnicodeWordBoundaries)
            exceptions.append(p)
        } catch {
            return luaL_argerror(L, 2, "invalid regex (\(error.localizedDescription)) at index \(i + 1) of except option")
        }
    }

    path = (path.expandingTildeInPath as NSString).resolvingSymlinksInPath as NSString
    var dirCount: lua_Integer = 0

    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    let fileExists = fileManager.fileExists(atPath: path as String, isDirectory: &isDirectory)

    if !fileExists {
        return luaL_argerror(L, 1, "path does not specify a reachable file or directory")
    } else if !isDirectory.boolValue {
        skin.pushNSObject(NSArray(array: [path]))
        lua_pushinteger(L, 1)
        lua_pushinteger(L, 0)
        return 3
    }

    let startingURL = URL(fileURLWithPath: path as String, isDirectory: true)
    let startingPathStr = (try? startingURL.resourceValues(forKeys: [.pathKey]))?.allValues[.pathKey] as? NSString ?? path

    let foundPaths = NSMutableArray()
    let seenDirectories = NSMutableArray()
    let directories = NSMutableArray(array: [NSArray(array: [startingPathStr, startingPathStr])])

    while directories.count > 0 {
        let currentPathArray = directories[0] as! NSArray
        directories.removeObject(at: 0)
        dirCount += 1

        let thisDir = currentPathArray[0] as! NSString
        let symbolicDir = currentPathArray[1] as! NSString

        seenDirectories.add(thisDir)

        let thisDirURL = NSURL(fileURLWithPath: thisDir as String, isDirectory: true) as URL
        guard let dirEnum = fileManager.enumerator(
            at: thisDirURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .pathKey],
            options: .skipsSubdirectoryDescendants,
            errorHandler: nil
        ) else { continue }

        for case var fileURL as URL in dirEnum {
            guard let vals = try? fileURL.resourceValues(forKeys: [.pathKey, .isSymbolicLinkKey]) else { continue }
            var filePathStr = (vals.allValues[.pathKey] as? NSString) ?? (fileURL.path as NSString)

            let originalFilePath = filePathStr.copy() as! NSString
            let fileName = originalFilePath.lastPathComponent as NSString

            if vals.isSymbolicLink == true {
                if followSymlinks {
                    let newPath = (filePathStr as String).resolvingSymlinksInPath
                    if fileManager.fileExists(atPath: newPath) {
                        fileURL = URL(fileURLWithPath: newPath)
                        if let resolvedVals = try? fileURL.resourceValues(forKeys: [.pathKey]) {
                            filePathStr = (resolvedVals.allValues[.pathKey] as? NSString) ?? (fileURL.path as NSString)
                        }
                    } else {
                        LuaSkin.skin(with: L).logWarn("\(USERDATA_TAG).pathList - error resolving symbolic link \(newPath)")
                        continue
                    }
                } else {
                    continue
                }
            }

            var keepGoing = true

            for test in excluders {
                let matches = test.numberOfMatches(in: fileName as String, options: [],
                                                   range: NSRange(location: 0, length: fileName.length))
                if matches > 0 {
                    keepGoing = false
                    break
                }
            }

            for test in exceptions {
                let matches = test.numberOfMatches(in: fileName as String, options: [],
                                                   range: NSRange(location: 0, length: fileName.length))
                if matches > 0 {
                    keepGoing = true
                    break
                }
            }

            if !keepGoing { continue }

            let fileVals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if fileVals?.isRegularFile == true {
                var resultPath = filePathStr
                if !expandSymlinks {
                    resultPath = originalFilePath.replacingOccurrences(
                        of: thisDir as String,
                        with: symbolicDir as String,
                        options: [.anchored, .literal],
                        range: NSRange(location: 0, length: originalFilePath.length)
                    ) as NSString
                }
                if relativePath && resultPath.hasPrefix(startingPathStr as String) {
                    foundPaths.add(resultPath.substring(from: startingPathStr.length + 1))
                } else {
                    foundPaths.add(resultPath)
                }
            } else if subdirs {
                if fileVals?.isDirectory == true && !seenDirectories.contains(filePathStr) {
                    directories.add(NSArray(array: [filePathStr, "\(symbolicDir)/\(fileName)"]))
                }
            }
        }
    }

    // ensure consistent order
    foundPaths.sort(using: [NSSortDescriptor(key: "self", ascending: true, selector: #selector(NSString.compare(_:)))])

    skin.pushNSObject(foundPaths)
    lua_pushinteger(L, lua_Integer(foundPaths.count))
    lua_pushinteger(L, dirCount)
    return 3
}

// MARK: - Module registration

private let fslib: [luaL_Reg] = [
    luaL_Reg(name: strdup("attributes"),        func: file_info),
    luaL_Reg(name: strdup("chdir"),             func: change_dir),
    luaL_Reg(name: strdup("currentDir"),        func: get_dir),
    luaL_Reg(name: strdup("dir"),               func: dir_iter_factory),
    luaL_Reg(name: strdup("link"),              func: make_link),
    luaL_Reg(name: strdup("lock"),              func: file_lock),
    luaL_Reg(name: strdup("mkdir"),             func: make_dir),
    luaL_Reg(name: strdup("rmdir"),             func: remove_dir),
    luaL_Reg(name: strdup("symlinkAttributes"), func: link_info),
    luaL_Reg(name: strdup("touch"),             func: file_utime),
    luaL_Reg(name: strdup("unlock"),            func: file_unlock),
    luaL_Reg(name: strdup("lockDir"),           func: lfs_lock_dir),
    luaL_Reg(name: strdup("tagsAdd"),           func: tagsAdd),
    luaL_Reg(name: strdup("tagsRemove"),        func: tagsRemove),
    luaL_Reg(name: strdup("tagsSet"),           func: tagsSet),
    luaL_Reg(name: strdup("tagsGet"),           func: tagsGet),
    luaL_Reg(name: strdup("temporaryDirectory"), func: hs_temporaryDirectory),
    luaL_Reg(name: strdup("fileUTI"),           func: hs_fileuti),
    luaL_Reg(name: strdup("fileUTIalternate"),  func: hs_fileUTIalternate),
    luaL_Reg(name: strdup("pathToAbsolute"),    func: hs_pathToAbsolute),
    luaL_Reg(name: strdup("displayName"),       func: fs_displayName),
    luaL_Reg(name: strdup("pathToBookmark"),    func: fs_pathToBookmark),
    luaL_Reg(name: strdup("pathFromBookmark"),  func: fs_pathFromBookmark),
    luaL_Reg(name: strdup("urlFromPath"),       func: fs_urlFromPath),
    luaL_Reg(name: strdup("fileListForPath"),   func: fs_filesInPath),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libfs")
public func luaopen_hs_libfs(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    dir_create_meta(L)
    lock_create_meta(L)
    luaL_newlib_compat(L, fslib)
    lua_pushvalue(L, -1)
    return 1
}

// MARK: - Compat helper

// luaL_newlib is a macro in C; we replicate it in Swift
private func luaL_newlib_compat(_ L: UnsafeMutablePointer<lua_State>!, _ lib: [luaL_Reg]) {
    var mutableLib = lib
    luaL_checkversion(L)
    lua_createtable(L, 0, Int32(lib.count - 1))
    luaL_setfuncs(L, &mutableLib, 0)
}

// MARK: - String.expandingTildeInPath helper

private extension String {
    var expandingTildeInPath: String {
        return (self as NSString).expandingTildeInPath
    }
    var standardizingPath: String {
        return (self as NSString).standardizingPath
    }
    var resolvingSymlinksInPath: String {
        return (self as NSString).resolvingSymlinksInPath
    }
}
