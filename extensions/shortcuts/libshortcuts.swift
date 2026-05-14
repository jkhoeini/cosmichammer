import Cocoa
import LuaSkin
import ScriptingBridge

private var refTable: LSRefTable = LUA_NOREF

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
private func shortcuts_list(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TBREAK)

    let app: ShortcutsEventsApplication = SBApplication(bundleIdentifier: "com.apple.shortcuts.events")!

    var shortcuts: [[String: Any]] = []
    for shortcut in app.shortcuts!() as! [ShortcutsEventsShortcut] {
        let data: [String: Any] = [
            "name": shortcut.name!,
            "id": shortcut.id!(),
            "acceptsInput": NSNumber(value: shortcut.acceptsInput),
            "actionCount": NSNumber(value: shortcut.actionCount),
        ]
        shortcuts.append(data)
    }

    skin.pushNSObject(shortcuts as NSArray)
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
private func shortcuts_run(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    skin.checkArgs(LS_TSTRING, LS_TBREAK)

    let name = skin.toNSObjectAtIndex(1) as! String

    let app: ShortcutsEventsApplication = SBApplication(bundleIdentifier: "com.apple.shortcuts.events")!
    for shortcut in app.shortcuts!() as! [ShortcutsEventsShortcut] {
        if shortcut.name == name {
            shortcut.runWithInput?(nil)
            break
        }
    }

    return 0
}

// MARK: - Module Registration

private var moduleLib: [luaL_Reg] = [
    luaL_Reg(name: strdup("list"), func: shortcuts_list),
    luaL_Reg(name: strdup("run"), func: shortcuts_run),
    luaL_Reg(name: nil, func: nil),
]

@_cdecl("luaopen_hs_libshortcuts")
public func luaopen_hs_libshortcuts(_ L: OpaquePointer!) -> Int32 {
    let skin = LuaSkin.shared(withState: L)
    refTable = skin.registerLibrary("hs.shortcuts", functions: &moduleLib, metaFunctions: nil)
    return 1
}
