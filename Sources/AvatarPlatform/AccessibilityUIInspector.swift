@preconcurrency import ApplicationServices
import AppKit
import AvatarCore
import Foundation

public enum AccessibilityTreeSourceError: Error, Equatable {
    case permissionDenied
    case targetNoLongerForeground
    case targetUnavailable
    case inspectionFailed
}

public struct AccessibilityRawSnapshot: Equatable, Sendable {
    public let elements: [RawAccessibilityElement]
    public let visitedElementCount: Int
    public let truncated: Bool

    public init(
        elements: [RawAccessibilityElement],
        visitedElementCount: Int,
        truncated: Bool
    ) {
        self.elements = elements
        self.visitedElementCount = visitedElementCount
        self.truncated = truncated
    }
}

@MainActor
public protocol AccessibilityTreeSnapshotSource: AnyObject {
    func read(
        processIdentifier: pid_t,
        maximumVisitedElements: Int,
        maximumDepth: Int
    ) -> Result<AccessibilityRawSnapshot, AccessibilityTreeSourceError>
}

@MainActor
public final class SystemAccessibilityTreeSnapshotSource:
    AccessibilityTreeSnapshotSource
{
    private let frontmostProcessIdentifier: () -> pid_t?

    public init(
        frontmostProcessIdentifier: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
    ) {
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    public func read(
        processIdentifier: pid_t,
        maximumVisitedElements: Int,
        maximumDepth: Int
    ) -> Result<AccessibilityRawSnapshot, AccessibilityTreeSourceError> {
        guard frontmostProcessIdentifier() == processIdentifier else {
            return .failure(.targetNoLongerForeground)
        }
        guard AXIsProcessTrusted() else {
            return .failure(.permissionDenied)
        }

        let application = AXUIElementCreateApplication(
            processIdentifier
        )
        AXUIElementSetMessagingTimeout(application, 0.5)

        guard
            attributeString(
                application,
                kAXRoleAttribute as CFString
            ) != nil
        else {
            return .failure(.targetUnavailable)
        }

        var queue: [(element: AXUIElement, depth: Int)] = [
            (application, 0)
        ]
        var queueIndex = 0
        var visited = 0
        var rawElements: [RawAccessibilityElement] = []
        var truncated = false

        while queueIndex < queue.count,
            visited < maximumVisitedElements
        {
            guard frontmostProcessIdentifier() == processIdentifier else {
                return .failure(.targetNoLongerForeground)
            }
            let current = queue[queueIndex]
            queueIndex += 1
            visited += 1

            if let role = attributeString(
                current.element,
                kAXRoleAttribute as CFString
            ), inspectableRoles.contains(role) {
                let actions = actionNames(current.element)
                let label =
                    attributeString(
                        current.element,
                        kAXTitleAttribute as CFString
                    )
                    ?? attributeString(
                        current.element,
                        kAXDescriptionAttribute as CFString
                    )
                rawElements.append(
                    RawAccessibilityElement(
                        role: role,
                        label: label,
                        actions: actions
                    )
                )
            }

            guard current.depth < maximumDepth else { continue }
            let remaining = maximumVisitedElements - visited
            guard remaining > 0 else { continue }
            let children = childElements(
                current.element,
                limit: remaining
            )
            if children.wasTruncated {
                truncated = true
            }
            queue.append(
                contentsOf: children.elements.map {
                    ($0, current.depth + 1)
                }
            )
        }

        if queueIndex < queue.count {
            truncated = true
        }
        guard frontmostProcessIdentifier() == processIdentifier else {
            return .failure(.targetNoLongerForeground)
        }
        return .success(
            AccessibilityRawSnapshot(
                elements: rawElements,
                visitedElementCount: visited,
                truncated: truncated
            )
        )
    }

    private func attributeString(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute,
                &value
            ) == .success
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
    ) -> (elements: [AXUIElement], wasTruncated: Bool) {
        var count = 0
        guard
            AXUIElementGetAttributeValueCount(
                element,
                kAXChildrenAttribute as CFString,
                &count
            ) == .success,
            count > 0
        else {
            return ([], false)
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
            return ([], false)
        }
        return (
            values as? [AXUIElement] ?? [],
            count > requested
        )
    }

    private let inspectableRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXDisclosureTriangle",
        "AXLink",
        "AXMenuButton",
        "AXMenuItem",
        "AXPopUpButton",
        "AXRadioButton",
        "AXSearchField",
        "AXSlider",
        "AXTab",
        "AXTextField",
    ]
}

@MainActor
public final class AccessibilityUIInspector {
    private let source: any AccessibilityTreeSnapshotSource
    private let redactor = AccessibilitySnapshotRedactor()

    public init(
        source: any AccessibilityTreeSnapshotSource =
            SystemAccessibilityTreeSnapshotSource()
    ) {
        self.source = source
    }

    public func inspect(
        processIdentifier: pid_t,
        validated: ValidatedAccessibilityInspection,
        capturedAt: Date
    ) -> Result<AccessibilityUISnapshot, AccessibilityTreeSourceError> {
        switch source.read(
            processIdentifier: processIdentifier,
            maximumVisitedElements:
                validated.request.maximumVisitedElements,
            maximumDepth: validated.request.maximumDepth
        ) {
        case let .success(raw):
            return .success(
                redactor.makeSnapshot(
                    validated: validated,
                    rawElements: raw.elements,
                    visitedElementCount: raw.visitedElementCount,
                    sourceTruncated: raw.truncated,
                    capturedAt: capturedAt
                )
            )
        case let .failure(error):
            return .failure(error)
        }
    }
}
