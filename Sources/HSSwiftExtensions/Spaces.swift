import Cocoa
import CLua
import Lua
import os.log

// MARK: - SkyLight Private Framework Declarations

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32

@_silgen_name("CoreDockSendNotification")
func CoreDockSendNotification(_ notification: CFString, _ unknown: Int32) -> CGError

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

@_silgen_name("SLSSpaceGetType")
func SLSSpaceGetType(_ cid: Int32, _ sid: UInt64) -> Int32

@_silgen_name("SLSCopyWindowsWithOptionsAndTags")
func SLSCopyWindowsWithOptionsAndTags(_ cid: Int32, _ owner: UInt32, _ spaces: CFArray, _ options: UInt32, _ setTags: UnsafeMutablePointer<UInt64>, _ clearTags: UnsafeMutablePointer<UInt64>) -> CFArray?

@_silgen_name("SLSMoveWindowsToManagedSpace")
func SLSMoveWindowsToManagedSpace(_ cid: Int32, _ windowList: CFArray, _ sid: UInt64)

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ selector: Int32, _ windowList: CFArray) -> CFArray?

@_silgen_name("SLSSpaceSetCompatID")
func SLSSpaceSetCompatID(_ cid: Int32, _ sid: UInt64, _ workspace: Int32) -> CGError

@_silgen_name("SLSSetWindowListWorkspace")
func SLSSetWindowListWorkspace(_ cid: Int32, _ windowList: UnsafeMutablePointer<UInt32>, _ windowCount: Int32, _ workspace: Int32) -> CGError

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: Int32) -> UInt64

// MARK: - Module State

private let USERDATA_TAG = "hs.spaces"
private var regEx_UUID: NSRegularExpression?
private var g_connection: Int32 = 0

// MARK: - Support Functions

private func workspace_is_macos_sonoma14_5_or_newer() -> Bool {
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    if osVersion.majorVersion > 14 { return true }
    if osVersion.majorVersion == 14 && osVersion.minorVersion >= 5 { return true }
    return false
}

// MARK: - Module Functions

/// hs.spaces.screensHaveSeparateSpaces() -> bool
/// Function
/// Determine if the user has enabled the "Displays Have Separate Spaces" option within Mission Control.
///
/// Parameters:
///  * None
///
/// Returns:
///  * true or false representing the status of the "Displays Have Separate Spaces" option within Mission Control.
private func spaces_screensHaveSeparateSpaces(_ L: LuaState) throws -> CInt {
    L.push(NSScreen.screensHaveSeparateSpaces)
    return 1
}

/// hs.spaces.data_managedDisplaySpaces() -> table | nil, error
/// Function
/// Returns a table containing information about the managed display spaces
///
/// Parameters:
///  * None
///
/// Returns:
///  * a table containing information about all of the displays and spaces managed by the OS.
///
/// Notes:
///  * the format and detail of this table is too complex and varied to describe here; suffice it to say this is the workhorse for this module and a careful examination of this table may be informative, but is not required in the normal course of using this module.
private func spaces_managedDisplaySpaces(_ L: LuaState) throws -> CInt {
    if let managedDisplaySpaces = SLSCopyManagedDisplaySpaces(g_connection) {
        lua_pushany(L, managedDisplaySpaces as NSArray)
    } else {
        lua_pushnil(L)
        L.push("SLSCopyManagedDisplaySpaces returned NULL")
        return 2
    }
    return 1
}

/// hs.spaces.focusedSpace() -> integer
/// Function
/// Returns the space ID of the currently focused space
///
/// Parameters:
///  * None
///
/// Returns:
///  * the space ID for the currently focused space. The focused space is the currently active space on the currently active screen (i.e. that the user is working on)
///
/// Notes:
///  * *usually* the currently active screen will be returned by `hs.screen.mainScreen()`; however some full screen applications may have focus without updating which screen is considered "main". You can use this function, and look up the screen UUID with [hs.spaces.spaceDisplay](#spaceDisplay) to determine the "true" focused screen if required.
private func spaces_getActiveSpace(_ L: LuaState) throws -> CInt {
    L.push(lua_Integer(SLSGetActiveSpace(g_connection)))
    return 1
}

