import Foundation

/// Stable identity observed from macOS. No executable path or app data is collected.
public struct AppIdentity: Equatable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public enum AdapterKind: String, Equatable, Sendable {
    /// Visible keyboard, pointer, window, and UI actions through macOS Accessibility.
    case foregroundComputerUse
    case nativeAPI
    case appExtension
    case urlScheme
    case keyboardShortcut
    case documentedScript
}

public enum ActionRisk: Int, Comparable, Sendable {
    case readOnly = 0
    case reversible = 1
    case meaningful = 2
    case destructive = 3

    public static func < (lhs: ActionRisk, rhs: ActionRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum PermissionScope: Equatable, Hashable, Sendable {
    case clipboardWrite
    case network(hosts: Set<String>)
    case accessibility(targetBundleIdentifier: String)
    case automation(targetBundleIdentifier: String)
    case files(securityScopedBookmarkIDs: Set<String>)
}

public enum CapabilityEvidence: Equatable, Hashable, Sendable {
    case bundled
    case reviewedClaim(UUID)
}

public struct CapabilityDefinition: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let effectSummary: String
    public let adapter: AdapterKind
    public let risk: ActionRisk
    public let requiredPermissions: Set<PermissionScope>
    public let evidence: CapabilityEvidence

    public init(
        id: String,
        name: String,
        effectSummary: String,
        adapter: AdapterKind,
        risk: ActionRisk,
        requiredPermissions: Set<PermissionScope>,
        evidence: CapabilityEvidence
    ) {
        self.id = id
        self.name = name
        self.effectSummary = effectSummary
        self.adapter = adapter
        self.risk = risk
        self.requiredPermissions = requiredPermissions
        self.evidence = evidence
    }
}

public struct CapabilityProfile: Equatable, Sendable {
    public let app: AppIdentity
    public let capabilities: [CapabilityDefinition]
    public let reviewedClaimIDs: Set<UUID>
    public let approvedAt: Date

    public init(
        app: AppIdentity,
        capabilities: [CapabilityDefinition],
        reviewedClaimIDs: Set<UUID>,
        approvedAt: Date
    ) {
        self.app = app
        self.capabilities = capabilities
        self.reviewedClaimIDs = reviewedClaimIDs
        self.approvedAt = approvedAt
    }
}

public enum ProfileValidationError: Error, Equatable {
    case duplicateCapabilityID(String)
    case unreviewedEvidence(UUID)
    case computerUseMustBeMeaningful
    case computerUseNeedsTargetedAccessibility
}

public struct ProfileValidator: Sendable {
    public init() {}

    public func validate(_ profile: CapabilityProfile) throws {
        var seen = Set<String>()

        for capability in profile.capabilities {
            guard seen.insert(capability.id).inserted else {
                throw ProfileValidationError.duplicateCapabilityID(capability.id)
            }

            if case let .reviewedClaim(claimID) = capability.evidence,
                !profile.reviewedClaimIDs.contains(claimID)
            {
                throw ProfileValidationError.unreviewedEvidence(claimID)
            }

            if capability.adapter == .foregroundComputerUse {
                guard capability.risk >= .meaningful else {
                    throw ProfileValidationError.computerUseMustBeMeaningful
                }

                let required = PermissionScope.accessibility(
                    targetBundleIdentifier: profile.app.bundleIdentifier
                )
                guard capability.requiredPermissions.contains(required) else {
                    throw ProfileValidationError
                        .computerUseNeedsTargetedAccessibility
                }
            }
        }
    }
}
