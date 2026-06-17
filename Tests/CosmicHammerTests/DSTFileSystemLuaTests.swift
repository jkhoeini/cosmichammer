import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite("DST FileSystem Lua") final class DSTFileSystemLuaTests {

        // MARK: - temporaryDirectory (fully routed through environmentGet)

        @Test func temporaryDirectoryReturnsSimulatedTmp() {
            withLuaState { L in
                _ = luaopen_hs_libfs(L)
                lua_setglobal(L, "fs")

                let result = luaEvalString(L, "return fs.temporaryDirectory()")
                #expect(result != nil)
                #expect(result!.hasPrefix("/tmp"))
            }
        }

        @Test func temporaryDirectoryEndsWithSlash() {
            withLuaState { L in
                _ = luaopen_hs_libfs(L)
                lua_setglobal(L, "fs")

                let result = luaEvalString(L, "return fs.temporaryDirectory()")
                #expect(result != nil)
                #expect(result!.hasSuffix("/"))
            }
        }

        @Test func temporaryDirectoryReflectsCustomTmpPath() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem as! SimulatedFileSystem
            fs.tmp = "/custom/tmp"

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            _ = luaopen_hs_libfs(L)
            lua_setglobal(L, "fs")

            let result = luaEvalString(L, "return fs.temporaryDirectory()")
            #expect(result == "/custom/tmp/")
        }

        // MARK: - displayName (existence check via environmentGet)

        @Test func displayNameReturnsNilForNonexistentFile() {
            withLuaState { L in
                _ = luaopen_hs_libfs(L)
                lua_setglobal(L, "fs")

                // The simulated FS has no file at this path, so fileExists returns false
                let result = luaEvalString(L, "return type(fs.displayName('/nonexistent/file.txt'))")
                #expect(result == "nil")
            }
        }

        @Test func displayNameReturnsNilForMissingSeededPath() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem as! SimulatedFileSystem
            // Seed a file at one path but query a different path
            fs.seed(path: "/existing/file.txt", node: .file("data".data(using: .utf8)!))

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            _ = luaopen_hs_libfs(L)
            lua_setglobal(L, "fs")

            let result = luaEvalString(L, "return type(fs.displayName('/other/path.txt'))")
            #expect(result == "nil")
        }

        // MARK: - fileListForPath (existence and isDirectory via environmentGet)

        @Test func fileListForPathRejectsNonexistentPath() {
            withLuaState { L in
                _ = luaopen_hs_libfs(L)
                lua_setglobal(L, "fs")

                // Path does not exist in simulated FS, should throw Lua error
                let errMsg = luaErrorMsg(L, "return fs.fileListForPath('/no/such/dir')")
                #expect(errMsg != nil)
                #expect(errMsg!.contains("does not specify a reachable file"))
            }
        }

        @Test func fileListForPathReturnsSingleFileForFilePath() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem as! SimulatedFileSystem
            // Seed a regular file -- fileExists returns true, isDirectory returns false
            fs.seed(path: "/testfile.txt", node: .file("content".data(using: .utf8)!))

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            _ = luaopen_hs_libfs(L)
            lua_setglobal(L, "fs")

            // For a file path (not dir), fileListForPath returns a table with just that file
            let count = luaEvalInt(L, """
                local list, fileCount, dirCount = fs.fileListForPath('/testfile.txt')
                return fileCount
            """)
            #expect(count == 1)
        }

        // MARK: - SimulatedFileSystem via environment (protocol-level tests through Lua state)

        @Test func simulatedFileSystemCurrentDirectoryPath() {
            withLuaState { L in
                let env = environmentGet(L)
                let cwd = env.fileSystem.currentDirectoryPath()
                #expect(cwd == "/tmp")
            }
        }

        @Test func simulatedFileSystemHomeDirectory() {
            withLuaState { L in
                let env = environmentGet(L)
                let home = env.fileSystem.homeDirectory()
                #expect(home == "/Users/test")
            }
        }

        @Test func simulatedFileSystemSeedAndRead() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem as! SimulatedFileSystem
            fs.seed(path: "/data/file.txt", node: .file("hello world".data(using: .utf8)!))

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            // Verify through the environment attached to the Lua state
            let envFromLua = environmentGet(L)
            let data = try envFromLua.fileSystem.contentsOfFile(atPath: "/data/file.txt")
            #expect(String(data: data, encoding: .utf8) == "hello world")
        }

        @Test func simulatedFileSystemCreateAndListDirectory() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            let fs = environmentGet(L).fileSystem
            try fs.createDirectory(atPath: "/mydir", withIntermediateDirectories: false)
            #expect(fs.isDirectory(atPath: "/mydir"))

            try fs.writeFile(atPath: "/mydir/a.txt", contents: "aaa".data(using: .utf8)!, atomically: true)
            try fs.writeFile(atPath: "/mydir/b.txt", contents: "bbb".data(using: .utf8)!, atomically: true)

            let entries = try fs.contentsOfDirectory(atPath: "/mydir")
            #expect(entries.count == 2)
            #expect(entries.contains("a.txt"))
            #expect(entries.contains("b.txt"))
        }

        @Test func simulatedFileSystemRemoveDirectory() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            let fs = environmentGet(L).fileSystem
            try fs.createDirectory(atPath: "/removeme", withIntermediateDirectories: false)
            #expect(fs.fileExists(atPath: "/removeme"))

            try fs.removeItem(atPath: "/removeme")
            #expect(!fs.fileExists(atPath: "/removeme"))
        }

        // MARK: - Fault injection through Lua state's environment

        @Test func fileReadFaultBlocksContentsOfFile() {
            var faults = FaultConfig()
            faults.fileReadFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let fs = env.fileSystem as! SimulatedFileSystem
            fs.seed(path: "/fault-test.txt", node: .file("data".data(using: .utf8)!))

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            // contentsOfFile should throw due to injected fault
            #expect(throws: (any Error).self) {
                _ = try environmentGet(L).fileSystem.contentsOfFile(atPath: "/fault-test.txt")
            }
        }

        @Test func diskFullFaultBlocksWrite() {
            var faults = FaultConfig()
            faults.diskFullProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            #expect(throws: (any Error).self) {
                try environmentGet(L).fileSystem.writeFile(
                    atPath: "/disk-full.txt",
                    contents: "data".data(using: .utf8)!,
                    atomically: true
                )
            }
        }

        @Test func fileWriteFaultBlocksWrite() {
            var faults = FaultConfig()
            faults.fileWriteFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            let L = luaL_newstate()!
            luaL_openlibs(L)
            environmentAttach(L, env)
            defer { environmentDetach(L); lua_close(L) }

            #expect(throws: (any Error).self) {
                try environmentGet(L).fileSystem.writeFile(
                    atPath: "/write-fail.txt",
                    contents: "data".data(using: .utf8)!,
                    atomically: true
                )
            }
        }

        // MARK: - Determinism

        @Test func sameSeeedProducesSameTemporaryDirectory() {
            // Two Lua states with the same seed should produce identical temporaryDirectory results
            var results: [String] = []
            for _ in 0..<2 {
                let harness = SimulatorHarness(seed: 42)
                let env = harness.createEnvironment()
                let L = luaL_newstate()!
                luaL_openlibs(L)
                environmentAttach(L, env)

                _ = luaopen_hs_libfs(L)
                lua_setglobal(L, "fs")

                if let r = luaEvalString(L, "return fs.temporaryDirectory()") {
                    results.append(r)
                }
                environmentDetach(L)
                lua_close(L)
            }
            #expect(results.count == 2)
            #expect(results[0] == results[1])
        }

        @Test func differentSeedsCanHaveSameDefaultPaths() {
            // Default tmp/home/cwd are the same regardless of seed (they are fixed defaults)
            let h1 = SimulatorHarness(seed: 1)
            let h2 = SimulatorHarness(seed: 999)
            let env1 = h1.createEnvironment()
            let env2 = h2.createEnvironment()

            #expect(env1.fileSystem.temporaryDirectory() == env2.fileSystem.temporaryDirectory())
            #expect(env1.fileSystem.homeDirectory() == env2.fileSystem.homeDirectory())
            #expect(env1.fileSystem.currentDirectoryPath() == env2.fileSystem.currentDirectoryPath())
        }

        // MARK: - Timestamp tests

        @Test func writeFileSetsCreationAndModificationDate() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.writeFile(atPath: "/ts/test.txt", contents: "hello".data(using: .utf8)!, atomically: true)
            let attrs = try fs.attributesOfItem(atPath: "/ts/test.txt")
            #expect(attrs.creationDate != nil)
            #expect(attrs.modificationDate != nil)
            #expect(attrs.creationDate == attrs.modificationDate)
        }

        @Test func overwriteFilePreservesCreationDateUpdatesModificationDate() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.writeFile(atPath: "/ts/overwrite.txt", contents: "v1".data(using: .utf8)!, atomically: true)
            let attrsV1 = try fs.attributesOfItem(atPath: "/ts/overwrite.txt")

            harness.advanceTime(by: 10)

            try fs.writeFile(atPath: "/ts/overwrite.txt", contents: "v2".data(using: .utf8)!, atomically: true)
            let attrsV2 = try fs.attributesOfItem(atPath: "/ts/overwrite.txt")

            #expect(attrsV2.creationDate == attrsV1.creationDate)
            #expect(attrsV2.modificationDate! > attrsV1.modificationDate!)
        }

        @Test func createDirectorySetsTimestamps() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.createDirectory(atPath: "/ts/mydir", withIntermediateDirectories: true)
            let attrs = try fs.attributesOfItem(atPath: "/ts/mydir")
            #expect(attrs.creationDate != nil)
            #expect(attrs.modificationDate != nil)
        }

        @Test func moveItemPreservesCreationDateUpdatesModificationDate() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.writeFile(atPath: "/ts/src.txt", contents: "data".data(using: .utf8)!, atomically: true)
            let srcAttrs = try fs.attributesOfItem(atPath: "/ts/src.txt")

            harness.advanceTime(by: 5)

            try fs.moveItem(from: "/ts/src.txt", to: "/ts/dst.txt")
            let dstAttrs = try fs.attributesOfItem(atPath: "/ts/dst.txt")

            #expect(dstAttrs.creationDate == srcAttrs.creationDate)
            #expect(dstAttrs.modificationDate! > srcAttrs.modificationDate!)
        }

        @Test func createAdvanceModifyShowsCreationBeforeModification() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.writeFile(atPath: "/ts/timeline.txt", contents: "initial".data(using: .utf8)!, atomically: true)

            harness.advanceTime(by: 60)

            try fs.writeFile(atPath: "/ts/timeline.txt", contents: "updated".data(using: .utf8)!, atomically: true)
            let attrs = try fs.attributesOfItem(atPath: "/ts/timeline.txt")

            #expect(attrs.creationDate! < attrs.modificationDate!)
        }

        @Test func seededFilesHaveNoTimestampsByDefault() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem as! SimulatedFileSystem
            fs.seed(path: "/ts/seeded.txt", node: .file("seeded".data(using: .utf8)!))

            let attrs = try fs.attributesOfItem(atPath: "/ts/seeded.txt")
            // seed() bypasses clock -- no timestamps set
            #expect(attrs.creationDate == nil)
            #expect(attrs.modificationDate == nil)
        }
    }
}
