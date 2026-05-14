import Cocoa

/// Check whether the app has Accessibility permissions enabled.
@_cdecl("MJAccessibilityIsEnabled")
func MJAccessibilityIsEnabled() -> Bool {
    let isEnabled = AXIsProcessTrusted()
    NSLog("Accessibility is: %@", isEnabled ? "ENABLED" : "DISABLED")
    return isEnabled
}

/// Prompt the user to grant Accessibility permissions.
@_cdecl("MJAccessibilityOpenPanel")
func MJAccessibilityOpenPanel() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}
