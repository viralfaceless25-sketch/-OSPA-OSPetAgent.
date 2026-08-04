import Foundation

/// Pure bounds shared by validated search values and platform transports.
public enum WebSearchLimits: Sendable {
    public static let maximumQueryScalars = 400
    public static let maximumTitleScalars = 200
    public static let maximumSnippetScalars = 1_000
    public static let maximumURLScalars = 2_048
    public static let maximumResults = 10
    public static let maximumResponseBytes = 1_048_576
    public static let timeoutSeconds: TimeInterval = 15
}

public enum WebSearchQueryRejection: Equatable, Sendable {
    case empty
    case tooLong
    case unsafeScalar(UInt32)
}

/// Failures exposed by a web-search service.
public enum WebSearchError: Error, Equatable, Sendable {
    case apiKeyNotConfigured
    case rejectedQuery(WebSearchQueryRejection)
    case credentialFailure
    case networkFailure
    case timedOut
    case rateLimited
    case httpStatus(Int)
    case badResponse
    case responseTooLarge

    public var userMessage: String {
        switch self {
        case .apiKeyNotConfigured:
            "Web search isn't set up yet."
        case .rejectedQuery:
            "That search isn't safe to use."
        case .credentialFailure:
            "I couldn't access the web search key."
        case .networkFailure:
            "I couldn't reach web search."
        case .timedOut:
            "Web search took too long."
        case .rateLimited:
            "Web search is busy right now. Please try again later."
        case .httpStatus:
            "Web search returned an error."
        case .badResponse:
            "I couldn't use the web search response."
        case .responseTooLarge:
            "The web search response was too large to handle safely."
        }
    }
}

/// A single-line query validated before it can reach a provider.
public struct WebSearchQuery: Equatable, Sendable {
    public let value: String

    public init(_ rawValue: String) throws {
        if let scalar = rawValue.unicodeScalars.first(where: isUnsafeSearchScalar) {
            throw WebSearchError.rejectedQuery(.unsafeScalar(scalar.value))
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebSearchError.rejectedQuery(.empty)
        }
        guard trimmed.unicodeScalars.count <= WebSearchLimits.maximumQueryScalars else {
            throw WebSearchError.rejectedQuery(.tooLong)
        }
        value = trimmed
    }
}

public enum WebSearchResultValidationError: Error, Equatable, Sendable {
    case emptyTitle
    case titleTooLong
    case unsafeTitleScalar(UInt32)
    case invalidURL
    case urlTooLong
    case unsafeURLScalar(UInt32)
    case emptySnippet
    case snippetTooLong
    case unsafeSnippetScalar(UInt32)
}

/// Untrusted provider output represented as inert display data.
public struct WebSearchResult: Equatable, Sendable {
    public let title: String
    public let url: URL
    public let snippet: String

    public init(title: String, url: URL, snippet: String) throws {
        if let scalar = title.unicodeScalars.first(where: isUnsafeSearchScalar) {
            throw WebSearchResultValidationError.unsafeTitleScalar(scalar.value)
        }
        guard title.unicodeScalars.count <= WebSearchLimits.maximumTitleScalars else {
            throw WebSearchResultValidationError.titleTooLong
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw WebSearchResultValidationError.emptyTitle
        }

        let rawURL = url.absoluteString
        guard rawURL.unicodeScalars.count <= WebSearchLimits.maximumURLScalars else {
            throw WebSearchResultValidationError.urlTooLong
        }
        let decodedURL = rawURL.removingPercentEncoding ?? rawURL
        if let scalar = decodedURL.unicodeScalars.first(where: isUnsafeSearchScalar) {
            throw WebSearchResultValidationError.unsafeURLScalar(scalar.value)
        }
        guard let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            throw WebSearchResultValidationError.invalidURL
        }

        if let scalar = snippet.unicodeScalars.first(where: isUnsafeSearchScalar) {
            throw WebSearchResultValidationError.unsafeSnippetScalar(scalar.value)
        }
        guard snippet.unicodeScalars.count <= WebSearchLimits.maximumSnippetScalars else {
            throw WebSearchResultValidationError.snippetTooLong
        }
        let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSnippet.isEmpty else {
            throw WebSearchResultValidationError.emptySnippet
        }

        self.title = trimmedTitle
        self.url = url
        self.snippet = trimmedSnippet
    }
}

public enum WebSearchResultSetError: Error, Equatable, Sendable {
    case tooManyResults(maximum: Int)
}

/// Provider results bounded as a whole. Excess results are refused.
public struct WebSearchResultSet: Equatable, Sendable {
    public let results: [WebSearchResult]

    public init(results: [WebSearchResult]) throws {
        guard results.count <= WebSearchLimits.maximumResults else {
            throw WebSearchResultSetError.tooManyResults(
                maximum: WebSearchLimits.maximumResults
            )
        }
        self.results = results
    }
}

public enum WebSearchAuditOutcome: Equatable, Sendable {
    case succeeded
    case notConfigured
    case rejected
    case failed
    case cancelled
}

/// Redacted metadata for one search. Query text and credentials are excluded.
public struct WebSearchAuditEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let providerHost: String
    public let timestamp: Date
    public let outcome: WebSearchAuditOutcome
    public let resultCount: Int
    public let queryScalarCount: Int

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        providerHost: String,
        timestamp: Date,
        outcome: WebSearchAuditOutcome,
        resultCount: Int,
        queryScalarCount: Int
    ) {
        self.id = id
        self.requestID = requestID
        self.providerHost = providerHost
        self.timestamp = timestamp
        self.outcome = outcome
        self.resultCount = resultCount
        self.queryScalarCount = queryScalarCount
    }
}

private func isUnsafeSearchScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator:
        true
    default:
        false
    }
}
