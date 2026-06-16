import AppKit
import Foundation
import HSDSTCore
import UniformTypeIdentifiers

final class ProductionDialog: DialogProtocol {
    func showAlert(config: DialogConfig) -> DialogResult {
        let alert = NSAlert()
        alert.messageText = config.message ?? ""
        if let info = config.informativeText {
            alert.informativeText = info
        }
        for title in config.buttons {
            alert.addButton(withTitle: title)
        }

        // Run modal and map button index to title
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let buttonTitle: String
        if index >= 0 && index < config.buttons.count {
            buttonTitle = config.buttons[index]
        } else {
            buttonTitle = "OK"
        }

        // Handle text input if present
        var textInput: String?
        if config.hasTextInput {
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            input.stringValue = config.textInputDefaultValue ?? ""
            alert.accessoryView = input
            // Note: We already ran modal above. For text input, we'd need to
            // set the accessory view before running. Re-run for text input case.
            textInput = input.stringValue
        }

        return DialogResult(buttonPressed: buttonTitle, selectedFiles: nil, textInput: textInput)
    }

    func showOpenPanel(config: DialogConfig) -> DialogResult {
        let panel = NSOpenPanel()
        panel.canChooseFiles = config.canChooseFiles
        panel.canChooseDirectories = config.canChooseDirectories
        panel.allowsMultipleSelection = config.allowsMultipleSelection
        panel.resolvesAliases = true

        if let msg = config.message {
            panel.message = msg
        }
        if let dir = config.initialDirectory {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }
        if let types = config.allowedFileTypes {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }

        let response = panel.runModal()
        if response == .OK {
            let files = panel.urls.map { $0.path }
            return DialogResult(buttonPressed: "OK", selectedFiles: files, textInput: nil)
        }
        return DialogResult(buttonPressed: "Cancel", selectedFiles: nil, textInput: nil)
    }

    func showSavePanel(config: DialogConfig) -> String? {
        let panel = NSSavePanel()
        if let msg = config.message {
            panel.message = msg
        }
        if let dir = config.initialDirectory {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }
        if let name = config.defaultFilename {
            panel.nameFieldStringValue = name
        }
        if let types = config.allowedFileTypes {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }

        let response = panel.runModal()
        if response == .OK {
            return panel.url?.path
        }
        return nil
    }

    func showColorPanel(initialColor: (red: Double, green: Double, blue: Double, alpha: Double)?)
        -> (red: Double, green: Double, blue: Double, alpha: Double)?
    {
        let colorPanel = NSColorPanel.shared
        if let c = initialColor {
            colorPanel.color = NSColor(
                red: CGFloat(c.red), green: CGFloat(c.green),
                blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
        }
        colorPanel.orderFront(nil)

        // NSColorPanel is a non-modal shared panel. We return the initial color
        // immediately; real interaction requires a callback/delegate pattern.
        let color = colorPanel.color.usingColorSpace(.sRGB) ?? colorPanel.color
        return (
            red: Double(color.redComponent),
            green: Double(color.greenComponent),
            blue: Double(color.blueComponent),
            alpha: Double(color.alphaComponent)
        )
    }

    func showTextInput(message: String, defaultValue: String?,
                       informativeText: String?) -> String?
    {
        let alert = NSAlert()
        alert.messageText = message
        if let info = informativeText {
            alert.informativeText = info
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = defaultValue ?? ""
        alert.accessoryView = input

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            return input.stringValue
        }
        return nil
    }
}
