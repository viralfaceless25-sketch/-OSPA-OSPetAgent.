@preconcurrency import ApplicationServices
import Foundation

/// Only checks or prompts for macOS trust. It never reads UI or generates events.
struct AccessibilityPermissionController {
    func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Must be called directly from a user action.
    func requestFromUser() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
