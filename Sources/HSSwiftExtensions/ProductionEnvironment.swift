import Foundation
import HSDSTCore

public func createProductionEnvironment() -> Environment {
    Environment(
        runtime: .init(
            clock: ProductionClock(),
            eventLoop: ProductionEventLoop(),
            fileSystem: ProductionFileSystem(),
            settings: ProductionSettings(),
            systemInfo: ProductionSystemInfo(),
            process: ProductionProcess(),
            telemetry: ProductionTelemetry()
        ),
        userInterface: .init(
            workspace: ProductionWorkspace(),
            pasteboard: ProductionPasteboard(),
            screen: ProductionScreen(),
            window: ProductionWindow(),
            accessibility: ProductionAccessibility(),
            input: ProductionInput(),
            spaces: ProductionSpaces(),
            webView: ProductionWebView(),
            dialog: ProductionDialog(),
            statusBar: ProductionStatusBar(),
            drawing: ProductionDrawing(),
            application: ProductionApplication()
        ),
        services: .init(
            network: ProductionNetwork(),
            location: ProductionLocation(),
            notification: ProductionNotification(),
            audio: ProductionAudio(),
            socket: ProductionSocket(),
            speech: ProductionSpeech(),
            automation: ProductionAutomation(),
            fileWatching: ProductionFileWatching(),
            device: ProductionDevice(),
            camera: ProductionCamera(),
            search: ProductionSearch(),
            loginItem: ProductionLoginItem(),
            bonjour: ProductionBonjour(),
            certificate: ProductionCertificate(),
            media: ProductionMedia()
        )
    )
}
