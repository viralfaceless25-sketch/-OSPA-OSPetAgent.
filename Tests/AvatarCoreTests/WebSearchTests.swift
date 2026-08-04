import Foundation
import Testing

@testable import AvatarCore

@Suite("Validated web search values")
struct WebSearchValueTests {
    @Test(
        "Empty and whitespace-only queries are refused with the exact reason",
        arguments: ["", "   "]
    )
    func refusesEmptyQuery(rawValue: String) {
        #expect(throws: WebSearchError.rejectedQuery(.empty)) {
            try WebSearchQuery(rawValue)
        }
    }

    @Test("A query over the scalar cap is refused, not truncated")
    func refusesLongQuery() throws {
        let atCap = String(
            repeating: "a", count: WebSearchLimits.maximumQueryScalars
        )
        #expect(try WebSearchQuery(atCap).value == atCap)

        let overCap = String(
            repeating: "a", count: WebSearchLimits.maximumQueryScalars + 1
        )
        #expect(throws: WebSearchError.rejectedQuery(.tooLong)) {
            try WebSearchQuery(overCap)
        }
    }

    @Test("A bidi override reaches query validation and is refused exactly")
    func refusesBidiQuery() {
        let rawValue = "weather\u{202E}txt"
        #expect(rawValue.unicodeScalars.contains { $0.value == 0x202E })
        #expect(throws: WebSearchError.rejectedQuery(.unsafeScalar(0x202E))) {
            try WebSearchQuery(rawValue)
        }
    }

    @Test("A NUL reaches query validation and is refused exactly")
    func refusesNULQuery() {
        let nul = UnicodeScalar(0)!
        let rawValue = "weather\(Character(nul))today"
        #expect(rawValue.unicodeScalars.contains { $0.value == 0 })
        #expect(throws: WebSearchError.rejectedQuery(.unsafeScalar(0))) {
            try WebSearchQuery(rawValue)
        }
    }

    @Test(
        "Queries are single-line and refuse newline and tab exactly",
        arguments: [UInt32(0x0A), UInt32(0x09)]
    )
    func refusesSingleLineControls(scalarValue: UInt32) {
        let scalar = UnicodeScalar(scalarValue)!
        let rawValue = "one\(Character(scalar))two"
        #expect(
            throws: WebSearchError.rejectedQuery(
                .unsafeScalar(scalarValue)
            )
        ) {
            try WebSearchQuery(rawValue)
        }
    }

    @Test("A hostile result title is refused before storage")
    func refusesHostileTitle() {
        #expect(
            throws: WebSearchResultValidationError.unsafeTitleScalar(0x202E)
        ) {
            try WebSearchResult(
                title: "Safe\u{202E}txt",
                url: URL(string: "https://example.com/page")!,
                snippet: "A normal snippet."
            )
        }
    }

    @Test("An over-length snippet is refused, not truncated")
    func refusesLongSnippet() {
        let snippet = String(
            repeating: "s", count: WebSearchLimits.maximumSnippetScalars + 1
        )
        #expect(throws: WebSearchResultValidationError.snippetTooLong) {
            try WebSearchResult(
                title: "Result",
                url: URL(string: "https://example.com/page")!,
                snippet: snippet
            )
        }
    }

    @Test("A result set over the cap is refused, not truncated")
    func refusesTooManyResults() throws {
        let result = try WebSearchResult(
            title: "Result",
            url: URL(string: "https://example.com/page")!,
            snippet: "Snippet."
        )
        let overCap = Array(
            repeating: result,
            count: WebSearchLimits.maximumResults + 1
        )
        #expect(
            throws: WebSearchResultSetError.tooManyResults(
                maximum: WebSearchLimits.maximumResults
            )
        ) {
            try WebSearchResultSet(results: overCap)
        }
    }

    @Test("Required errors expose bounded plain-language copy")
    func exposesPlainLanguageErrors() {
        #expect(
            WebSearchError.apiKeyNotConfigured.userMessage
                == "Web search isn't set up yet."
        )
        #expect(
            WebSearchError.rejectedQuery(.empty).userMessage
                == "That search isn't safe to use."
        )
        #expect(
            WebSearchError.networkFailure.userMessage
                == "I couldn't reach web search."
        )
        #expect(
            WebSearchError.timedOut.userMessage
                == "Web search took too long."
        )
        #expect(
            WebSearchError.rateLimited.userMessage
                == "Web search is busy right now. Please try again later."
        )
        #expect(
            WebSearchError.badResponse.userMessage
                == "I couldn't use the web search response."
        )
        #expect(
            WebSearchError.responseTooLarge.userMessage
                == "The web search response was too large to handle safely."
        )
    }
}

@Suite("Redacted web search audit")
struct WebSearchAuditTests {
    @Test("Audit stores lengths and counts, never query text or credentials")
    func storesOnlyRedactedMetadata() {
        let requestID = UUID()
        let event = WebSearchAuditEvent(
            requestID: requestID,
            providerHost: "api.search.brave.com",
            timestamp: Date(timeIntervalSince1970: 1_000),
            outcome: .succeeded,
            resultCount: 3,
            queryScalarCount: 17
        )

        #expect(event.requestID == requestID)
        #expect(event.providerHost == "api.search.brave.com")
        #expect(event.outcome == .succeeded)
        #expect(event.resultCount == 3)
        #expect(event.queryScalarCount == 17)
        let fields = Mirror(reflecting: event).children.compactMap(\.label)
        #expect(fields == [
            "id", "requestID", "providerHost", "timestamp", "outcome",
            "resultCount", "queryScalarCount",
        ])
    }
}

@Suite("Structurally inert web search results")
struct WebSearchStructuralSafetyTests {
    @Test("A result stores data only and exposes no authority-bearing member")
    func resultIsDataOnly() throws {
        let result = try WebSearchResult(
            title: "Result",
            url: URL(string: "https://example.com/page")!,
            snippet: "Snippet."
        )
        #expect(
            Mirror(reflecting: result).children.compactMap(\.label)
                == ["title", "url", "snippet"]
        )

        let source = try String(
            contentsOf: coreSourceURL(), encoding: .utf8
        )
        let declaration = try #require(
            source.split(
                separator: "public struct WebSearchResultSet",
                maxSplits: 1
            ).first?.split(
                separator: "public struct WebSearchResult",
                maxSplits: 1
            ).last
        )
        let forbiddenMembers = ["fetch", "approve", "authorize"]
        for member in forbiddenMembers {
            #expect(!declaration.localizedCaseInsensitiveContains(member))
        }
    }

    @Test("Search value types have no structural route to action authority")
    func typesDoNotReferenceActionAuthority() throws {
        let source = try String(
            contentsOf: coreSourceURL(), encoding: .utf8
        )
        let forbiddenTypes = [
            "ParsedApplicationCommand", "ActionPlan", "ConsentGrant",
        ]
        for typeName in forbiddenTypes {
            #expect(!source.contains(typeName))
        }
    }

    private func coreSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AvatarCore/WebSearch.swift")
    }
}