/// hs.spaces.windowsForSpace(spaceID) -> table | nil, error
/// Function
/// Returns a table containing the window IDs of *all* windows on the specified space
///
/// Parameters:
///  * `spaceID` - an integer specifying the ID of the space
///
/// Returns:
///  * a table containing the window IDs for *all* windows on the specified space
///
/// Notes:
///  * the table returned has its __tostring metamethod set to `hs.inspect` to simplify inspecting the results when using the Cosmic Hammer Console.
///  * The list of windows includes all items which are considered "windows" by macOS -- this includes visual elements usually considered unimportant like overlays, tooltips, graphics, off-screen windows, etc. so expect a lot of false positives in the results.
///  * In addition, due to the way Accessibility objects work, only those window IDs that are present on the currently visible spaces will be finable with `hs.window` or exist within `hs.window.allWindows()`.
///  * This function *will* prune Cosmic Hammer canvas elements from the list because we "own" these and can identify their window ID's programmatically. This does not help with other applications, however.
///  * Reviewing how third-party applications have generally pruned this list, I believe it will be necessary to use `hs.window.filter` to prune the list and access `hs.window` objects that are on the non-visible spaces.
///    * as `hs.window.filter` is scheduled to undergo a re-write soon to (hopefully) dramatically speed it up, I am providing this function *as is* at present for those who wish to experiment with it; however, I hope to make it more useful in the coming months and the contents may change in the future (the format won't, but hopefully the useless extras will disappear requiring less pruning logic on your end).
private func spaces_windowsForSpace(_ L: LuaState) throws -> CInt {
    precondition(lua_gettop(L) >= 1, "windowsForSpace requires at least a spaceID argument")
    let sid = UInt64(lua_tointeger(L, 1))
    let includeMinimized: Bool = lua_gettop(L) > 1 ? (lua_toboolean(L, 2) != 0) : true

    let owner: UInt32 = 0
    let options: UInt32 = includeMinimized ? 0x7 : 0x2
    var setTags: UInt64 = 0
    var clearTags: UInt64 = 0

    let type = SLSSpaceGetType(g_connection, sid)
    if type != 0 && type != 4 {
        lua_pushnil(L)
        L.push("not a user or fullscreen managed space")
        return 2
    }

    let spacesList = [NSNumber(value: sid)] as CFArray

    if let windowListRef = SLSCopyWindowsWithOptionsAndTags(g_connection, owner, spacesList, options, &setTags, &clearTags) {
        lua_pushany(L, windowListRef as NSArray)
        lua_newtable(L)
        lua_getglobal(L, "require")

        L.push("hs.inspect")

        lua_pcall(L, 1, 1, 0)
        lua_setfield(L, -2, "__tostring")
        lua_setmetatable(L, -2)
    } else {
        lua_pushnil(L)
        L.push("SLSCopyWindowsWithOptionsAndTags returned NULL for \(sid)")
        return 2
    }
    return 1
}

/// hs.spaces.moveWindowToSpace(window, spaceID[, force]) -> true | nil, error
/// Function
/// Moves the window with the specified windowID to the space specified by spaceID.
///
/// Parameters:
///  * `window`  - an integer specifying the ID of the window, or an `hs.window` object
///  * `spaceID` - an integer specifying the ID of the space
///  * `force` - an optional boolean specifying whether the window should be tried to move even if the spaces aren't compatible
///
/// Returns:
///  * true if the window was moved; otherwise nil and an error message.
///
/// Notes:
///  * a window can only be moved from a user space to another user space -- you cannot move the window of a full screen (or tiled) application to another space. you also cannot move a window *to* the same space as a full screen application unless `force` is set to true and even then it works for floating windows only.
private func spaces_moveWindowToSpace(_ L: LuaState) throws -> CInt {
    precondition(lua_gettop(L) >= 2, "moveWindowToSpace requires window and spaceID arguments")
    var wid = UInt32(lua_tointeger(L, 1))
    let sid = UInt64(lua_tointeger(L, 2))
    let force: Bool = lua_gettop(L) > 2 ? (lua_toboolean(L, 3) != 0) : false

    if SLSSpaceGetType(g_connection, sid) != 0 && !force {
        lua_pushnil(L)
        L.push("target space ID \(sid) does not refer to a user space")
        return 2
    }

    let windows = [NSNumber(value: wid)] as CFArray
    // 0x7 : kCGSAllSpacesMask
    if let spacesList = SLSCopySpacesForWindows(g_connection, 0x7, windows) {
        let spacesArray = spacesList as NSArray
        if !spacesArray.contains(NSNumber(value: sid)) {
            if let sourceSpace = spacesArray.firstObject as? NSNumber {
                if SLSSpaceGetType(g_connection, sourceSpace.uint64Value) != 0 && !force {
                    lua_pushnil(L)
                    L.push("source space for windowID \(wid) is not a user space")
                    return 2
                }
            }

            if workspace_is_macos_sonoma14_5_or_newer() {
                _ = SLSSpaceSetCompatID(g_connection, sid, 0x79616265)
                _ = SLSSetWindowListWorkspace(g_connection, &wid, 1, 0x79616265)
                _ = SLSSpaceSetCompatID(g_connection, sid, 0x0)
            } else {
                SLSMoveWindowsToManagedSpace(g_connection, windows, sid)
            }
        }
        L.push(true)
    } else {
        lua_pushnil(L)
        L.push("SLSCopySpacesForWindows returned NULL for window ID \(wid)")
        return 2
    }
    return 1
}

