import Foundation
import Testing
import HSDSTSimulator
@testable import HSSwiftExtensions

extension CosmicHammerTests {
    @Suite("DST File Open URL Handling") final class DSTFileOpenURLHandlingTests {
        private let cosmicHammerBundleID = "org.cosmic-hammer.CosmicHammer"
        private let urlEventDocumentExtensions = ["html", "htm", "shtml", "jhtml", "xhtml", "xht", "xhtm", "txt", "text", "url"]

        @Test func httpsOpenReachesURLCallbackThroughSimulator() {
            let harness = makeURLHandlingHarness()

            #expect(harness.workspace.openURL("https://google.com"))
            #expect(harness.callback.receivedFullURLs == ["https://google.com"])
        }

        @Test func htmlFileOpenReachesURLCallbackAsFileURLThroughSimulator() {
            let harness = makeURLHandlingHarness()
            let path = "/Users/mohammadk/src/simple-html/index.html"

            #expect(harness.workspace.openFile(path))
            #expect(harness.workspace.openedFiles == [path])
            #expect(harness.callback.receivedFullURLs == [expectedFileURL(for: path)])
        }

        @Test func htmlFileOpenWithSpacesAndHashReachesURLCallbackAsEncodedFileURL() {
            let harness = makeURLHandlingHarness()
            let path = "/tmp/Cosmic Hammer/url chooser #1.html"

            #expect(harness.workspace.openFile(path))
            #expect(harness.callback.receivedFullURLs == [expectedFileURL(for: path)])
        }

        @Test func multipleHTMLFileOpensReachURLCallbackInOrder() {
            let harness = makeURLHandlingHarness()
            let paths = [
                "/tmp/Cosmic Hammer/first.html",
                "/tmp/Cosmic Hammer/second #2.html",
            ]

            for path in paths {
                #expect(harness.workspace.openFile(path))
            }

            #expect(harness.workspace.openedFiles == paths)
            #expect(harness.callback.receivedFullURLs == paths.map { expectedFileURL(for: $0) })
        }

        @Test func uppercaseHTMLFileOpenReachesURLCallback() {
            let harness = makeURLHandlingHarness()
            let path = "/tmp/Cosmic Hammer/LOGIN.HTML"

            #expect(harness.workspace.openFile(path))
            #expect(harness.callback.receivedFullURLs == [expectedFileURL(for: path)])
        }

        @Test func jhtmlFileOpenReachesURLCallbackAsHTMLDocument() {
            let harness = makeURLHandlingHarness()
            let path = "/tmp/Cosmic Hammer/legacy-login.jhtml"

            #expect(harness.workspace.openFile(path))
            #expect(harness.callback.receivedFullURLs == [expectedFileURL(for: path)])
        }

        @Test func unsupportedDocumentExtensionDoesNotReachURLCallback() {
            let harness = makeURLHandlingHarness()

            #expect(harness.workspace.openFile("/tmp/archive.zip") == false)
            #expect(harness.callback.receivedFullURLs.isEmpty)
        }

        @Test func appDelegateURLAccessConformanceWiresFileDelegate() {
            let appDelegate = MJAppDelegate()
            let callback = SimulatedURLEventCallback()
            let fileDelegate = SimulatedOpenFileDelegate(callback: callback)
            let appDelegateURLAccess: any HSAppDelegateURLAccess = appDelegate
            let path = "/tmp/index.html"

            appDelegateURLAccess.openFileDelegate = fileDelegate

            #expect(appDelegate.handleOpenedFile(path, supportedExtensions: urlEventDocumentExtensions) == .deliveredToURLEvent)
            #expect(callback.receivedFullURLs == [expectedFileURL(for: path)])
        }

        private func makeURLHandlingHarness() -> (
            workspace: SimulatedWorkspace,
            callback: SimulatedURLEventCallback,
            appDelegate: MJAppDelegate,
            fileDelegate: SimulatedOpenFileDelegate
        ) {
            let simulatorHarness = SimulatorHarness(seed: 42)
            let workspace = simulatorHarness.createEnvironment().workspace as! SimulatedWorkspace
            let callback = SimulatedURLEventCallback()
            let appDelegate = MJAppDelegate()
            let fileDelegate = SimulatedOpenFileDelegate(callback: callback)
            let appDelegateURLAccess: any HSAppDelegateURLAccess = appDelegate

            appDelegateURLAccess.openFileDelegate = fileDelegate

            workspace.launchServices.setDefaultURLHandler(cosmicHammerBundleID, forScheme: "http")
            workspace.launchServices.setDefaultURLHandler(cosmicHammerBundleID, forScheme: "https")
            workspace.launchServices.setDefaultDocumentHandler(cosmicHammerBundleID, forFileExtension: "html")
            workspace.launchServices.setDefaultDocumentHandler(cosmicHammerBundleID, forFileExtension: "jhtml")
            workspace.launchServices.registerURLHandler(bundleIdentifier: cosmicHammerBundleID) { rawURL in
                callback.receive(rawURL)
            }
            workspace.launchServices.registerFileHandler(bundleIdentifier: cosmicHammerBundleID) { path in
                appDelegate.handleOpenedFile(path, supportedExtensions: self.urlEventDocumentExtensions)
            }

            return (workspace, callback, appDelegate, fileDelegate)
        }

        private func expectedFileURL(for path: String) -> String {
            URL(fileURLWithPath: path).absoluteString
        }
    }
}

private final class SimulatedURLEventCallback {
    private(set) var receivedFullURLs: [String] = []

    func receive(_ rawURL: String) {
        guard let parsed = parseURLEvent(rawURL) else { return }
        receivedFullURLs.append(parsed.fullURL)
    }
}

private final class SimulatedOpenFileDelegate: NSObject, HSOpenFileDelegate {
    private let callback: SimulatedURLEventCallback

    init(callback: SimulatedURLEventCallback) {
        self.callback = callback
    }

    func callback(withURL openUrl: String, senderPID pid: pid_t) {
        callback.receive(openUrl)
    }
}
