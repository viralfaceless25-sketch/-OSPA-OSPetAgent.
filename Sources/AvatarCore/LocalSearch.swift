import Foundation

public enum LocalSearchItemKind: String, CaseIterable, Equatable, Sendable {
    case application
    case folder
    case file

    public var displayName: String {
        rawValue.capitalized
    }
}

public enum LocalSearchScopeID: String, CaseIterable, Equatable, Hashable, Sendable {
    case applications
    case desktop
    case documents
    case downloads

    public var displayName: String {
        switch self {
        case .applications: "Applications"
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        }
    }

    public var isPersonal: Bool {
        self != .applications
    }
}

public struct LocalSearchItem: Equatable, Sendable, Identifiable {
    public let name: String
    public let url: URL
    public let kind: LocalSearchItemKind
    public let scope: LocalSearchScopeID
    public let bundleIdentifier: String?
    public let isRunning: Bool

    public var id: String {
        url.standardizedFileURL.absoluteString
    }

    public init(
        name: String,
        url: URL,
        kind: LocalSearchItemKind,
        scope: LocalSearchScopeID,
        bundleIdentifier: String? = nil,
        isRunning: Bool = false
    ) {
        self.name = name
        self.url = url.standardizedFileURL
        self.kind = kind
        self.scope = scope
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
    }
}

public struct LocalSearchCandidate: Equatable, Sendable, Identifiable {
    public let item: LocalSearchItem
    public let score: Int
    public let matchDescription: String

    public var id: String { item.id }

    public init(
        item: LocalSearchItem,
        score: Int,
        matchDescription: String
    ) {
        self.item = item
        self.score = score
        self.matchDescription = matchDescription
    }
}

/// Pure, local name ranker. A candidate has no execution authority.
public struct LocalSearchRanker: Sendable {
    public init() {}

    public func search(
        query: String,
        items: [LocalSearchItem],
        limit: Int = 12
    ) -> [LocalSearchCandidate] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty, limit > 0 else { return [] }

        return items.compactMap { item in
            rank(item, query: normalizedQuery)
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            let nameOrder = $0.item.name.localizedCaseInsensitiveCompare(
                $1.item.name
            )
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.item.url.path < $1.item.url.path
        }
        .prefix(limit)
        .map { $0 }
    }

    private func rank(
        _ item: LocalSearchItem,
        query: String
    ) -> LocalSearchCandidate? {
        let name = normalize(item.name)
        let base: (Int, String)?

        if name == query {
            base = (1_000, "Exact name")
        } else if name.hasPrefix(query) {
            base = (
                900 - min(name.count - query.count, 100),
                "Name prefix"
            )
        } else if name.split(separator: " ").contains(where: {
            $0.hasPrefix(query)
        }) {
            base = (800, "Word prefix")
        } else if name.contains(query) {
            base = (700, "Name contains query")
        } else if let gapPenalty = subsequenceGapPenalty(
            query: query,
            value: name
        ) {
            base = (400 - min(gapPenalty, 200), "Fuzzy name")
        } else {
            base = nil
        }

        guard let base else { return nil }
        let applicationBonus = item.kind == .application ? 10 : 0
        let runningBonus = item.isRunning ? 20 : 0
        return LocalSearchCandidate(
            item: item,
            score: base.0 + applicationBonus + runningBonus,
            matchDescription: base.1
        )
    }

    private func subsequenceGapPenalty(
        query: String,
        value: String
    ) -> Int? {
        var queryIndex = query.startIndex
        var lastMatchOffset: Int?
        var penalty = 0

        for (offset, character) in value.enumerated() {
            guard queryIndex < query.endIndex else { break }
            if character == query[queryIndex] {
                if let lastMatchOffset {
                    penalty += max(0, offset - lastMatchOffset - 1)
                }
                lastMatchOffset = offset
                query.formIndex(after: &queryIndex)
            }
        }

        return queryIndex == query.endIndex ? penalty : nil
    }

    private func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
    }
}

public struct LocalSearchAuthorization: Equatable, Sendable {
    public let approvedScopes: Set<LocalSearchScopeID>
    public let approvedAt: Date
    public let expiresAt: Date

    public init(
        approvedScopes: Set<LocalSearchScopeID>,
        approvedAt: Date,
        expiresAt: Date
    ) {
        self.approvedScopes = approvedScopes
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
    }
}

