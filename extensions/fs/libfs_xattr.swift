import Cocoa
import LuaSkin
import Darwin.POSIX.sys.xattr

/// === hs.fs.xattr ===
///
/// Get and manipulate extended attributes for files and directories
///
/// This submodule provides functions for getting and setting the extended attributes for files and directories.  Access to extended attributes is provided through the Darwin xattr functions defined in the /usr/include/sys/xattr.h header. Attribute names are expected to conform to proper UTF-8 strings and values are represented as raw data -- in Lua raw data is presented as bytes in a string object but the bytes are not required to conform to proper UTF-8 byte code sequences. This module does not perform any encoding or decoding of the raw data.
///
/// All of the functions provided by this module can take an options table. Note that not all options are valid for all functions. The options table should be a Lua table containing an array of zero or more of the following strings:
///
///  * "noFollow"       - do not follow symbolic links; this can be used to access the attributes of the link itself.
///  * "hfsCompression" - access HFS Plus Compression extended attributes for the file or directory, if present
///  * "createOnly"     - when setting an attribute value, fail if the attribute already exists
///  * "replaceOnly"    - when setting an attribute value, fail if the attribute does not already exist
///
/// Note that the following options did not seem to be valid for the initial tests performed when developing this module and may refer the kernel level features not available to Cosmic Hammer; they are included here for full compatibility with the library as defined in its header. If you have more information about these options or can provide examples or documentation about their use, please submit an issue to the Cosmic Hammer github repository so we can provide better documentation here.
///
///  * "noSecurity"      - bypass authorization checking
///  * "noDefault"       - bypass the default extended attribute file (dot-underscore file)

// MARK: - Constants

// private let USERDATA_TAG = "hs.fs.xattr"
private var refTable: LSRefTable = LUA_NOREF

// MARK: - Support Functions

private func parseOptionsTable(_ L: UnsafeMutablePointer<lua_State>!, _ idx: Int32) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    let optionList: NSArray
    if lua_type(L, idx) == LUA_TTABLE {
        optionList = skin.toNSObject(atIndex: idx) as? NSArray ?? NSArray()
    } else {
        optionList = NSArray()
    }

    if !(optionList is NSArray) {
        return luaL_argerror(L, idx, "expected an array of strings")
    }

    var errMsg: String? = nil
    var options: Int32 = 0

    for (i, obj) in optionList.enumerated() {
        guard let opt = obj as? String else {
            errMsg = "expected string at index \(i + 1)"
            break
        }
        switch opt {
        case "noFollow":        options |= XATTR_NOFOLLOW
        case "hfsCompression":  options |= XATTR_SHOWCOMPRESSION
        case "createOnly":      options |= XATTR_CREATE
        case "replaceOnly":     options |= XATTR_REPLACE
        case "noSecurity":      options |= XATTR_NOSECURITY
        case "noDefault":       options |= XATTR_NODEFAULT
        default:
            errMsg = "unrecognized option \(opt) at index \(i + 1)"
            break
        }
        if errMsg != nil { break }
    }
    if let errMsg = errMsg {
        return luaL_argerror(L, idx, errMsg)
    }
    return options
}

private func expandErrno(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let msg: String
    switch errno {
    case ENOTSUP:      msg = "filesystem does not support extended attributes"
    case ERANGE:       msg = "data size out of range"
    case EPERM:        msg = "named attribute is not permitted for this type of file or file does not support extended attributes"
    case EISDIR:       msg = "named attribute only valid for regular file"
    case ENOTDIR:      msg = "a path component is not a directory"
    case ENAMETOOLONG: msg = "path, name, or a path component too long"
    case EACCES:       msg = "permission denied"
    case ELOOP:        msg = "too many symbolic links or links loop"
    case EFAULT:       msg = "path points to an invalid address"
    case EIO:          msg = "io error"
    case EINVAL:       msg = "name is invalid or invalid option set"
    case ENOENT:       msg = "file not found"
    case ENOATTR:      msg = "extended attribute does not exist"
    case EEXIST:       msg = "extended attribute already exists"
    case EROFS:        msg = "file system mounted read-only"
    case E2BIG:        msg = "data size of extended attribute is too large"
    default:           msg = "unrecognized errno code \(errno); see /usr/include/sys/errno.h"
    }
    return luaL_error(L, msg)
}

