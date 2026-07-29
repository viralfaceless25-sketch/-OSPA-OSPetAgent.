import Foundation
import Testing
@testable import AvatarCore

@Suite("Local search")
struct LocalSearchTests {
    private let netflix = LocalSearchItem(
        name: "Netflix",
        url: URL(fileURLWithPath: "/Applications/Netflix.app"),
        kind: .application,
        scope: .applications,
        bundleIdentifier: "com.apple.Safari.WebApp.netflix"
    )

    @Test("Prefix and fuzzy matching rank by name")
    func rankedNameMatching() {
        let notes = LocalSearchItem(
            name: "Notes",
            url: URL(fileURLWithPath: "/Applications/Notes.app"),
            kind: .application,
            scope: .applications,
            bundleIdentifier: "com.apple.Notes",
            isRunning: true
        )
        let ranker = LocalSearchRanker()

        #expect(ranker.search(query: "net", items: [notes, netflix]).first?.item == netflix)
        #expect(ranker.search(query: "ntfx", items: [notes, netflix]).first?.item == netflix)
    }

    @Test("Exact name beats running prefix")
    func exactBeatsRunningPrefix() {
        let runningPrefix = LocalSearchItem(
            name: "Netflix Helper",
            url: URL(fileURLWithPath: "/Applications/Netflix Helper.app"),
            kind: .application,
            scope: .applications,
            isRunning: true
        )

        #expect(
            LocalSearchRanker()
                .search(query: "Netflix", items: [runningPrefix, netflix])
                .first?.item == netflix
        )
    }

    @Test("Empty query and zero limit return no names")
    func emptySearch() {
        let ranker = LocalSearchRanker()

        #expect(ranker.search(query: " ", items: [netflix]).isEmpty)
        #expect(ranker.search(query: "net", items: [netflix], limit: 0).isEmpty)
    }

    @Test("Search result count is bounded")
    func resultLimit() {
        let items = (0..<20).map { index in
            LocalSearchItem(
                name: "Net \(index)",
                url: URL(fileURLWithPath: "/Applications/Net\(index).app"),
                kind: .application,
                scope: .applications
            )
        }

        #expect(LocalSearchRanker().search(query: "net", items: items, limit: 4).count == 4)
    }

    @Test("Scope authorization is explicit and expiring")
    func authorization() throws {
        let now = Date()
        let policy = LocalSearchScopePolicy()

        #expect(throws: LocalSearchAuthorizationError.userApprovalRequired) {
            try policy.authorize(
                scopes: [.applications, .documents],
                userApproved: false,
                now: now
            )
        }
        let authorization = try policy.authorize(
            scopes: [.applications, .documents],
            userApproved: true,
            now: now
        )
        #expect(authorization.approvedScopes.contains(.documents))
        #expect(throws: LocalSearchAuthorizationError.expired) {
            try policy.validate(
                item: netflix,
                authorization: authorization,
                now: now.addingTimeInterval(901)
            )
        }
    }

    @Test("Selection outside approved scope is rejected")
    func rejectsUnapprovedScope() throws {
        let now = Date()
        let authorization = try LocalSearchScopePolicy().authorize(
            scopes: [.applications],
            userApproved: true,
            now: now
        )
        let file = LocalSearchItem(
            name: "Private.txt",
            url: URL(fileURLWithPath: "/Users/me/Documents/Private.txt"),
            kind: .file,
            scope: .documents
        )

        #expect(throws: LocalSearchAuthorizationError.scopeNotApproved) {
            try LocalSearchScopePolicy().validate(
                item: file,
                authorization: authorization,
                now: now
            )
        }
    }

    @Test("Spotlight route cannot execute")
    func previewOnlyRoute() {
        let preview = SpotlightOpenPreview(item: netflix)

        #expect(!preview.executionEnabled)
        #expect(preview.steps == SpotlightInteractionStep.allCases)
    }

    @Test("Native fallback requires action mode and exact consent")
    func fallbackValidation() throws {
        let now = Date()
        let plan = LocalItemOpenPlan(
            item: netflix,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let authorization = try LocalSearchScopePolicy().authorize(
            scopes: [.applications],
            userApproved: true,
            now: now
        )
        let consent = ConsentGrant(
            planID: plan.id,
            scopes: [],
            approvedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )

        #expect(throws: LocalItemOpenValidationError.observeOnly) {
            try LocalItemOpenValidator().validate(
                plan: plan,
                authorization: authorization,
                consent: consent,
                safety: .initial,
                userConfirmedPreview: true,
                now: now
            )
        }
        let validated = try LocalItemOpenValidator().validate(
            plan: plan,
            authorization: authorization,
            consent: consent,
            safety: SafetyState(observeOnly: false, emergencyStopped: false),
            userConfirmedPreview: true,
            now: now
        )
        #expect(validated.plan.item == netflix)
    }
}