public enum LocalSearchAuthorizationError: Error, Equatable {
    case userApprovalRequired
    case applicationsScopeRequired
    case expired
    case scopeNotApproved
}

public struct LocalSearchScopePolicy: Sendable {
    public init() {}

    public func authorize(
        scopes: Set<LocalSearchScopeID>,
        userApproved: Bool,
        now: Date,
        duration: TimeInterval = 15 * 60
    ) throws -> LocalSearchAuthorization {
        guard userApproved else {
            throw LocalSearchAuthorizationError.userApprovalRequired
        }
        guard scopes.contains(.applications) else {
            throw LocalSearchAuthorizationError.applicationsScopeRequired
        }
        return LocalSearchAuthorization(
            approvedScopes: scopes,
            approvedAt: now,
            expiresAt: now.addingTimeInterval(duration)
        )
    }

    public func validate(
        item: LocalSearchItem,
        authorization: LocalSearchAuthorization,
        now: Date
    ) throws {
        guard now < authorization.expiresAt else {
            throw LocalSearchAuthorizationError.expired
        }
        guard authorization.approvedScopes.contains(item.scope) else {
            throw LocalSearchAuthorizationError.scopeNotApproved
        }
    }
}

public enum SpotlightInteractionStep: String, CaseIterable, Equatable, Sendable {
    case invokeSpotlight
    case enterSelectedName
    case verifyExactResult
    case openVerifiedResult

    public var previewDescription: String {
        switch self {
        case .invokeSpotlight:
            "Press Command-Space to show macOS Spotlight."
        case .enterSelectedName:
            "Enter only the selected result’s exact name."
        case .verifyExactResult:
            "Verify the highlighted name, kind, and location match the selected result."
        case .openVerifiedResult:
            "Press Return once only after exact-result verification."
        }
    }
}

public struct SpotlightOpenPreview: Equatable, Sendable {
    public let item: LocalSearchItem
    public let steps: [SpotlightInteractionStep]
    public let executionEnabled: Bool
    public let blocker: String

    public init(item: LocalSearchItem) {
        self.item = item
        self.steps = SpotlightInteractionStep.allCases
        self.executionEnabled = false
        self.blocker =
            "Accessibility input and Spotlight-result inspection are not enabled. This route cannot safely press Return yet."
    }
}

public struct LocalItemOpenPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let item: LocalSearchItem
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        item: LocalSearchItem,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.item = item
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct ValidatedLocalItemOpen: Equatable, Sendable {
    public let plan: LocalItemOpenPlan
    public let consent: ConsentGrant
}

public enum LocalItemOpenValidationError: Error, Equatable {
    case observeOnly
    case emergencyStopped
    case expired
    case consentForDifferentPlan
    case permissionScopeNotEmpty
    case confirmationRequired
}

public struct LocalItemOpenValidator: Sendable {
    public init() {}

    public func validate(
        plan: LocalItemOpenPlan,
        authorization: LocalSearchAuthorization,
        consent: ConsentGrant,
        safety: SafetyState,
        userConfirmedPreview: Bool,
        now: Date
    ) throws -> ValidatedLocalItemOpen {
        if safety.emergencyStopped {
            throw LocalItemOpenValidationError.emergencyStopped
        }
        if safety.observeOnly {
            throw LocalItemOpenValidationError.observeOnly
        }
        guard now < plan.expiresAt, now < consent.expiresAt else {
            throw LocalItemOpenValidationError.expired
        }
        guard consent.planID == plan.id else {
            throw LocalItemOpenValidationError.consentForDifferentPlan
        }
        guard consent.scopes.isEmpty else {
            throw LocalItemOpenValidationError.permissionScopeNotEmpty
        }
        guard userConfirmedPreview else {
            throw LocalItemOpenValidationError.confirmationRequired
        }
        try LocalSearchScopePolicy().validate(
            item: plan.item,
            authorization: authorization,
            now: now
        )
        return ValidatedLocalItemOpen(plan: plan, consent: consent)
    }
}

public struct LocalItemOpenExecutionContract: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let validated: ValidatedLocalItemOpen
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        validated: ValidatedLocalItemOpen,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.validated = validated
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}
