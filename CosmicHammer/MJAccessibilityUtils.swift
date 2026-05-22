import ApplicationServices

@_cdecl("MJAccessibilityIsEnabled")
func MJAccessibilityIsEnabled() -> Bool {
    let isEnabled = AXIsProcessTrusted()
    NSLog("Accessibility is: %@", isEnabled ? "ENABLED" : "DISABLED")
    return isEnabled
}

@_cdecl("MJAccessibilityOpenPanel")
func MJAccessibilityOpenPanel() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}
