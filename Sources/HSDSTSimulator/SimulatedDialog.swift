import Foundation
import HSDSTCore

public final class SimulatedDialog: DialogProtocol {
    private var rng: RPRNG
    private let faults: FaultConfig

    public var alertResult: DialogResult = DialogResult()
    public var openPanelResult: DialogResult = DialogResult()
    public var savePanelResult: String?
    public var colorPanelResult: (red: Double, green: Double, blue: Double, alpha: Double)?
    public var textInputResult: String?
    public var shownDialogs: [DialogConfig] = []

    public init(rng: RPRNG, faults: FaultConfig) {
        self.rng = rng
        self.faults = faults
    }

    public func showAlert(config: DialogConfig) -> DialogResult {
        shownDialogs.append(config)
        return alertResult
    }

    public func showOpenPanel(config: DialogConfig) -> DialogResult {
        shownDialogs.append(config)
        return openPanelResult
    }

    public func showSavePanel(config: DialogConfig) -> String? {
        shownDialogs.append(config)
        return savePanelResult
    }

    public func showColorPanel(initialColor: (red: Double, green: Double, blue: Double, alpha: Double)?) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        colorPanelResult
    }

    public func showTextInput(message: String, defaultValue: String?, informativeText: String?) -> String? {
        let config = DialogConfig(
            message: message,
            informativeText: informativeText,
            hasTextInput: true,
            textInputDefaultValue: defaultValue
        )
        shownDialogs.append(config)
        return textInputResult
    }
}
