@preconcurrency import ApplicationServices
import AppKit
import AvatarCore
import CoreGraphics
import Foundation

/// Live environment probe backed by AppKit + Accessibility. Emergency-stop is
/// injected because it lives in the app's SafetyState, not the OS.
@MainActor
public final class SystemForegroundEnvironmentProbe: ForegroundEnvironmentProbe {
    private let frontmostBundleIdentifier: @MainActor () -> String?
    private let accessibilityTrusted: @MainActor () -> Bool
    private let isEmergencyStopped: @MainActor () -> Bool

    public init(
        isEmergencyStopped: @MainActor @escaping () -> Bool,
        frontmostBundleIdentifier: @MainActor @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        accessibilityTrusted: @MainActor @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.isEmergencyStopped = isEmergencyStopped
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.accessibilityTrusted = accessibilityTrusted
    }

    public func currentContext(now: Date) -> ExecutionContext {
        ExecutionContext(
            frontmostBundleIdentifier: frontmostBundleIdentifier(),
            accessibilityPermissionGranted: accessibilityTrusted(),
            emergencyStopped: isEmergencyStopped(),
            now: now
        )
    }
}

/// Presses a UI element found by role + exact label via `AXUIElementPerformAction`.
/// No coordinates are ever computed.
@MainActor
public final class SystemAccessibilityActionPerformer: AccessibilityActionPerformer {
    private let processIdentifier: (String) -> pid_t?
    private let maximumVisitedElements: Int
    private let maximumDepth: Int

    public init(
        maximumVisitedElements: Int = 600,
        maximumDepth: Int = 16,
        processIdentifier: @escaping (String) -> pid_t? = { bundleIdentifier in
            NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first?
                .processIdentifier
        }
    ) {
        self.maximumVisitedElements = maximumVisitedElements
        self.maximumDepth = maximumDepth
        self.processIdentifier = processIdentifier
    }

    public func press(
        role: String,
        label: String,
        inBundleIdentifier bundleIdentifier: String
    ) -> ForegroundInputResult {
        guard AXIsProcessTrusted() else {
            return .failed("macOS Accessibility permission is not granted.")
        }
        guard let pid = processIdentifier(bundleIdentifier) else {
            return .failed("Couldn't find that app running.")
        }

        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)

        guard let element = findElement(application, role: role, label: label) else {
            return .failed("Couldn't find that button on screen.")
        }
        guard actionNames(element).contains(kAXPressAction as String) else {
            return .failed("That control can't be pressed.")
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        else {
            return .failed("macOS wouldn't let me press that button.")
        }
        return .performed
    }

    private func findElement(
        _ root: AXUIElement,
        role: String,
        label: String
    ) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var index = 0
        var visited = 0

        while index < queue.count, visited < maximumVisitedElements {
            let current = queue[index]
            index += 1
            visited += 1

            if attributeString(current.element, kAXRoleAttribute as CFString) == role {
                let elementLabel =
                    attributeString(current.element, kAXTitleAttribute as CFString)
                    ?? attributeString(current.element, kAXDescriptionAttribute as CFString)
                if Self.normalized(elementLabel) == Self.normalized(label) {
                    return current.element
                }
            }

            guard current.depth < maximumDepth else { continue }
            let remaining = maximumVisitedElements - visited
            guard remaining > 0 else { continue }
            let children = childElements(current.element, limit: remaining)
            queue.append(contentsOf: children.map { ($0, current.depth + 1) })
        }
        return nil
    }

    /// Matches the inspection redactor's label normalization so a plan built
    /// from a sanitized snapshot ("Play") still resolves the live element
    /// whatever its casing or internal spacing ("play", "  PLAY ").
    static func normalized(_ label: String?) -> String? {
        guard let label else { return nil }
        let value =
            label
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return value.isEmpty ? nil : value
    }

    private func attributeString(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute, &value) == .success
        else {
            return nil
        }
        return value as? String
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard
            AXUIElementCopyActionNames(element, &names) == .success,
            let names
        else {
            return []
        }
        return names as? [String] ?? []
    }

    private func childElements(
        _ element: AXUIElement,
        limit: Int
    ) -> [AXUIElement] {
        var count = 0
        guard
            AXUIElementGetAttributeValueCount(
                element,
                kAXChildrenAttribute as CFString,
                &count
            ) == .success,
            count > 0
        else {
            return []
        }

        let requested = min(count, limit)
        var values: CFArray?
        guard
            AXUIElementCopyAttributeValues(
                element,
                kAXChildrenAttribute as CFString,
                0,
                requested,
                &values
            ) == .success,
            let values
        else {
            return []
        }
        return values as? [AXUIElement] ?? []
    }
}

/// Posts a bounded keyboard chord to the frontmost app via CGEvent. This is the
/// only path that synthesizes HID input; the key set is a closed allowlist.
@MainActor
public final class SystemKeyboardShortcutPerformer: KeyboardShortcutPerformer {
    public init() {}

    public func post(
        key: String,
        modifiers: Set<ModifierKey>,
        toBundleIdentifier bundleIdentifier: String
    ) -> ForegroundInputResult {
        guard AXIsProcessTrusted() else {
            return .failed("macOS Accessibility permission is not granted.")
        }
        guard let keyCode = Self.keyCode(for: key) else {
            return .failed("I don't know that key.")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("macOS wouldn't let me use the keyboard.")
        }
        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode,
                keyDown: false
            )
        else {
            return .failed("macOS wouldn't let me use the keyboard.")
        }

        let flags = Self.flags(for: modifiers)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return .performed
    }

    private static func flags(for modifiers: Set<ModifierKey>) -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case .command: flags.insert(.maskCommand)
            case .option: flags.insert(.maskAlternate)
            case .control: flags.insert(.maskControl)
            case .shift: flags.insert(.maskShift)
            }
        }
        return flags
    }

    private static func keyCode(for key: String) -> CGKeyCode? {
        keyCodes[key.lowercased()]
    }

    /// ANSI virtual key codes (HIToolbox layout). Closed, bounded allowlist.
    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
        "delete": 0x33, "escape": 0x35, "esc": 0x35,
    ]
}

/// Brings the exact target application forward, launching it first when it is
/// not already running. Reuses the existing native workspace so behavior matches
/// native app launch/switch.
@MainActor
public final class SystemForegroundActivationPerformer: ForegroundActivationPerformer {
    private let workspace: any NativeApplicationWorkspace
    private let applicationURL: (String) -> URL?

    public init(
        workspace: any NativeApplicationWorkspace = SystemNativeApplicationWorkspace(),
        applicationURL: @escaping (String) -> URL? = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        }
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
    }

    public func activate(bundleIdentifier: String) async -> ForegroundInputResult {
        if case .succeeded = workspace.activateRunningApplication(
            bundleIdentifier: bundleIdentifier
        ) {
            return .performed
        }
        guard let url = applicationURL(bundleIdentifier) else {
            return .failed("Couldn't find that app on this Mac.")
        }
        return await withCheckedContinuation { continuation in
            workspace.launchApplication(at: url) { result in
                switch result {
                case .succeeded:
                    continuation.resume(returning: .performed)
                case let .failed(reason):
                    continuation.resume(returning: .failed(reason))
                }
            }
        }
    }
}
