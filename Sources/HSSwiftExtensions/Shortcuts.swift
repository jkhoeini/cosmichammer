import Cocoa
import CLua
import Lua
import ScriptingBridge

// MARK: - ScriptingBridge Protocol Declarations

@objc protocol ShortcutsEventsShortcut {
    @objc optional var name: String { get }
    @objc optional func id() -> String
    @objc optional var acceptsInput: Bool { get }
    @objc optional var actionCount: Int { get }
    @objc optional func runWithInput(_ withInput: Any?) -> Any?
}

@objc protocol ShortcutsEventsApplication {
    @objc optional func shortcuts() -> SBElementArray
}

extension SBApplication: ShortcutsEventsApplication {}

// MARK: - Module Functions

/// hs.shortcuts.list() -> []
/// Function
/// Returns a list of available shortcuts
///
/// Parameters:
///  * None
///
/// Returns:
///  * A table of shortcuts, each being a table with the following keys:
///   * name - The name of the shortcut
///   * id - A unique ID for the shortcut
///   * acceptsInput - A boolean indicating if the shortcut requires input
///   * actionCount - A number relating to how many actions are in the shortcut
private func shortcuts_list(_ L: LuaState) throws -> CInt {
    guard let app: ShortcutsEventsApplication = SBApplication(bundleIdentifier: "com.apple.shortcuts.events") else {
        lua_pushnil(L)
        return 1
    }

    var shortcuts: [[String: Any]] = []
    if let elements = app.shortcuts?() {
        for item in elements {
            guard let shortcut = item as? ShortcutsEventsShortcut else { continue }
            var data: [String: Any] = [:]
            if let name = shortcut.name {
                data["name"] = name
            }
            if let id = shortcut.id?() {
                data["id"] = id
            }
            data["acceptsInput"] = NSNumber(value: shortcut.acceptsInput ?? false)
            data["actionCount"] = NSNumber(value: shortcut.actionCount ?? 0)
            shortcuts.append(data)
        }
    }

    lua_pushany(L, shortcuts as NSArray)
    return 1
}

/// hs.shortcuts.run(name)
/// Function
/// Execute a Shortcuts shortcut by name
///
/// Parameters:
///  * name - A string containing the name of the Shortcut to execute
///
/// Returns:
///  * None
private func shortcuts_run(_ L: LuaState) throws -> CInt {
    let name = String(cString: luaL_checkstring(L, 1))

    guard let app: ShortcutsEventsApplication = SBApplication(bundleIdentifier: "com.apple.shortcuts.events") else {
        return 0
    }
    if let elements = app.shortcuts?() {
        for item in elements {
            guard let shortcut = item as? ShortcutsEventsShortcut else { continue }
            if shortcut.name == name {
                _ = shortcut.runWithInput?(nil)
                break
            }
        }
    }

    return 0
}

// MARK: - Module Registration

@_cdecl("luaopen_hs_libshortcuts")
public func luaopen_hs_libshortcuts(_ L: UnsafeMutablePointer<lua_State>!) -> Int32 {
    runEntryPoint(L) { L in
        lua_createtable(L, 0, 2)
        L.push(shortcuts_list)
        lua_setfield(L, -2, "list")
        L.push(shortcuts_run)
        lua_setfield(L, -2, "run")
    }
}
