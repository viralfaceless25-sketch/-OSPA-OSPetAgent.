import Foundation
import Testing
@testable import AvatarCore

@Suite("Official documentation research boundary")
struct ResearchBoundaryTests {
    private let gate = ResearchGate()
    private let app = AppIdentity(
        bundleIdentifier: "com.example.editor",
        displayName: "Example Editor"
    )
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("Creates exact HTTPS host scope")
    func createsNarrowProposal() throws {
        let request = try gate.propose(
            app: app,
            officialDocumentationURL: #require(URL(string: "https://docs.example.com/guide")),
            now: now
        )

        #expect(request.approvedHosts == ["docs.example.com"])
        #expect(request.maxDocuments == 5)
    }

    @Test("Rejects non-HTTPS source")
    func rejectsHTTP() {
        #expect(throws: ResearchBoundaryError.httpsRequired) {
            try gate.propose(
                app: app,
                officialDocumentationURL: #require(URL(string: "http://docs.example.com")),
                now: now
            )
        }
    }

    @Test("Authorization needs explicit approval")
    func needsApproval() throws {
        let request = try proposal()
        #expect(throws: ResearchBoundaryError.explicitApprovalRequired) {
            try gate.authorize(request, userApproved: false, now: now)
        }
    }

    @Test("Authorized fetch cannot leave exact host")
    func blocksHostChange() throws {
        let authorization = try gate.authorize(
            proposal(),
            userApproved: true,
            now: now
        )

        #expect(
            throws: ResearchBoundaryError.hostOutsideAuthorization("example.com")
        ) {
            try gate.validateFetch(
                #require(URL(string: "https://example.com/docs")),
                authorization: authorization,
                now: now
            )
        }
    }

    @Test("Research authorization expires")
    func expires() throws {
        let authorization = try gate.authorize(
            proposal(),
            userApproved: true,
            now: now,
            duration: 60
        )

        #expect(throws: ResearchBoundaryError.authorizationExpired) {
            try gate.validateFetch(
                #require(URL(string: "https://docs.example.com/guide")),
                authorization: authorization,
                now: now.addingTimeInterval(61)
            )
        }
    }

    @Test("Extracted claim remains blocked until reviewed")
    func claimNeedsReview() {
        let claim = ResearchClaim(
            artifactID: UUID(),
            summary: "The application documents a Save keyboard shortcut."
        )

        #expect(throws: ResearchBoundaryError.claimApprovalRequired) {
            try ReviewedClaim(
                claim: claim,
                userApproved: false,
                reviewedAt: now
            )
        }
    }

    private func proposal() throws -> ResearchRequest {
        try gate.propose(
            app: app,
            officialDocumentationURL: #require(URL(string: "https://docs.example.com")),
            now: now
        )
    }
}