// MARK: - Module Functions

/// hs.fs.xattr.set(path, attribute, value, [options], [position]) -> boolean
/// Function
/// Set the extended attribute to the value provided for the path specified.
///
/// Parameters:
///  * `path`      - A string specifying the path to the file or directory to set the extended attribute for
///  * `attribute` - A string specifying the name of the extended attribute to set
///  * `value`     - A string containing the value to set the extended attribute to. This value is treated as a raw sequence of bytes and does not have to conform to property UTF-8 byte sequences.
///  * `options`   - An optional table containing options as described in this module's documentation header. Defaults to {} (an empty array).
///  * `position`  - An optional integer specifying the offset within the extended attribute. Defaults to 0. Setting this argument to a value other than 0 is only valid when `attribute` is "com.apple.ResourceFork".
///
/// Returns:
///  * True if the operation succeeds; otherwise throws a Lua error with a description of reason for failure.
private func xattr_setxattr(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TSTRING, LS_TTABLE | LS_TOPTIONAL, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)

    var path = skin.toNSObject(atIndex: 1) as! NSString
    path = path.expandingTildeInPath as NSString

    let attribute = skin.toNSObject(atIndex: 2) as! NSString

    let value = skin.toNSObject(atIndex: 3, withOptions: .nsLuaStringAsDataOnly) as! NSData

    let options = parseOptionsTable(L, 4)

    let position: UInt32 = (lua_gettop(L) == 5) ? UInt32(lua_tointeger(L, 5)) : 0
    if position != 0 && !(attribute as String == XATTR_RESOURCEFORK_NAME) {
        return luaL_argerror(L, 5, "position argument only valid with \(XATTR_RESOURCEFORK_NAME) attribute")
    }

    if setxattr(path.utf8String, attribute.utf8String, value.bytes, value.length, position, Int32(options)) < 0 {
        return expandErrno(L)
    } else {
        lua_pushboolean(L, 1)
    }
    return 1
}

/// hs.fs.xattr.remove(path, attribute, [options]) -> boolean
/// Function
/// Removes the specified extended attribute from the file or directory at the path specified.
///
/// Parameters:
///  * `path`      - A string specifying the path to the file or directory to remove the extended attribute from
///  * `attribute` - A string specifying the name of the extended attribute to remove
///  * `options`   - An optional table containing options as described in this module's documentation header. Defaults to {} (an empty array).
///
/// Returns:
///  * True if the operation succeeds; otherwise throws a Lua error with a description of reason for failure.
private func xattr_removexattr(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)

    var path = skin.toNSObject(atIndex: 1) as! NSString
    path = path.expandingTildeInPath as NSString

    let attribute = skin.toNSObject(atIndex: 2) as! NSString

    let options = parseOptionsTable(L, 3)

    if removexattr(path.utf8String, attribute.utf8String, Int32(options)) < 0 {
        return expandErrno(L)
    } else {
        lua_pushboolean(L, 1)
    }
    return 1
}