/// hs.spaces.windowSpaces(window) -> table | nil, error
/// Function
/// Returns a table containing the space IDs for all spaces that the specified window is on.
///
/// Parameters:
///  * `window` - an integer specifying the ID of the window, or an `hs.window` object
///
/// Returns:
///  * a table containing the space IDs of all spaces the window is on, or nil and an error message if an error occurs.
///
/// Notes:
///  * the table returned has its __tostring metamethod set to `hs.inspect` to simplify inspecting the results when using the Cosmic Hammer Console.
///  * If the window ID does not specify a valid window, then an empty array will be returned.
///  * For most windows, this will be a single element table; however some applications may create "sticky" windows that may appear on more than one space.
///    * For example, the container windows for `hs.canvas` objects which have the `canJoinAllSpaces` behavior set will appear on all spaces and the table returned by this function will contain all spaceIDs for the screen which displays the canvas.
private func spaces_windowSpaces(_ L: LuaState) throws -> CInt {
    precondition(lua_gettop(L) >= 1, "windowSpaces requires a window ID argument")
    let wid = UInt32(lua_tointeger(L, 1))

    let windows = [NSNumber(value: wid)] as CFArray
    // 0x7 : kCGSAllSpacesMask
    if let spacesList = SLSCopySpacesForWindows(g_connection, 0x7, windows) {
        lua_pushany(L, spacesList as NSArray)
        lua_newtable(L)
        lua_getglobal(L, "require")

        L.push("hs.inspect")

        lua_pcall(L, 1, 1, 0)
        lua_setfield(L, -2, "__tostring")
        lua_setmetatable(L, -2)
    } else {
        lua_pushnil(L)
        L.push("SLSCopySpacesForWindows returned NULL for window ID \(wid)")
        return 2
    }
    return 1
}

private func spaces_coreDesktopSendNotification(_ L: LuaState) throws -> CInt {
    luaL_checktype(L, 1, LUA_TSTRING)
    let message = lua_tovalue(L, at: 1) as! NSString

    L.push(lua_Integer(CoreDockSendNotification(message as CFString, 0).rawValue))
    return 1
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libspaces")
public func luaopen_hs_libspaces(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        // Create module table
        lua_createtable(L, 0, 7)
        L.push(spaces_screensHaveSeparateSpaces)
        lua_setfield(L, -2, "screensHaveSeparateSpaces")
        L.push(spaces_managedDisplaySpaces)
        lua_setfield(L, -2, "data_managedDisplaySpaces")
        L.push(spaces_getActiveSpace)
        lua_setfield(L, -2, "focusedSpace")
        L.push(spaces_moveWindowToSpace)
        lua_setfield(L, -2, "moveWindowToSpace")
        L.push(spaces_windowsForSpace)
        lua_setfield(L, -2, "windowsForSpace")
        L.push(spaces_windowSpaces)
        lua_setfield(L, -2, "windowSpaces")
        L.push(spaces_coreDesktopSendNotification)
        lua_setfield(L, -2, "_coreDesktopNotification")

        g_connection = SLSMainConnectionID()
        assert(g_connection != 0, "SLSMainConnectionID must return a valid connection")

        do {
            regEx_UUID = try NSRegularExpression(
                pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                options: .caseInsensitive
            )
        } catch {
            regEx_UUID = nil
            os_log(.error, "%{public}s","\(USERDATA_TAG).luaopen - unable to create UUID regular expression: \(error.localizedDescription)")
        }
    }
}
