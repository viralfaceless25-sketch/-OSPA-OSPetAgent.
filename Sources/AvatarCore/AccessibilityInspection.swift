import Foundation

public struct AccessibilityInspectionRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let target: AppIdentity
    public let createdAt: Date
    public let expiresAt: Date
    public let maximumControls: Int
    public let maximumVisitedElements: Int
    public let maximumDepth: Int

    public init(
        id: UUID = UUID(),
        target: AppIdentity,
        createdAt: Date,
        expiresAt: Date,
        maximumControls: Int = 20,
        maximumVisitedElements: Int = 60,
        maximumDepth: Int = 4
    ) {
        self.id = id
        self.target = target
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.maximumControls = maximumControls
        self.maximumVisitedElements = maximumVisitedElements
        self.maximumDepth = maximumDepth
    }
}

public struct AccessibilityInspectionContext: Equatable, Sendable {
    public let frontmostBundleIdentifier: String?
    public let accessibilityPermissionGranted: Bool
    public let emergencyStopped: Bool
    public let now: Date

    public init(
        frontmostBundleIdentifier: String?,
        accessibilityPermissionGranted: Bool,
        emergencyStopped: Bool,
        now: Date
    ) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.accessibilityPermissionGranted = accessibilityPermissionGranted
        self.emergencyStopped = emergencyStopped
        self.now = now
    }
}

public struct ValidatedAccessibilityInspection: Equatable, Sendable {
    public let request: AccessibilityInspectionRequest
    public let consent: ConsentGrant
}

public enum AccessibilityInspectionValidationError: Error, Equatable {
    case emergencyStopped
    case requestExpired
    case targetNotForeground
    case accessibilityPermissionMissing
    case consentForDifferentRequest
    case wrongPermissionScope
    case oneShotConsentRequired
    case userApprovalRequired
    case invalidLimits
}

public struct AccessibilityInspectionValidator: Sendable {
    public init() {}

    public func validate(
        request: AccessibilityInspectionRequest,
        consent: ConsentGrant,
        context: AccessibilityInspectionContext,
        userApproved: Bool
    ) throws -> ValidatedAccessibilityInspection {
        guard !context.emergencyStopped else {
            throw AccessibilityInspectionValidationError.emergencyStopped
        }
        guard context.now < request.expiresAt,
            context.now < consent.expiresAt
        else {
            throw AccessibilityInspectionValidationError.requestExpired
        }
        guard
            context.frontmostBundleIdentifier
                == request.target.bundleIdentifier
        else {
            throw AccessibilityInspectionValidationError.targetNotForeground
        }
        guard context.accessibilityPermissionGranted else {
            throw AccessibilityInspectionValidationError
                .accessibilityPermissionMissing
        }
        guard consent.planID == request.id else {
            throw AccessibilityInspectionValidationError
                .consentForDifferentRequest
        }
        let exactPermission = PermissionScope.accessibility(
            targetBundleIdentifier: request.target.bundleIdentifier
        )
        guard consent.scopes == [exactPermission] else {
            throw AccessibilityInspectionValidationError
                .wrongPermissionScope
        }
        guard consent.oneShot else {
            throw AccessibilityInspectionValidationError
                .oneShotConsentRequired
        }
        guard userApproved else {
            throw AccessibilityInspectionValidationError
                .userApprovalRequired
        }
        guard (1...40).contains(request.maximumControls),
            (1...160).contains(request.maximumVisitedElements),
            (1...6).contains(request.maximumDepth)
        else {
            throw AccessibilityInspectionValidationError.invalidLimits
        }
        return ValidatedAccessibilityInspection(
            request: request,
            consent: consent
        )
    }
}

public struct RawAccessibilityElement: Equatable, Sendable {
    public let role: String
    public let label: String?
    public let actions: [String]

    public init(
        role: String,
        label: String?,
        actions: [String]
    ) {
        self.role = role
        self.label = label
        self.actions = actions
    }
}

public enum RedactedAccessibilityAction: String, Equatable, Sendable {
    case press
    case showMenu
    case increment
    case decrement
    case confirm
    case cancel
    case raise

    public var displayName: String {
        switch self {
        case .press: "Press"
        case .showMenu: "Show menu"
        case .increment: "Increment"
        case .decrement: "Decrement"
        case .confirm: "Confirm"
        case .cancel: "Cancel"
        case .raise: "Raise"
        }
    }
}

public struct AccessibilityControlSummary: Equatable, Sendable, Identifiable {
    public let id: Int
    public let role: String
    public let label: String?
    public let labelWasRedacted: Bool
    public let actions: [RedactedAccessibilityAction]

    public init(
        id: Int,
        role: String,
        label: String?,
        labelWasRedacted: Bool,
        actions: [RedactedAccessibilityAction]
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.labelWasRedacted = labelWasRedacted
        self.actions = actions
    }
}

public struct AccessibilityUISnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let target: AppIdentity
    public let capturedAt: Date
    public let expiresAt: Date
    public let controls: [AccessibilityControlSummary]
    public let visitedElementCount: Int
    public let truncated: Bool

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        target: AppIdentity,
        capturedAt: Date,
        expiresAt: Date,
        controls: [AccessibilityControlSummary],
        visitedElementCount: Int,
        truncated: Bool
    ) {
        self.id = id
        self.requestID = requestID
        self.target = target
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.controls = controls
        self.visitedElementCount = visitedElementCount
        self.truncated = truncated
    }
}

/// Converts raw AX metadata into bounded, display-safe evidence.
public struct AccessibilitySnapshotRedactor: Sendable {
    public init() {}

