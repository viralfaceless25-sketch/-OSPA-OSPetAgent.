import Foundation

public struct ResearchRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let app: AppIdentity
    public let approvedHosts: Set<String>
    public let maxDocuments: Int
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        app: AppIdentity,
        approvedHosts: Set<String>,
        maxDocuments: Int,
        createdAt: Date
    ) {
        self.id = id
        self.app = app
        self.approvedHosts = approvedHosts
        self.maxDocuments = maxDocuments
        self.createdAt = createdAt
    }
}

public struct ResearchAuthorization: Equatable, Sendable {
    public let request: ResearchRequest
    public let approvedAt: Date
    public let expiresAt: Date
}

public enum ResearchBoundaryError: Error, Equatable {
    case httpsRequired
    case exactHostRequired
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed
    case invalidDocumentLimit
    case explicitApprovalRequired
    case hostOutsideAuthorization(String)
    case authorizationExpired
    case claimApprovalRequired
}

public struct ResearchGate: Sendable {
    public init() {}

    public func propose(
        app: AppIdentity,
        officialDocumentationURL: URL,
        maxDocuments: Int = 5,
        now: Date
    ) throws -> ResearchRequest {
        guard officialDocumentationURL.scheme?.lowercased() == "https" else {
            throw ResearchBoundaryError.httpsRequired
        }
        guard
            let host = officialDocumentationURL.host?.lowercased(),
            !host.isEmpty,
            !host.contains("*")
        else {
            throw ResearchBoundaryError.exactHostRequired
        }
        guard officialDocumentationURL.user == nil,
            officialDocumentationURL.password == nil
        else {
            throw ResearchBoundaryError.credentialsNotAllowed
        }
        guard officialDocumentationURL.query == nil,
            officialDocumentationURL.fragment == nil
        else {
            throw ResearchBoundaryError.queryOrFragmentNotAllowed
        }
        guard (1...10).contains(maxDocuments) else {
            throw ResearchBoundaryError.invalidDocumentLimit
        }

        return ResearchRequest(
            app: app,
            approvedHosts: [host],
            maxDocuments: maxDocuments,
            createdAt: now
        )
    }

    public func authorize(
        _ request: ResearchRequest,
        userApproved: Bool,
        now: Date,
        duration: TimeInterval = 15 * 60
    ) throws -> ResearchAuthorization {
        guard userApproved else {
            throw ResearchBoundaryError.explicitApprovalRequired
        }

        return ResearchAuthorization(
            request: request,
            approvedAt: now,
            expiresAt: now.addingTimeInterval(duration)
        )
    }

    public func validateFetch(
        _ url: URL,
        authorization: ResearchAuthorization,
        now: Date
    ) throws {
        guard now < authorization.expiresAt else {
            throw ResearchBoundaryError.authorizationExpired
        }
        guard url.scheme?.lowercased() == "https" else {
            throw ResearchBoundaryError.httpsRequired
        }
        guard let host = url.host?.lowercased(),
            authorization.request.approvedHosts.contains(host)
        else {
            throw ResearchBoundaryError.hostOutsideAuthorization(
                url.host ?? "(missing host)"
            )
        }
    }
}

/// Fetched text remains untrusted. It cannot become executable capability data.
public struct ResearchArtifact: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let sourceURL: URL
    public let contentDigest: String
    public let fetchedAt: Date

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        sourceURL: URL,
        contentDigest: String,
        fetchedAt: Date
    ) {
        self.id = id
        self.requestID = requestID
        self.sourceURL = sourceURL
        self.contentDigest = contentDigest
        self.fetchedAt = fetchedAt
    }
}

public struct ResearchClaim: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let artifactID: UUID
    public let summary: String

    public init(id: UUID = UUID(), artifactID: UUID, summary: String) {
        self.id = id
        self.artifactID = artifactID
        self.summary = summary
    }
}

public struct ReviewedClaim: Equatable, Sendable {
    public let claim: ResearchClaim
    public let reviewedAt: Date

    public init(
        claim: ResearchClaim,
        userApproved: Bool,
        reviewedAt: Date
    ) throws {
        guard userApproved else {
            throw ResearchBoundaryError.claimApprovalRequired
        }
        self.claim = claim
        self.reviewedAt = reviewedAt
    }
}
