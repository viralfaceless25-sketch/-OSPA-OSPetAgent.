import Foundation

public struct ComputerUsePreviewContract: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let validatedPlan: PreviewValidatedPlan
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        validatedPlan: PreviewValidatedPlan,
        issuedAt: Date
    ) {
        self.id = id
        self.validatedPlan = validatedPlan
        self.issuedAt = issuedAt
        self.expiresAt = validatedPlan.consent.expiresAt
    }
}

public enum PreviewReadinessIssue: Equatable, Sendable {
    case emergencyStopped
    case contractExpired
    case targetNotForeground
    case accessibilityPermissionMissing

    public var description: String {
        switch self {
        case .emergencyStopped:
            "Emergency stop is active."
        case .contractExpired:
            "Preview consent expired."
        case .targetNotForeground:
            "Target app is no longer foreground."
        case .accessibilityPermissionMissing:
            "macOS Accessibility permission is not granted."
        }
    }
}

public struct ComputerUsePreview: Equatable, Sendable {
    public let contractID: UUID
    public let planID: UUID
    public let target: AppIdentity
    public let steps: [String]
    public let permissionScopes: Set<PermissionScope>
    public let readinessIssues: [PreviewReadinessIssue]
    public let executionEnabled: Bool
    public let expiresAt: Date

    public init(
        contractID: UUID,
        planID: UUID,
        target: AppIdentity,
        steps: [String],
        permissionScopes: Set<PermissionScope>,
        readinessIssues: [PreviewReadinessIssue],
        executionEnabled: Bool,
        expiresAt: Date
    ) {
        self.contractID = contractID
        self.planID = planID
        self.target = target
        self.steps = steps
        self.permissionScopes = permissionScopes
        self.readinessIssues = readinessIssues
        self.executionEnabled = executionEnabled
        self.expiresAt = expiresAt
    }
}

/// Renders contracts only. Deliberately has no execute method or event dependency.
public struct PreviewOnlyForegroundAdapter: Sendable {
    public init() {}

    public func render(
        _ contract: ComputerUsePreviewContract,
        context: ExecutionContext
    ) -> ComputerUsePreview {
        let target = contract.validatedPlan.plan.app
        var issues: [PreviewReadinessIssue] = []

        if context.emergencyStopped {
            issues.append(.emergencyStopped)
        }
        if context.now >= contract.expiresAt {
            issues.append(.contractExpired)
        }
        if context.frontmostBundleIdentifier != target.bundleIdentifier {
            issues.append(.targetNotForeground)
        }
        if !context.accessibilityPermissionGranted {
            issues.append(.accessibilityPermissionMissing)
        }

        let steps = contract.validatedPlan.plan.steps.enumerated().map {
            index, step in
            let interaction =
                step.visibleInteraction?.previewDescription
                ?? "No typed visible interaction."
            return "\(index + 1). \(interaction) Effect: \(step.effectPreview)"
        }

        return ComputerUsePreview(
            contractID: contract.id,
            planID: contract.validatedPlan.plan.id,
            target: target,
            steps: steps,
            permissionScopes: contract.validatedPlan.consent.scopes,
            readinessIssues: issues,
            executionEnabled: false,
            expiresAt: contract.expiresAt
        )
    }
}

public struct PreviewAuditRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let contractID: UUID
    public let planID: UUID
    public let targetBundleIdentifier: String
    public let renderedAt: Date
    public let readinessIssues: [PreviewReadinessIssue]

    public init(
        id: UUID = UUID(),
        preview: ComputerUsePreview,
        renderedAt: Date
    ) {
        self.id = id
        self.contractID = preview.contractID
        self.planID = preview.planID
        self.targetBundleIdentifier = preview.target.bundleIdentifier
        self.renderedAt = renderedAt
        self.readinessIssues = preview.readinessIssues
    }
}
