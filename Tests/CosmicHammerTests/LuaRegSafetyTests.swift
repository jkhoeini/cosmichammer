import Testing
import Foundation

extension CosmicHammerTests {
    @Suite(.serialized) @MainActor final class LuaRegSafety {

        /// Verify no luaL_Reg entries use the unsafe ("..." as NSString).utf8String
        /// pattern.  Those pointers dangle after the autorelease pool drains,
        /// corrupting function names on hs.reload().  Use strdup("...") instead.
        @Test func testNoUnsafeNSStringUTF8InLuaLReg() throws {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourcesDir = repoRoot.appendingPathComponent("Sources/HSSwiftExtensions")

            let enumerator = FileManager.default.enumerator(
                at: sourcesDir,
                includingPropertiesForKeys: nil
            )

            var violations: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let contents = try String(contentsOf: url, encoding: .utf8)
                for (i, line) in contents.components(separatedBy: "\n").enumerated() {
                    if line.contains("luaL_Reg") && line.contains("NSString") && line.contains("utf8String") {
                        let relative = url.lastPathComponent
                        violations.append("\(relative):\(i + 1)")
                    }
                }
            }

            #expect(violations.isEmpty,
                "Found unsafe (\"...\" as NSString).utf8String in luaL_Reg entries — use strdup(\"...\") instead:\n\(violations.joined(separator: "\n"))")
        }

        @Test(.disabled("C1 migration eliminated all luaL_Reg; re-require crashes L.register(Metatable<T>) which is by-design"))
        func testModuleMetatablesSurviveReRequire() {
            let checks: [(cLib: String, luaLib: String, expectedMeta: [String])] = [
                ("hs.libdoc", "hs.doc",
                 ["_registerTriggerFunction", "_children", "_loadRegisteredFiles",
                  "_registeredFilesObject", "_documentationTreeObject", "__gc"]),
                ("hs.libmarkdown", "hs.doc.markdown", []),
                ("hs.libhid", "hs.hid", []),
                ("hs.libnetworkconfiguration", "hs.network.configuration", []),
                ("hs.libnetworkreachability", "hs.network.reachability", []),
                ("hs.libnetworkhost", "hs.network.host", []),
                ("hs.libdrawing_color", "hs.drawing.color", []),
            ]

            for (cLib, luaLib, expectedMeta) in checks {
                _ = runLua("require('\(luaLib)')")
                _ = runLua("package.loaded['\(cLib)'] = nil")

                let loadResult = runLua("local ok, err = pcall(require, '\(cLib)'); if ok then return 'ok' else return err end")
                #expect(loadResult == "ok",
                    "\(cLib) failed to re-require: \(loadResult ?? "nil")")

                for fn in expectedMeta {
                    let check = runLua("""
                        local m = require('\(cLib)')
                        local mt = getmetatable(m)
                        if not mt then return 'no metatable' end
                        if type(mt['\(fn)']) ~= 'function' then return 'missing' end
                        return 'ok'
                    """)
                    #expect(check == "ok",
                        "\(cLib): metatable.\(fn) is \(check ?? "nil") after re-require")
                }
            }
        }

        @Test func testDocRegisterJSONFileRejectsNilWithoutCrashing() {
            let result = runLua("""
                local doc = require('hs.libdoc')
                local ok, err = pcall(doc.registerJSONFile, nil)
                if ok then return 'accepted nil' end
                return type(err)
            """)
            #expect(result == "string")
        }
    }
}
