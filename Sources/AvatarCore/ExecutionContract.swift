import Foundation

public struct ExecutionContract: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let validatedPlan: ValidatedPlan
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        validatedPlan: ValidatedPlan,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.validatedPlan = validatedPlan
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct ExecutionContext: Equatable, Sendable {
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

public enum ExecutionPreflightError: Error, Equatable {
    case emergencyStopped
    case contractExpired
    case targetNotForeground
    case accessibilityPermissionMissing
}

public struct ExecutionPreflight: Sendable {
    public init() {}

    public func validate(
        _ contract: ExecutionContract,
        context: ExecutionContext
    ) throws {
        if context.emergencyStopped {
            throw ExecutionPreflightError.emergencyStopped
        }
        guard context.now < contract.expiresAt else {
            throw ExecutionPreflightError.contractExpired
        }
        guard
            context.frontmostBundleIdentifier
                == contract.validatedPlan.plan.app.bundleIdentifier
        else {
            throw ExecutionPreflightError.targetNotForeground
        }

        let needsAccessibility = contract.validatedPlan.consent.scopes.contains {
            if case .accessibility = $0 { true } else { false }
        }
        if needsAccessibility, !context.accessibilityPermissionGranted {
            throw ExecutionPreflightError.accessibilityPermissionMissing
        }
    }
}

public actor ConsentUseLedger {
    private var consumedOneShotGrantIDs = Set<UUID>()

    public init() {}

    public func consume(_ grant: ConsentGrant) -> Bool {
        guard grant.oneShot else { return true }
        return consumedOneShotGrantIDs.insert(grant.id).inserted
    }
}

public enum ExecutionOutcome: Equatable, Sendable {
    case started
    case succeeded
    case denied(String)
    case failed(String)
    case cancelled
}

public struct AuditEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let contractID: UUID
    public let planID: UUID
    public let timestamp: Date
    public let outcome: ExecutionOutcome

    public init(
        id: UUID = UUID(),
        contractID: UUID,
        planID: UUID,
        timestamp: Date,
        outcome: ExecutionOutcome
    ) {
        self.id = id
        self.contractID = contractID
        self.planID = planID
        self.timestamp = timestamp
        self.outcome = outcome
    }
}

public protocol CapabilityAdapter: Sendable {
    var kind: AdapterKind { get }

    /// Executor receives only prevalidated, expiring contracts.
    func execute(_ contract: ExecutionContract) async -> ExecutionOutcome
}

public actor InMemoryAuditLog {
    private var events: [AuditEvent] = []

    public init() {}

    public func append(_ event: AuditEvent) {
        events.append(event)
    }

    public func events(for contractID: UUID) -> [AuditEvent] {
        events.filter { $0.contractID == contractID }
    }
}