/// hs.fs.xattr.get(path, attribute, [options], [position]) -> string | true | nil
/// Function
/// Set the extended attribute to the value provided for the path specified.
///
/// Parameters:
///  * `path`      - A string specifying the path to the file or directory to get the extended attribute from
///  * `attribute` - A string specifying the name of the extended attribute to get the value of
///  * `options`   - An optional table containing options as described in this module's documentation header. Defaults to {} (an empty array).
///  * `position`  - An optional integer specifying the offset within the extended attribute. Defaults to 0. Setting this argument to a value other than 0 is only valid when `attribute` is "com.apple.ResourceFork".
///
/// Returns:
///  * If the attribute exists for the file or directory and contains data, returns the value of the attribute as a string of raw bytes which are not guaranteed to conform to proper UTF-8 byte sequences. If the attribute exist but does not have a value, returns the Lua boolean `true`.  If the attribute does not exist, returns nil. Throws a Lua error on failure with a description of the reason for the failure.
///
/// Notes:
///  * See also [hs.fs.xattr.getHumanReadable](#getHumanReadable).
private func xattr_getxattr(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TSTRING, LS_TTABLE | LS_TOPTIONAL, LS_TNUMBER | LS_TINTEGER | LS_TOPTIONAL, LS_TBREAK)

    var path = skin.toNSObject(atIndex: 1) as! NSString
    path = path.expandingTildeInPath as NSString

    let attribute = skin.toNSObject(atIndex: 2) as! NSString

    let options = parseOptionsTable(L, 3)

    let position: UInt32 = (lua_gettop(L) == 4) ? UInt32(lua_tointeger(L, 4)) : 0
    if position != 0 && !(attribute as String == XATTR_RESOURCEFORK_NAME) {
        return luaL_argerror(L, 4, "position argument only valid with \(XATTR_RESOURCEFORK_NAME) attribute")
    }

    var bufferSize = getxattr(path.utf8String, attribute.utf8String, nil, 0, position, Int32(options))
    if bufferSize > 0 {
        let buffer = malloc(bufferSize)!
        bufferSize = getxattr(path.utf8String, attribute.utf8String, buffer, bufferSize, position, Int32(options))
        if bufferSize > 0 {
            skin.pushNSObject(NSData(bytes: buffer, length: bufferSize))
        }
        free(buffer)
    } else if bufferSize == 0 {
        lua_pushboolean(L, 1)
    }
    if bufferSize < 0 {
        if errno == ENOATTR {
            lua_pushnil(L)
        } else {
            return expandErrno(L)
        }
    }
    return 1
}

/// hs.fs.xattr.list(path, [options]) -> table
/// Function
/// Returns a list of the extended attributes currently defined for the specified file or directory
///
/// Parameters:
///  * `path`      - A string specifying the path to the file or directory to get the list of extended attributes for
///  * `options`   - An optional table containing options as described in this module's documentation header. Defaults to {} (an empty array).
///
/// Returns:
///  * a table containing an array of strings identifying the extended attributes currently defined for the file or directory; note that the order of the attributes is nondeterministic and is not guaranteed to be the same for future queries.  Throws a Lua error on failure with a description of the reason for the failure.
private func xattr_listxattr(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    skin.checkArgs(LS_TSTRING, LS_TTABLE | LS_TOPTIONAL, LS_TBREAK)

    var path = skin.toNSObject(atIndex: 1) as! NSString
    path = path.expandingTildeInPath as NSString

    let options = parseOptionsTable(L, 2)

    lua_newtable(L)
    var bufferSize = listxattr(path.utf8String, nil, 0, Int32(options))
    if bufferSize > 0 {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        bufferSize = listxattr(path.utf8String, buffer, bufferSize, Int32(options))
        if bufferSize > 0 {
            var j = 0
            var p = buffer
            while j < bufferSize {
                lua_pushstring(L, p)
                let t = lua_rawlen(L, -1) + 1
                p += t
                j += t
                lua_rawseti(L, -2, luaL_len(L, -2) + 1)
            }
        }
        buffer.deallocate()
    }
    if bufferSize < 0 {
        lua_pop(L, 1)
        return expandErrno(L)
    }
    return 1
}

// MARK: - Lua registration

private let moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("list"),   func: xattr_listxattr),
    luaL_Reg(name: strdup("get"),    func: xattr_getxattr),
    luaL_Reg(name: strdup("set"),    func: xattr_setxattr),
    luaL_Reg(name: strdup("remove"), func: xattr_removexattr),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libfsxattr")
public func luaopen_hs_libfsxattr(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    let skin = LuaSkin.skin(with: L)
    refTable = skin.registerLibrary("hs.fs.xattr", functions: moduleLib, metaFunctions: nil)

    return 1
}
