import ApplicationServices
import os.log

@_cdecl("MJAccessibilityIsEnabled")
func MJAccessibilityIsEnabled() -> Bool {
    let isEnabled = AXIsProcessTrusted()
    os_log(.info, "Accessibility is: %{public}s", isEnabled ? "ENABLED" : "DISABLED")
    return isEnabled
}

@_cdecl("MJAccessibilityOpenPanel")
func MJAccessibilityOpenPanel() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    AXIsProcessTrustedWithOptions(options)
}
