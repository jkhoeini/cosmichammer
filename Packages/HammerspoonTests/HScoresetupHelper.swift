import LuaSkin

nonisolated(unsafe) private var testFlag = false

private let verifyShutdown: lua_CFunction = { L in
    testFlag = true
    return 0
}

enum HScoresetupHelper {
    @MainActor static func registerShutdownLib() {
        var shutdownLib: [luaL_Reg] = [
            luaL_Reg(name: strdup("verifyShutdown"), func: verifyShutdown),
            luaL_Reg(name: nil, func: nil),
        ]
        let skin = LuaSkin.shared(with: nil) as! LuaSkin
        skin.registerLibrary("shutdownLib", functions: &shutdownLib, metaFunctions: nil)
        lua_setglobal(skin.l, "shutdownLib")
    }

    static func shutdownFired() -> Bool { testFlag }
    static func resetShutdownFlag() { testFlag = false }
}
