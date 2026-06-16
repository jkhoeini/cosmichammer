import Foundation

public struct DialogResult: Sendable {
    public var buttonPressed: String
    public var selectedFiles: [String]?
    public var textInput: String?

    public init(buttonPressed: String = "OK", selectedFiles: [String]? = nil,
                textInput: String? = nil) {
        self.buttonPressed = buttonPressed
        self.selectedFiles = selectedFiles
        self.textInput = textInput
    }
}

public struct DialogConfig: Sendable {
    public var message: String?
    public var informativeText: String?
    public var buttons: [String]
    public var defaultButton: Int?
    public var canChooseFiles: Bool
    public var canChooseDirectories: Bool
    public var allowsMultipleSelection: Bool
    public var allowedFileTypes: [String]?
    public var initialDirectory: String?
    public var defaultFilename: String?
    public var hasTextInput: Bool
    public var textInputDefaultValue: String?

    public init(message: String? = nil, informativeText: String? = nil,
                buttons: [String] = ["OK"], defaultButton: Int? = nil,
                canChooseFiles: Bool = true, canChooseDirectories: Bool = false,
                allowsMultipleSelection: Bool = false, allowedFileTypes: [String]? = nil,
                initialDirectory: String? = nil, defaultFilename: String? = nil,
                hasTextInput: Bool = false, textInputDefaultValue: String? = nil) {
        self.message = message
        self.informativeText = informativeText
        self.buttons = buttons
        self.defaultButton = defaultButton
        self.canChooseFiles = canChooseFiles
        self.canChooseDirectories = canChooseDirectories
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowedFileTypes = allowedFileTypes
        self.initialDirectory = initialDirectory
        self.defaultFilename = defaultFilename
        self.hasTextInput = hasTextInput
        self.textInputDefaultValue = textInputDefaultValue
    }
}

public protocol DialogProtocol: AnyObject {
    func showAlert(config: DialogConfig) -> DialogResult
    func showOpenPanel(config: DialogConfig) -> DialogResult
    func showSavePanel(config: DialogConfig) -> String?
    func showColorPanel(initialColor: (red: Double, green: Double, blue: Double, alpha: Double)?) -> (red: Double, green: Double, blue: Double, alpha: Double)?
    func showTextInput(message: String, defaultValue: String?, informativeText: String?) -> String?
}
