import Testing
import Foundation
import CLua
import HSDSTCore
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {

    @Suite("DST Fault Injection") final class DSTFaultInjectionTests {

        // MARK: - Brightness

        @Test func brightnessSetFailsUnderFault() {
            var faults = FaultConfig()
            faults.brightnessSetFailProbability = 1.0
            withLuaState(faults: faults) { L in
                _ = luaopen_hs_libbrightness(L)
                lua_setglobal(L, "brightness")
                #expect(luaEvalBool(L, "return brightness.set(50)") == false)
            }
        }

        @Test func brightnessSetSucceedsWithoutFault() {
            withLuaState { L in
                _ = luaopen_hs_libbrightness(L)
                lua_setglobal(L, "brightness")
                #expect(luaEvalBool(L, "return brightness.set(50)") == true)
                #expect(luaEvalInt(L, "return brightness.get()") == 50)
            }
        }

        // MARK: - Settings

        @Test func settingsReadReturnsNilUnderFault() {
            var faults = FaultConfig()
            faults.settingsReadFailProbability = 1.0
            withLuaState(faults: faults) { L in
                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settings")
                #expect(luaEval(L, "settings.set('testKey', 'hello')"))
                #expect(luaEvalString(L, "return settings.get('testKey')") == nil)
            }
        }

        @Test func settingsRoundTripWithoutFault() {
            withLuaState { L in
                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settings")
                #expect(luaEval(L, "settings.set('testKey', 'hello')"))
                #expect(luaEvalString(L, "return settings.get('testKey')") == "hello")
            }
        }

        @Test func settingsTypedAccessors() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let settings = env.settings as! SimulatedSettings

            settings.set(true, forKey: "flag")
            settings.set(42, forKey: "count")
            settings.set(3.14, forKey: "pi")
            settings.set("hello", forKey: "greeting")
            settings.set([1, 2, 3], forKey: "nums")
            settings.set(["a": 1], forKey: "map")

            #expect(settings.bool(forKey: "flag") == true)
            #expect(settings.integer(forKey: "count") == 42)
            #expect(settings.double(forKey: "pi") == 3.14)
            #expect(settings.string(forKey: "greeting") == "hello")
            #expect(settings.array(forKey: "nums")?.count == 3)
            #expect(settings.dictionary(forKey: "map")?["a"] as? Int == 1)
            #expect(settings.allKeys().count == 6)
        }

        @Test func settingsRemoveObject() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            env.settings.set("value", forKey: "key")
            #expect(env.settings.string(forKey: "key") == "value")

            env.settings.removeObject(forKey: "key")
            #expect(env.settings.string(forKey: "key") == nil)
        }

        // MARK: - File system

        @Test func fileReadThrowsUnderFault() {
            var faults = FaultConfig()
            faults.fileReadFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let fs = env.fileSystem as! SimulatedFileSystem
            fs.seed(path: "/test.txt", node: .file("hello".data(using: .utf8)!))

            #expect(throws: (any Error).self) {
                _ = try env.fileSystem.contentsOfFile(atPath: "/test.txt")
            }
        }

        @Test func fileReadSucceedsWithoutFault() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem as! SimulatedFileSystem
            fs.seed(path: "/test.txt", node: .file("hello".data(using: .utf8)!))

            let data = try env.fileSystem.contentsOfFile(atPath: "/test.txt")
            #expect(String(data: data, encoding: .utf8) == "hello")
        }

        @Test func fileWriteThrowsWhenDiskFull() {
            var faults = FaultConfig()
            faults.diskFullProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(throws: (any Error).self) {
                try env.fileSystem.writeFile(atPath: "/out.txt", contents: Data(), atomically: true)
            }
        }

        @Test func fileWriteFailsUnderFault() {
            var faults = FaultConfig()
            faults.fileWriteFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(throws: (any Error).self) {
                try env.fileSystem.writeFile(atPath: "/out.txt", contents: "data".data(using: .utf8)!, atomically: true)
            }
        }

        @Test func fileSystemDirectoryOperations() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.createDirectory(atPath: "/a/b/c", withIntermediateDirectories: true)
            #expect(fs.isDirectory(atPath: "/a/b/c"))
            #expect(fs.fileExists(atPath: "/a/b"))

            try fs.writeFile(atPath: "/a/b/c/file.txt", contents: "test".data(using: .utf8)!, atomically: true)
            #expect(fs.fileExists(atPath: "/a/b/c/file.txt"))

            let listing = try fs.contentsOfDirectory(atPath: "/a/b/c")
            #expect(listing == ["file.txt"])
        }

        @Test func fileSystemMoveAndCopy() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.writeFile(atPath: "/src.txt", contents: "data".data(using: .utf8)!, atomically: true)

            try fs.copyItem(from: "/src.txt", to: "/copy.txt")
            #expect(fs.fileExists(atPath: "/src.txt"))
            #expect(fs.fileExists(atPath: "/copy.txt"))

            try fs.moveItem(from: "/src.txt", to: "/moved.txt")
            #expect(!fs.fileExists(atPath: "/src.txt"))
            #expect(fs.fileExists(atPath: "/moved.txt"))

            let data = try fs.contentsOfFile(atPath: "/moved.txt")
            #expect(String(data: data, encoding: .utf8) == "data")
        }

        @Test func fileSystemAttributes() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem as! SimulatedFileSystem

            fs.seed(path: "/test.txt", node: .file("hello world".data(using: .utf8)!, permissions: 0o600))
            let attrs = try fs.attributesOfItem(atPath: "/test.txt")
            #expect(attrs.size == 11)
            #expect(attrs.fileType == .regular)
            #expect(attrs.posixPermissions == 0o600)

            try fs.setAttributes(posixPermissions: 0o755, ofItemAtPath: "/test.txt")
            let updated = try fs.attributesOfItem(atPath: "/test.txt")
            #expect(updated.posixPermissions == 0o755)
        }

        @Test func fileSystemRemove() throws {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let fs = env.fileSystem

            try fs.writeFile(atPath: "/delete-me.txt", contents: Data(), atomically: true)
            #expect(fs.fileExists(atPath: "/delete-me.txt"))

            try fs.removeItem(atPath: "/delete-me.txt")
            #expect(!fs.fileExists(atPath: "/delete-me.txt"))
        }

        @Test func fileSystemReadNonexistent() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            #expect(throws: (any Error).self) {
                _ = try env.fileSystem.contentsOfFile(atPath: "/does-not-exist.txt")
            }
        }

        @Test func fileSystemPaths() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            #expect(env.fileSystem.currentDirectoryPath() == "/tmp")
            #expect(env.fileSystem.homeDirectory() == "/Users/test")
            #expect(env.fileSystem.temporaryDirectory().hasPrefix("/tmp"))
        }

        // MARK: - RPRNG

        @Test func sameSeeedProducesSameRPRNGSequence() {
            var rng1 = RPRNG(seed: 123)
            var rng2 = RPRNG(seed: 123)
            let seq1 = (0..<10).map { _ in rng1.next() }
            let seq2 = (0..<10).map { _ in rng2.next() }
            #expect(seq1 == seq2)
        }

        @Test func differentSeedsProduceDifferentResults() {
            var rng1 = RPRNG(seed: 1)
            var rng2 = RPRNG(seed: 2)
            #expect(rng1.next() != rng2.next())
        }

        @Test func rprngForkProducesIndependentStream() {
            var parent = RPRNG(seed: 77)
            var child = parent.fork()
            let parentSeq = (0..<5).map { _ in parent.next() }
            let childSeq = (0..<5).map { _ in child.next() }
            #expect(parentSeq != childSeq)
        }

        @Test func rprngUniformBelowStaysInRange() {
            var rng = RPRNG(seed: 42)
            for _ in 0..<1000 {
                let val = rng.uniform(below: 10)
                #expect(val < 10)
            }
        }

        @Test func rprngBooleanProbabilityEdgeCases() {
            var rng = RPRNG(seed: 42)
            let alwaysFalse = rng.boolean(probability: 0)
            let alwaysTrue = rng.boolean(probability: 1)
            #expect(!alwaysFalse)
            #expect(alwaysTrue)

            var trueCount = 0
            for _ in 0..<10000 {
                if rng.boolean(probability: 0.5) { trueCount += 1 }
            }
            #expect(trueCount > 4000 && trueCount < 6000)
        }

        @Test func rprngPickFromCollection() {
            var rng = RPRNG(seed: 42)
            let items = ["a", "b", "c", "d"]
            var seen: Set<String> = []
            for _ in 0..<100 {
                seen.insert(rng.pick(from: items))
            }
            #expect(seen.count == items.count)
        }

        // MARK: - Timer

        @Test func timerFiresAtExactSimulatedTime() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var fired = false

            let timer = env.clock.createTimer(interval: 1.0, repeats: false) {
                fired = true
            }
            timer.schedule()

            harness.advanceTime(by: 0.9)
            #expect(!fired)

            harness.advanceTime(by: 0.2)
            #expect(fired)
        }

        @Test func repeatingTimerFiresMultipleTimes() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var count = 0

            let timer = env.clock.createTimer(interval: 1.0, repeats: true) {
                count += 1
            }
            timer.schedule()

            harness.advanceTime(by: 3.5)
            #expect(count == 3)
        }

        @Test func timerCancelPreventsCallback() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var fired = false

            let timer = env.clock.createTimer(interval: 1.0, repeats: false) {
                fired = true
            }
            timer.schedule()
            timer.invalidate()

            harness.advanceTime(by: 2.0)
            #expect(!fired)
        }

        @Test func multipleTimersFireInCorrectOrder() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var order: [Int] = []

            let t1 = env.clock.createTimer(interval: 0.5, repeats: false) { order.append(1) }
            let t2 = env.clock.createTimer(interval: 0.3, repeats: false) { order.append(2) }
            let t3 = env.clock.createTimer(interval: 0.8, repeats: false) { order.append(3) }
            t1.schedule()
            t2.schedule()
            t3.schedule()

            harness.advanceTime(by: 1.0)
            #expect(order == [2, 1, 3])
        }

        // MARK: - Notification

        @Test func notificationObserverReceivesPost() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let notif = env.notification
            var received = false

            _ = notif.addObserver(name: "TestEvent", object: nil) { _ in
                received = true
            }
            notif.post(name: "TestEvent", object: nil, userInfo: nil)
            #expect(received)
        }

        @Test func notificationDroppedUnderFault() {
            var faults = FaultConfig()
            faults.notificationDropProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var received = false

            _ = env.notification.addObserver(name: "TestEvent", object: nil) { _ in
                received = true
            }
            env.notification.post(name: "TestEvent", object: nil, userInfo: nil)
            #expect(!received)
        }

        @Test func notificationRemoveObserverStopsDelivery() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var count = 0

            let token = env.notification.addObserver(name: "TestEvent", object: nil) { _ in
                count += 1
            }
            env.notification.post(name: "TestEvent", object: nil, userInfo: nil)
            #expect(count == 1)

            env.notification.removeObserver(token)
            env.notification.post(name: "TestEvent", object: nil, userInfo: nil)
            #expect(count == 1)
        }

        @Test func distributedNotificationFiltersByName() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let notif = env.notification
            var receivedNames: [String] = []

            _ = notif.addDistributedObserver(name: "TargetEvent", object: nil) { name, _, _ in
                receivedNames.append(name)
            }
            notif.postDistributed(name: "TargetEvent", object: nil, userInfo: nil)
            notif.postDistributed(name: "OtherEvent", object: nil, userInfo: nil)
            notif.postDistributed(name: "TargetEvent", object: nil, userInfo: nil)

            #expect(receivedNames == ["TargetEvent", "TargetEvent"])
        }

        @Test func workspaceNotificationDelivery() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let notif = env.notification as! SimulatedNotification
            var receivedInfo: [String: Any]?

            _ = notif.addWorkspaceObserver(name: "AppLaunched", object: nil) { info in
                receivedInfo = info
            }
            notif.postWorkspace(name: "AppLaunched", userInfo: ["pid": 123])
            #expect(receivedInfo?["pid"] as? Int == 123)
        }

        // MARK: - Location

        @Test func locationPermissionDeniedUnderFault() {
            var faults = FaultConfig()
            faults.locationPermissionDenied = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var receivedError: Error?

            env.location.startUpdating { _, error in
                receivedError = error
            }
            #expect(receivedError != nil)
            #expect(env.location.authorizationStatus() == 2)
        }

        @Test func locationUnavailableUnderFault() {
            var faults = FaultConfig()
            faults.locationUnavailable = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(env.location.currentLocation() == nil)
        }

        @Test func locationCoordinateUpdate() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation
            var received: LocationCoordinate?

            loc.startUpdating { coord, _ in received = coord }
            #expect(received != nil)

            let custom = LocationCoordinate(latitude: 59.3293, longitude: 18.0686)
            loc.pushLocation(custom)
            #expect(received?.latitude == 59.3293)
            #expect(received?.longitude == 18.0686)
        }

        @Test func locationGeocode() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var addresses: [String]?

            env.location.geocode(latitude: 37.0, longitude: -122.0) { result, _ in
                addresses = result
            }
            #expect(addresses?.isEmpty == false)
        }

        @Test func locationStopUpdating() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let loc = env.location as! SimulatedLocation
            var callCount = 0

            loc.startUpdating { _, _ in callCount += 1 }
            #expect(callCount == 1)

            loc.stopUpdating()
            loc.pushLocation(LocationCoordinate(latitude: 0, longitude: 0))
            #expect(callCount == 1)
        }

        // MARK: - System info

        @Test func batteryUnavailableUnderFault() {
            var faults = FaultConfig()
            faults.batteryUnavailable = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(env.systemInfo.batteryInfo() == nil)
        }

        @Test func batteryInfoReturnsConfiguredState() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sys = env.systemInfo as! SimulatedSystemInfo
            sys.battery = BatteryInfo(percentage: 72, isCharging: true)

            let info = env.systemInfo.batteryInfo()
            #expect(info?.percentage == 72)
            #expect(info?.isCharging == true)
        }

        @Test func wifiUnavailableUnderFault() {
            var faults = FaultConfig()
            faults.wifiUnavailable = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(env.systemInfo.wifiInfo() == nil)
        }

        @Test func wifiInfoReturnsConfiguredState() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sys = env.systemInfo as! SimulatedSystemInfo
            sys.wifi = WifiInfo(ssid: "Spotify-Guest", rssi: -55)

            let info = env.systemInfo.wifiInfo()
            #expect(info?.ssid == "Spotify-Guest")
            #expect(info?.rssi == -55)
        }

        @Test func hostnameAndAddresses() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            #expect(env.systemInfo.hostname() == "test-mac.local")
            #expect(env.systemInfo.addresses().contains("192.168.1.100"))
        }

        @Test func audioDeviceVolumeAndMute() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let sys = env.systemInfo as! SimulatedSystemInfo

            let devices = sys.audioDevices()
            #expect(!devices.isEmpty)
            let uid = devices[0].uid

            #expect(sys.setAudioDeviceVolume(uid: uid, volume: 0.75))
            #expect(sys.audioDevices().first(where: { $0.uid == uid })?.volume == 0.75)

            #expect(sys.setAudioDeviceMuted(uid: uid, muted: true))
            #expect(sys.audioDevices().first(where: { $0.uid == uid })?.isMuted == true)

            #expect(!sys.setAudioDeviceVolume(uid: "nonexistent", volume: 0.5))
        }

        @Test func systemInfoMiscFields() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            #expect(env.systemInfo.thermalState() == 0)
            #expect(env.systemInfo.systemUptime() == 86400)

            let version = env.systemInfo.operatingSystemVersion()
            #expect(version.major == 26)
        }

        // MARK: - Process

        @Test func processLaunchFailsUnderFault() {
            var faults = FaultConfig()
            faults.processLaunchFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var result: ProcessResult?

            _ = env.process.run(executablePath: "/usr/bin/echo", arguments: ["hi"],
                                environment: nil, currentDirectory: nil) { r in
                result = r
            }
            harness.drainEventLoop()
            #expect(result?.exitCode == 127)
        }

        @Test func processCrashUnderFault() {
            var faults = FaultConfig()
            faults.processCrashProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var result: ProcessResult?

            _ = env.process.run(executablePath: "/usr/bin/echo", arguments: ["hi"],
                                environment: nil, currentDirectory: nil) { r in
                result = r
            }
            harness.drainEventLoop()
            #expect(result?.exitCode == -11)
        }

        @Test func processScriptedResult() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let proc = env.process as! SimulatedProcess

            proc.scriptedResults["/usr/bin/echo hello"] = ProcessResult(
                exitCode: 0, stdout: "hello\n".data(using: .utf8)!
            )

            var result: ProcessResult?
            _ = env.process.run(executablePath: "/usr/bin/echo", arguments: ["hello"],
                                environment: nil, currentDirectory: nil) { r in
                result = r
            }
            harness.drainEventLoop()
            #expect(result?.exitCode == 0)
            #expect(String(data: result!.stdout, encoding: .utf8) == "hello\n")
        }

        @Test func processSyncExecution() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let proc = env.process as! SimulatedProcess
            proc.defaultResult = ProcessResult(exitCode: 0, stdout: "ok".data(using: .utf8)!)

            let result = env.process.runSync(executablePath: "/bin/test", arguments: [],
                                             environment: nil, currentDirectory: nil)
            #expect(result.exitCode == 0)
            #expect(String(data: result.stdout, encoding: .utf8) == "ok")
            #expect(proc.launchedProcesses.count == 1)
        }

        @Test func processStreamingRun() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let proc = env.process as! SimulatedProcess
            proc.scriptedResults["/usr/bin/ls -la"] = ProcessResult(
                exitCode: 0,
                stdout: "total 0\ndrwxr-xr-x  2 user  staff  64 Jan  1 00:00 .\n".data(using: .utf8)!,
                stderr: Data()
            )

            var stdoutChunks: [Data] = []
            var exitCode: Int32?

            _ = env.process.streamingRun(
                executablePath: "/usr/bin/ls", arguments: ["-la"],
                environment: nil, currentDirectory: nil,
                onStdout: { stdoutChunks.append($0) },
                onStderr: { _ in },
                onExit: { exitCode = $0 }
            )

            harness.drainEventLoop()
            #expect(!stdoutChunks.isEmpty)
            #expect(exitCode == 0)
        }

        @Test func processCompletionIsAsync() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var result: ProcessResult?

            let handle = env.process.run(executablePath: "/usr/bin/true", arguments: [],
                                         environment: nil, currentDirectory: nil) { r in
                result = r
            }

            // Before draining: completion has not fired, process still "running"
            #expect(result == nil)
            #expect(handle.isRunning == true)

            // After draining: completion fires, process finishes
            harness.drainEventLoop()
            #expect(result != nil)
            #expect(result?.exitCode == 0)
            #expect(handle.isRunning == false)
        }

        @Test func processStreamingRunIsAsync() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let proc = env.process as! SimulatedProcess
            proc.defaultResult = ProcessResult(
                exitCode: 0,
                stdout: "out".data(using: .utf8)!,
                stderr: "err".data(using: .utf8)!
            )

            var stdoutChunks: [Data] = []
            var stderrChunks: [Data] = []
            var exitCode: Int32?

            let handle = env.process.streamingRun(
                executablePath: "/usr/bin/test", arguments: [],
                environment: nil, currentDirectory: nil,
                onStdout: { stdoutChunks.append($0) },
                onStderr: { stderrChunks.append($0) },
                onExit: { exitCode = $0 }
            )

            // Before draining: no callbacks fired
            #expect(stdoutChunks.isEmpty)
            #expect(stderrChunks.isEmpty)
            #expect(exitCode == nil)
            #expect(handle.isRunning == true)

            // After draining: all callbacks fire
            harness.drainEventLoop()
            #expect(stdoutChunks.count == 1)
            #expect(stderrChunks.count == 1)
            #expect(exitCode == 0)
            #expect(handle.isRunning == false)
        }

        @Test func processHandlesGetUniquePIDs() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            let handle1 = env.process.run(executablePath: "/usr/bin/a", arguments: [],
                                          environment: nil, currentDirectory: nil) { _ in }
            let handle2 = env.process.run(executablePath: "/usr/bin/b", arguments: [],
                                          environment: nil, currentDirectory: nil) { _ in }

            #expect(handle1.processIdentifier != handle2.processIdentifier)
        }

        // MARK: - Network

        @Test func httpRequestSucceeds() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let net = env.network as! SimulatedNetwork
            net.httpResponses["https://example.com"] = HTTPResponse(
                statusCode: 200, headers: [:], body: "OK".data(using: .utf8)
            )

            var response: HTTPResponse?
            env.network.httpRequest(url: "https://example.com", method: "GET",
                                    headers: [:], body: nil, redirect: true) { r, _ in
                response = r
            }
            #expect(response?.statusCode == 200)
            #expect(String(data: response!.body!, encoding: .utf8) == "OK")
        }

        @Test func httpRequestTimesOutUnderFault() {
            var faults = FaultConfig()
            faults.httpTimeoutProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var error: Error?

            env.network.httpRequest(url: "https://example.com", method: "GET",
                                    headers: [:], body: nil, redirect: true) { _, e in
                error = e
            }
            #expect(error != nil)
        }

        @Test func httpConnectionFailsUnderFault() {
            var faults = FaultConfig()
            faults.connectionFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var error: Error?

            env.network.httpRequest(url: "https://example.com", method: "GET",
                                    headers: [:], body: nil, redirect: true) { _, e in
                error = e
            }
            #expect(error != nil)
        }

        // MARK: - Telemetry

        @Test func telemetryFlushFailureReportsStatus() {
            var faults = FaultConfig()
            faults.telemetryFlushFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let telemetry = env.telemetry as! SimulatedTelemetry

            telemetry.configure(TelemetryConfiguration(enabled: true))
            #expect(!telemetry.flush(timeout: 1))

            let status = telemetry.status()
            #expect(status.lastFlushResult == "failure")
            #expect(status.lastExporterFailureKind == "flush_failed")
            #expect(status.flushFailureCount == 1)
            #expect(status.exporterFailureCount == 1)
            #expect(status.lastExportError?.contains("simulated") == true)
        }

        @Test func telemetryShutdownFailureReportsStatus() {
            var faults = FaultConfig()
            faults.telemetryShutdownFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let telemetry = env.telemetry as! SimulatedTelemetry

            telemetry.configure(TelemetryConfiguration(enabled: true))
            #expect(!telemetry.shutdown(timeout: 1))

            let status = telemetry.status()
            #expect(status.shutdownCount == 1)
            #expect(status.lastShutdownResult == "failure")
            #expect(status.lastExporterFailureKind == "shutdown_failed")
            #expect(status.shutdownFailureCount == 1)
            #expect(status.exporterFailureCount == 1)
            #expect(status.lastShutdownDuration != nil)
        }

        @Test func telemetryFailedShutdownClearsLocalActiveContext() throws {
            var faults = FaultConfig()
            faults.telemetryShutdownFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let telemetry = env.telemetry as! SimulatedTelemetry

            telemetry.configure(TelemetryConfiguration(enabled: true))
            _ = try #require(telemetry.startSpan(
                name: "active-before-failed-shutdown",
                kind: .internalSpan,
                attributes: [:],
                startTime: nil
            ))

            #expect(!telemetry.shutdown(timeout: 1))
            #expect(telemetry.status().activeSpanID == nil)

            let afterShutdown = try #require(telemetry.startSpan(
                name: "after-failed-shutdown",
                kind: .internalSpan,
                attributes: [:],
                startTime: nil
            ))
            telemetry.endSpan(id: afterShutdown, status: .ok, attributes: [:], endTime: nil)

            #expect(telemetry.spans.first { $0.name == "after-failed-shutdown" }?.parentSpanID == nil)
        }

        @Test func telemetryConfigurePreservesFailureCountsAndClearsLastResults() {
            var faults = FaultConfig()
            faults.telemetryShutdownFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let telemetry = env.telemetry as! SimulatedTelemetry

            telemetry.configure(TelemetryConfiguration(enabled: true))
            #expect(!telemetry.shutdown(timeout: 1))

            let beforeReconfigure = telemetry.status()
            #expect(beforeReconfigure.exporterFailureCount == 1)
            #expect(beforeReconfigure.shutdownFailureCount == 1)
            #expect(beforeReconfigure.lastFlushResult == "success")
            #expect(beforeReconfigure.lastShutdownResult == "failure")

            telemetry.configure(TelemetryConfiguration(enabled: true, serviceName: "reconfigured"))

            let afterReconfigure = telemetry.status()
            #expect(afterReconfigure.serviceName == "reconfigured")
            #expect(afterReconfigure.exporterFailureCount == 1)
            #expect(afterReconfigure.shutdownFailureCount == 1)
            #expect(afterReconfigure.lastExportError == nil)
            #expect(afterReconfigure.lastExporterFailureKind == nil)
            #expect(afterReconfigure.lastFlushDuration == nil)
            #expect(afterReconfigure.lastFlushResult == nil)
            #expect(afterReconfigure.lastShutdownDuration == nil)
            #expect(afterReconfigure.lastShutdownResult == nil)
        }

        @Test func telemetryUnavailableCollectorAndTimeoutReportFailureKinds() {
            var unavailableFaults = FaultConfig()
            unavailableFaults.telemetryCollectorUnavailable = true
            let unavailableHarness = SimulatorHarness(seed: 42)
            let unavailableTelemetry = unavailableHarness.createEnvironment(faults: unavailableFaults).telemetry as! SimulatedTelemetry
            unavailableTelemetry.configure(TelemetryConfiguration(enabled: true, exporter: "otlp", endpoint: "http://localhost:4318"))

            #expect(!unavailableTelemetry.flush(timeout: 1))
            #expect(unavailableTelemetry.status().lastExporterFailureKind == "collector_unavailable")

            var timeoutFaults = FaultConfig()
            timeoutFaults.telemetryExportTimeoutProbability = 1.0
            let timeoutHarness = SimulatorHarness(seed: 43)
            let timeoutTelemetry = timeoutHarness.createEnvironment(faults: timeoutFaults).telemetry as! SimulatedTelemetry
            timeoutTelemetry.configure(TelemetryConfiguration(enabled: true, exporter: "otlp", endpoint: "http://localhost:4318"))

            #expect(!timeoutTelemetry.flush(timeout: 1))
            #expect(timeoutTelemetry.status().lastExporterFailureKind == "timeout")
        }

        @Test func telemetryMalformedEndpointReportsConfigurationDiagnostic() {
            let telemetry = SimulatedTelemetry()

            telemetry.configure(TelemetryConfiguration(
                enabled: true,
                exporter: "otlp",
                endpoint: "http://[::1"
            ))

            let status = telemetry.status()
            #expect(status.lastExporterFailureKind == "invalid_endpoint")
            #expect(status.exporterFailureCount == 1)
            #expect(status.lastExportError?.contains("Invalid OTLP endpoint") == true)
        }

        @Test func telemetryBackpressureDropsBoundedRecords() {
            var faults = FaultConfig()
            faults.telemetryQueueCapacity = 1
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            let telemetry = env.telemetry as! SimulatedTelemetry

            telemetry.configure(TelemetryConfiguration(enabled: true))
            telemetry.recordLog(level: "info", message: "queued", attributes: [:], timestamp: nil)
            telemetry.recordLog(level: "info", message: "dropped", attributes: [:], timestamp: nil)

            let status = telemetry.status()
            #expect(status.logRecords == 1)
            #expect(status.droppedRecords == 1)
            #expect(status.backpressureDroppedRecords == 1)
            #expect(status.exporterFailureCount == 0)
            #expect(status.lastExporterFailureKind == nil)
            #expect(status.exporterQueueCapacity == 1)
        }

        @Test func tcpConnectionSucceeds() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            var connected = false

            let conn = env.network.createTCPConnection(host: "localhost", port: 8080) { err in
                connected = (err == nil)
            }
            #expect(connected)
            #expect(conn.isConnected)
        }

        @Test func tcpConnectionFailsUnderFault() {
            var faults = FaultConfig()
            faults.connectionFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var error: Error?

            _ = env.network.createTCPConnection(host: "localhost", port: 8080) { err in
                error = err
            }
            #expect(error != nil)
        }

        @Test func tcpSendPacketDroppedUnderFault() {
            var faults = FaultConfig()
            faults.packetDropProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)
            var sendError: Error?

            let conn = env.network.createTCPConnection(host: "localhost", port: 8080) { _ in }
            conn.send("hello".data(using: .utf8)!) { err in
                sendError = err
            }
            #expect(sendError != nil)
        }

        // MARK: - Workspace

        @Test func workspaceLaunchAndTerminate() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()

            #expect(env.workspace.launchApplication(bundleIdentifier: "com.apple.Safari"))
            #expect(env.workspace.runningApplications().count == 1)
            #expect(env.workspace.runningApplications()[0].bundleIdentifier == "com.apple.Safari")

            let pid = env.workspace.runningApplications()[0].processIdentifier
            #expect(env.workspace.terminateApplication(pid: pid))
            #expect(env.workspace.runningApplications().isEmpty)
        }

        @Test func workspaceLaunchFailsUnderFault() {
            var faults = FaultConfig()
            faults.appLaunchFailProbability = 1.0
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(!env.workspace.launchApplication(bundleIdentifier: "com.apple.Safari"))
            #expect(env.workspace.runningApplications().isEmpty)
        }

        @Test func workspaceActivateAndHide() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let ws = env.workspace as! SimulatedWorkspace

            ws.apps = [
                AppInfo(name: "Safari", bundleIdentifier: "com.apple.Safari", processIdentifier: 100),
                AppInfo(name: "Terminal", bundleIdentifier: "com.apple.Terminal", processIdentifier: 101),
            ]

            #expect(ws.activateApplication(pid: 100))
            #expect(ws.frontmostApplication()?.processIdentifier == 100)

            #expect(ws.hideApplication(pid: 100))
            #expect(ws.apps.first(where: { $0.processIdentifier == 100 })?.isHidden == true)

            #expect(ws.unhideApplication(pid: 100))
            #expect(ws.apps.first(where: { $0.processIdentifier == 100 })?.isHidden == false)
        }

        @Test func workspaceOpenURLAndFile() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let ws = env.workspace as! SimulatedWorkspace

            #expect(ws.openURL("https://spotify.com"))
            #expect(ws.openFile("/tmp/test.txt"))
            #expect(ws.openedURLs == ["https://spotify.com"])
            #expect(ws.openedFiles == ["/tmp/test.txt"])
        }

        @Test func workspaceWindowList() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let ws = env.workspace as! SimulatedWorkspace

            ws.windows = [
                WindowInfo(windowID: 1, ownerPID: 100, ownerName: "Safari", title: "Tab 1"),
                WindowInfo(windowID: 2, ownerPID: 101, ownerName: "Terminal", title: "zsh"),
            ]

            let windows = ws.windowList(options: 0)
            #expect(windows.count == 2)
            #expect(windows[0].title == "Tab 1")
        }

        // MARK: - Pasteboard

        @Test func pasteboardRoundTrip() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard

            #expect(pb.setString("hello", forType: "public.utf8-plain-text"))
            #expect(pb.string(forType: "public.utf8-plain-text") == "hello")
            #expect(pb.changeCount == 1)
        }

        @Test func pasteboardUnavailableUnderFault() {
            var faults = FaultConfig()
            faults.pasteboardUnavailable = true
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment(faults: faults)

            #expect(!env.pasteboard.setString("hello", forType: "public.utf8-plain-text"))
            #expect(env.pasteboard.string(forType: "public.utf8-plain-text") == nil)
        }

        @Test func pasteboardClearContents() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard

            _ = pb.setString("data", forType: "type1")
            pb.clearContents()
            #expect(pb.string(forType: "type1") == nil)
            #expect(pb.availableTypes().isEmpty)
        }

        @Test func pasteboardDataRoundTrip() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard

            let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
            #expect(pb.setData(data, forType: "com.test.binary"))
            #expect(pb.data(forType: "com.test.binary") == data)
        }

        @Test func pasteboardWriteObjects() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let pb = env.pasteboard

            _ = pb.setString("old", forType: "type1")
            let items: [[String: Data]] = [
                ["type2": "new".data(using: .utf8)!],
            ]
            #expect(pb.writeObjects(items))
            #expect(pb.string(forType: "type1") == nil)
            #expect(pb.string(forType: "type2") == "new")
        }

        // MARK: - Screen

        @Test func screenListAndProperties() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let scr = env.screen as! SimulatedScreen

            scr.screens = [
                ScreenInfo(id: 1, name: "Built-in"),
                ScreenInfo(id: 2, name: "External"),
            ]
            scr.mainScreenID = 1

            #expect(env.screen.allScreens().count == 2)
            #expect(env.screen.mainScreen()?.name == "Built-in")
            #expect(env.screen.primaryScreen()?.name == "Built-in")
        }

        @Test func screenRotation() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let scr = env.screen as! SimulatedScreen

            scr.screens = [ScreenInfo(id: 1, name: "Test")]
            #expect(scr.setRotation(90, forScreenID: 1))
            #expect(scr.allScreens()[0].rotation == 90)
            #expect(!scr.setRotation(90, forScreenID: 999))
        }

        @Test func screenSpaceID() {
            let harness = SimulatorHarness(seed: 42)
            let env = harness.createEnvironment()
            let scr = env.screen as! SimulatedScreen

            scr.spaceIDs = [1: 3, 2: 5]
            #expect(scr.currentSpaceID(forScreenID: 1) == 3)
            #expect(scr.currentSpaceID(forScreenID: 2) == 5)
            #expect(scr.currentSpaceID(forScreenID: 99) == nil)
        }

        // MARK: - Cross-subsystem determinism

        @Test func sameSeeedProducesSameEnvironmentBehavior() {
            func run(seed: Int64) -> (brightness: Bool, hostname: String, fileExists: Bool) {
                let harness = SimulatorHarness(seed: seed)
                let env = harness.createEnvironment()
                let bright = env.screen.setBrightness(50, forScreenID: 1)
                let host = env.systemInfo.hostname()
                let exists = env.fileSystem.fileExists(atPath: "/nonexistent")
                return (bright, host, exists)
            }

            let r1 = run(seed: 42)
            let r2 = run(seed: 42)
            #expect(r1.brightness == r2.brightness)
            #expect(r1.hostname == r2.hostname)
            #expect(r1.fileExists == r2.fileExists)
        }

        // MARK: - Swarm

        @Test func swarmFaultConfigDoesNotCrash() {
            var rng = RPRNG(seed: 99)
            let faults = FaultConfig.swarm(rng: &rng)
            withLuaState(faults: faults) { L in
                _ = luaopen_hs_libbrightness(L)
                lua_setglobal(L, "brightness")

                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settings")

                _ = luaEval(L, "brightness.get()")
                _ = luaEval(L, "brightness.set(50)")
                _ = luaEval(L, "settings.set('k', 'v')")
                _ = luaEval(L, "settings.get('k')")
            }
        }

        @Test func swarmMultipleSeedsNocrash() {
            for seed: Int64 in [0, 1, 42, 999, 12345, Int64.max] {
                var rng = RPRNG(seed: seed)
                let faults = FaultConfig.swarm(rng: &rng)
                let harness = SimulatorHarness(seed: seed)
                let env = harness.createEnvironment(faults: faults)

                _ = env.systemInfo.batteryInfo()
                _ = env.systemInfo.wifiInfo()
                _ = env.systemInfo.hostname()
                _ = env.screen.allScreens()
                _ = env.screen.setBrightness(50, forScreenID: 1)
                _ = env.location.currentLocation()
                _ = env.fileSystem.fileExists(atPath: "/tmp")
                env.notification.post(name: "test", object: nil, userInfo: nil)
            }
        }

        @Test func swarmFaultConfigIsReproducible() {
            var rng1 = RPRNG(seed: 77)
            var rng2 = RPRNG(seed: 77)
            let f1 = FaultConfig.swarm(rng: &rng1)
            let f2 = FaultConfig.swarm(rng: &rng2)

            #expect(f1.fileReadFailProbability == f2.fileReadFailProbability)
            #expect(f1.connectionFailProbability == f2.connectionFailProbability)
            #expect(f1.batteryUnavailable == f2.batteryUnavailable)
            #expect(f1.locationPermissionDenied == f2.locationPermissionDenied)
        }
    }

    // MARK: - Lua-level integration tests (Lua API → Swift → SimulatedX)

    @Suite("DST Lua Integration") final class DSTLuaIntegrationTests {

        // MARK: - hs.host

        @Test func hostAddressesReturnsList() {
            withLuaState { L in
                _ = luaopen_hs_libhost(L)
                lua_setglobal(L, "host")

                let result = luaEvalString(L, "return host.addresses()[1]")
                #expect(result == "192.168.1.100")
            }
        }

        @Test func hostThermalState() {
            withLuaState { L in
                _ = luaopen_hs_libhost(L)
                lua_setglobal(L, "host")

                let result = luaEvalString(L, "return host.thermalState()")
                #expect(result == "nominal")
            }
        }

        @Test func hostOSVersion() {
            withLuaState { L in
                _ = luaopen_hs_libhost(L)
                lua_setglobal(L, "host")

                let major = luaEvalInt(L, "return host.operatingSystemVersion().major")
                #expect(major == 26)
            }
        }

        // MARK: - hs.battery

        @Test func batteryTimeRemaining() {
            withLuaState { L in
                _ = luaopen_hs_libbattery(L)
                lua_setglobal(L, "battery")

                let result = luaEvalNumber(L, "return battery.timeRemaining()")
                #expect(result != nil)
            }
        }

        @Test func batteryPowerSource() {
            withLuaState { L in
                _ = luaopen_hs_libbattery(L)
                lua_setglobal(L, "battery")

                let result = luaEvalString(L, "return battery.powerSource()")
                #expect(result == "AC Power")
            }
        }

        @Test func batteryUnavailableReturnsFallback() {
            var faults = FaultConfig()
            faults.batteryUnavailable = true
            withLuaState(faults: faults) { L in
                _ = luaopen_hs_libbattery(L)
                lua_setglobal(L, "battery")

                let result = luaEvalNumber(L, "return battery.timeRemaining()")
                #expect(result == -2)
            }
        }

        // MARK: - hs.settings (Lua-level)

        @Test func settingsLuaRoundTrip() {
            withLuaState { L in
                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settings")

                #expect(luaEval(L, "settings.set('number', 42)"))
                let result = luaEvalInt(L, "return settings.get('number')")
                #expect(result == 42)

                #expect(luaEval(L, "settings.set('flag', true)"))
                let flag = luaEvalBool(L, "return settings.get('flag')")
                #expect(flag == true)
            }
        }

        @Test func settingsLuaClear() {
            withLuaState { L in
                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settings")

                #expect(luaEval(L, "settings.set('temp', 'value')"))
                #expect(luaEval(L, "settings.clear('temp')"))
                let result = luaEvalString(L, "return type(settings.get('temp'))")
                #expect(result == "nil")
            }
        }

        @Test func settingsLuaGetKeys() {
            withLuaState { L in
                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settings")

                #expect(luaEval(L, "settings.set('aaa', 1)"))
                #expect(luaEval(L, "settings.set('bbb', 2)"))
                let count = luaEvalInt(L, "return #settings.getKeys()")
                #expect(count == 2)
            }
        }

        // MARK: - hs.brightness (Lua-level)

        @Test func brightnessLuaGetSet() {
            withLuaState { L in
                _ = luaopen_hs_libbrightness(L)
                lua_setglobal(L, "brightness")

                #expect(luaEvalBool(L, "return brightness.set(75)") == true)
                #expect(luaEvalInt(L, "return brightness.get()") == 75)
            }
        }

        @Test func brightnessLuaFault() {
            var faults = FaultConfig()
            faults.brightnessSetFailProbability = 1.0
            withLuaState(faults: faults) { L in
                _ = luaopen_hs_libbrightness(L)
                lua_setglobal(L, "brightness")

                #expect(luaEvalBool(L, "return brightness.set(50)") == false)
            }
        }

        // MARK: - hs.json (Lua-level)

        @Test func jsonEncodeDecode() {
            withLuaState { L in
                _ = luaopen_hs_libjson(L)
                lua_setglobal(L, "json")

                let encoded = luaEvalString(L, "return json.encode({a=1, b='hello'})")
                #expect(encoded != nil)
                #expect(encoded!.contains("hello"))
            }
        }

        @Test func jsonDecodeRoundTrip() {
            withLuaState { L in
                _ = luaopen_hs_libjson(L)
                lua_setglobal(L, "json")

                let val = luaEvalInt(L, """
                    local t = json.decode('{"x": 42}')
                    return t.x
                """)
                #expect(val == 42)
            }
        }

        // MARK: - hs.hash (Lua-level)

        @Test func hashSHA256() {
            withLuaState { L in
                _ = luaopen_hs_libhash(L)
                lua_setglobal(L, "hash")

                let result = luaEvalString(L, """
                    return hash.new("SHA256"):append("hello"):finish():value()
                """)
                #expect(result == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
            }
        }

        @Test func hashMD5() {
            withLuaState { L in
                _ = luaopen_hs_libhash(L)
                lua_setglobal(L, "hash")

                let result = luaEvalString(L, """
                    return hash.new("MD5"):append("hello"):finish():value()
                """)
                #expect(result == "5d41402abc4b2a76b9719d911017c592")
            }
        }

        // MARK: - hs.plist (Lua-level)

        @Test func plistReadWrite() {
            withLuaState { L in
                _ = luaopen_hs_libplist(L)
                lua_setglobal(L, "plist")

                let data = luaEvalString(L, """
                    return plist.writeString({name="test", value=42})
                """)
                #expect(data != nil)
                #expect(data!.contains("test"))
            }
        }

        @Test func plistDecodeRoundTrip() {
            withLuaState { L in
                _ = luaopen_hs_libplist(L)
                lua_setglobal(L, "plist")

                let val = luaEvalString(L, """
                    local xml = plist.writeString({greeting="hello"})
                    local t = plist.readString(xml)
                    return t.greeting
                """)
                #expect(val == "hello")
            }
        }

        // MARK: - hs.host.locale (Lua-level)

        @Test func hostLocaleCurrentLocale() {
            withLuaState { L in
                _ = luaopen_hs_libhost_locale(L)
                lua_setglobal(L, "locale")

                let result = luaEvalString(L, "return locale.current()")
                #expect(result != nil)
            }
        }

        // MARK: - Cross-module Lua integration

        @Test func multiModuleSwarmExercise() {
            var rng = RPRNG(seed: 42)
            let faults = FaultConfig.swarm(rng: &rng)
            withLuaState(faults: faults) { L in
                _ = luaopen_hs_libbrightness(L)
                lua_setglobal(L, "brightness")
                _ = luaopen_hs_libsettings(L)
                lua_setglobal(L, "settings")
                _ = luaopen_hs_libhost(L)
                lua_setglobal(L, "host")
                _ = luaopen_hs_libjson(L)
                lua_setglobal(L, "json")
                _ = luaopen_hs_libhash(L)
                lua_setglobal(L, "hash")
                _ = luaopen_hs_libbattery(L)
                lua_setglobal(L, "battery")

                _ = luaEval(L, "brightness.get()")
                _ = luaEval(L, "brightness.set(50)")
                _ = luaEval(L, "settings.set('k', 'v')")
                _ = luaEval(L, "settings.get('k')")
                _ = luaEval(L, "host.addresses()")
                _ = luaEval(L, "host.thermalState()")
                _ = luaEval(L, "json.encode({a=1})")
                _ = luaEval(L, "json.decode('{}')")
                _ = luaEval(L, "hash.SHA256('test')")
                _ = luaEval(L, "battery.timeRemaining()")
                _ = luaEval(L, "battery.powerSource()")
            }
        }
    }
}