    public func makeSnapshot(
        validated: ValidatedAccessibilityInspection,
        rawElements: [RawAccessibilityElement],
        visitedElementCount: Int,
        sourceTruncated: Bool,
        capturedAt: Date
    ) -> AccessibilityUISnapshot {
        let maximum = validated.request.maximumControls
        let controls = rawElements.compactMap(sanitize)
            .prefix(maximum)
            .enumerated()
            .map { offset, control in
                AccessibilityControlSummary(
                    id: offset + 1,
                    role: control.role,
                    label: control.label,
                    labelWasRedacted: control.labelWasRedacted,
                    actions: control.actions
                )
            }

        return AccessibilityUISnapshot(
            requestID: validated.request.id,
            target: validated.request.target,
            capturedAt: capturedAt,
            expiresAt: validated.request.expiresAt,
            controls: controls,
            visitedElementCount: min(
                visitedElementCount,
                validated.request.maximumVisitedElements
            ),
            truncated:
                sourceTruncated
                || rawElements.count > maximum,
        )
    }

    private typealias Sanitized = (
        role: String,
        label: String?,
        labelWasRedacted: Bool,
        actions: [RedactedAccessibilityAction]
    )

    private func sanitize(
        _ raw: RawAccessibilityElement
    ) -> Sanitized? {
        guard let role = safeRoles[raw.role] else { return nil }
        let actions = raw.actions.compactMap { safeActions[$0] }
        guard !actions.isEmpty || passiveInteractiveRoles.contains(raw.role)
        else {
            return nil
        }

        let label = sanitizeLabel(raw.label)
        return (
            role,
            label.value,
            label.wasRedacted,
            Array(Set(actions)).sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func sanitizeLabel(
        _ rawLabel: String?
    ) -> (value: String?, wasRedacted: Bool) {
        guard let rawLabel else { return (nil, false) }
        let normalized =
            rawLabel
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        guard !normalized.isEmpty else { return (nil, false) }
        guard let safe = safeLabels[normalized] else {
            return ("[redacted label]", true)
        }
        return (safe, false)
    }

    private let safeRoles: [String: String] = [
        "AXButton": "Button",
        "AXCheckBox": "Checkbox",
        "AXDisclosureTriangle": "Disclosure",
        "AXLink": "Link",
        "AXMenuButton": "Menu button",
        "AXMenuItem": "Menu item",
        "AXPopUpButton": "Pop-up button",
        "AXRadioButton": "Radio button",
        "AXSearchField": "Search field",
        "AXSlider": "Slider",
        "AXTab": "Tab",
        "AXTextField": "Text field",
    ]

    private let passiveInteractiveRoles: Set<String> = [
        "AXSearchField",
        "AXTextField",
    ]

    private let safeActions: [String: RedactedAccessibilityAction] = [
        "AXCancel": .cancel,
        "AXConfirm": .confirm,
        "AXDecrement": .decrement,
        "AXIncrement": .increment,
        "AXPress": .press,
        "AXRaise": .raise,
        "AXShowMenu": .showMenu,
    ]

    private let safeLabels: [String: String] = [
        "back": "Back",
        "cancel": "Cancel",
        "close": "Close",
        "confirm": "Confirm",
        "continue": "Continue",
        "continue watching": "Continue watching",
        "done": "Done",
        "episodes": "Episodes",
        "forward": "Forward",
        "full screen": "Full screen",
        "home": "Home",
        "menu": "Menu",
        "more": "More",
        "mute": "Mute",
        "next": "Next",
        "ok": "OK",
        "open": "Open",
        "pause": "Pause",
        "play": "Play",
        "previous": "Previous",
        "resume": "Resume",
        "search": "Search",
        "settings": "Settings",
        "sign in": "Sign in",
        "unmute": "Unmute",
        "volume": "Volume",
    ]
}

public struct AccessibilityInteractionEvidence: Equatable, Sendable, Identifiable {
    public let id: Int
    public let description: String

    public init(id: Int, description: String) {
        self.id = id
        self.description = description
    }
}

public struct AccessibilityInteractionPreview: Equatable, Sendable {
    public let snapshotID: UUID
    public let target: AppIdentity
    public let evidence: [AccessibilityInteractionEvidence]
    public let executionEnabled: Bool
    public let expiresAt: Date

    public init(snapshot: AccessibilityUISnapshot) {
        snapshotID = snapshot.id
        target = snapshot.target
        expiresAt = snapshot.expiresAt
        executionEnabled = false
        evidence = snapshot.controls.prefix(12).map { control in
            let label =
                control.label.map { " “\($0)”" }
                ?? ""
            let actions =
                control.actions.isEmpty
                ? "no supported action"
                : control.actions.map(\.displayName)
                    .joined(separator: ", ")
            return AccessibilityInteractionEvidence(
                id: control.id,
                description:
                    "\(control.role)\(label) exposes \(actions)."
            )
        }
    }
}

public enum AccessibilityInspectionAuditOutcome: Equatable, Sendable {
    case started
    case succeeded(controlCount: Int, truncated: Bool)
    case denied
    case failed
}

public struct AccessibilityInspectionAuditRecord:
    Equatable, Sendable, Identifiable
{
    public let id: UUID
    public let requestID: UUID
    public let targetBundleIdentifier: String
    public let timestamp: Date
    public let outcome: AccessibilityInspectionAuditOutcome

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        targetBundleIdentifier: String,
        timestamp: Date,
        outcome: AccessibilityInspectionAuditOutcome
    ) {
        self.id = id
        self.requestID = requestID
        self.targetBundleIdentifier = targetBundleIdentifier
        self.timestamp = timestamp
        self.outcome = outcome
    }
}
