import CLua
@testable import HSSwiftExtensions

nonisolated(unsafe) private var testFlag = false

private let verifyShutdown: lua_CFunction = { L in
    testFlag = true
    return 0
}

enum HScoresetupHelper {
    @MainActor static func registerShutdownLib() {
        var shutdownLib: [luaL_Reg] = [
            luaL_Reg(name: UnsafeRawPointer(("verifyShutdown" as StaticString).utf8Start)
                .assumingMemoryBound(to: CChar.self), func: verifyShutdown),
            luaL_Reg(name: nil, func: nil),
        ]
        let L = lua_getCurrentState()!
        lua_createtable(L, 0, Int32(shutdownLib.count - 1))
        luaL_setfuncs(L, &shutdownLib, 0)
        lua_setglobal(L, "shutdownLib")
    }

    static func shutdownFired() -> Bool { testFlag }
    static func resetShutdownFlag() { testFlag = false }
}
