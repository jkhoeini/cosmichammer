import Testing
import HSDSTSimulator

extension CosmicHammerTests {
    @Suite("DST LaunchServices Simulator") final class DSTLaunchServicesTests {
        private let cosmicHammerBundleID = "org.cosmic-hammer.CosmicHammer"

        @Test func urlOpenDeliversToRegisteredURLHandler() {
            let simulator = SimulatedLaunchServices(seedSystemDefaults: false)
            var deliveredURLs: [String] = []

            simulator.setDefaultURLHandler(cosmicHammerBundleID, forScheme: "https")
            simulator.registerURLHandler(bundleIdentifier: cosmicHammerBundleID) { url in
                deliveredURLs.append(url)
            }

            #expect(simulator.openURL("https://example.com/path?q=1"))
            #expect(deliveredURLs == ["https://example.com/path?q=1"])
            #expect(simulator.deliveryLog == [
                SimulatedLaunchServices.DeliveryLogEntry(
                    payload: .url("https://example.com/path?q=1"),
                    outcome: .deliveredToURLHandler(bundleIdentifier: cosmicHammerBundleID)
                ),
            ])
        }

        @Test func documentOpenDeliversFileSystemPathToRegisteredFileHandler() {
            let simulator = SimulatedLaunchServices(seedSystemDefaults: false)
            var deliveredPaths: [String] = []

            simulator.setDefaultDocumentHandler(cosmicHammerBundleID, forFileExtension: "html")
            simulator.registerFileHandler(bundleIdentifier: cosmicHammerBundleID) { path in
                deliveredPaths.append(path)
            }

            #expect(simulator.openFile("/tmp/index.html"))
            #expect(deliveredPaths == ["/tmp/index.html"])
            #expect(deliveredPaths.first?.hasPrefix("file://") == false)
            #expect(simulator.deliveryLog == [
                SimulatedLaunchServices.DeliveryLogEntry(
                    payload: .filePath("/tmp/index.html"),
                    outcome: .deliveredToFileHandler(bundleIdentifier: cosmicHammerBundleID)
                ),
            ])
        }

        @Test func unregisteredDefaultHandlerRecordsExternalOpen() {
            let simulator = SimulatedLaunchServices(seedSystemDefaults: false)

            simulator.setDefaultURLHandler("com.apple.Safari", forScheme: "http")

            #expect(simulator.openURL("http://example.com"))
            #expect(simulator.deliveryLog == [
                SimulatedLaunchServices.DeliveryLogEntry(
                    payload: .url("http://example.com"),
                    outcome: .externalOpen(bundleIdentifier: "com.apple.Safari")
                ),
            ])
        }

        @Test func missingDefaultHandlerRecordsNoHandler() {
            let simulator = SimulatedLaunchServices(seedSystemDefaults: false)

            #expect(simulator.openFile("/tmp/archive.zip") == false)
            #expect(simulator.deliveryLog == [
                SimulatedLaunchServices.DeliveryLogEntry(
                    payload: .filePath("/tmp/archive.zip"),
                    outcome: .noHandler
                ),
            ])
        }

        @Test func workspaceOpenUsesLaunchServicesSimulator() {
            let harness = SimulatorHarness(seed: 42)
            let workspace = harness.createEnvironment().workspace as! SimulatedWorkspace
            var deliveredURLs: [String] = []

            workspace.launchServices.setDefaultURLHandler(cosmicHammerBundleID, forScheme: "https")
            workspace.launchServices.registerURLHandler(bundleIdentifier: cosmicHammerBundleID) { url in
                deliveredURLs.append(url)
            }

            #expect(workspace.openURL("https://example.com/from-workspace"))
            #expect(workspace.openedURLs == ["https://example.com/from-workspace"])
            #expect(deliveredURLs == ["https://example.com/from-workspace"])
        }
    }
}
