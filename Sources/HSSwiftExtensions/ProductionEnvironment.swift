import Foundation
import HSDSTCore

func createProductionEnvironment() -> Environment {
    Environment(
        clock: ProductionClock(),
        eventLoop: ProductionEventLoop(),
        fileSystem: ProductionFileSystem(),
        network: ProductionNetwork(),
        workspace: ProductionWorkspace(),
        pasteboard: ProductionPasteboard(),
        settings: ProductionSettings(),
        screen: ProductionScreen(),
        systemInfo: ProductionSystemInfo(),
        location: ProductionLocation(),
        notification: ProductionNotification(),
        process: ProductionProcess(),
        window: ProductionWindow(),
        accessibility: ProductionAccessibility(),
        input: ProductionInput(),
        audio: ProductionAudio(),
        socket: ProductionSocket(),
        speech: ProductionSpeech(),
        spaces: ProductionSpaces(),
        webView: ProductionWebView(),
        automation: ProductionAutomation(),
        fileWatching: ProductionFileWatching(),
        device: ProductionDevice(),
        camera: ProductionCamera(),
        search: ProductionSearch(),
        loginItem: ProductionLoginItem(),
        dialog: ProductionDialog(),
        statusBar: ProductionStatusBar(),
        bonjour: ProductionBonjour(),
        drawing: ProductionDrawing(),
        certificate: ProductionCertificate(),
        media: ProductionMedia()
    )
}
