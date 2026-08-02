import Foundation
import Testing

@testable import AvatarCore

@Suite("Fetched document bounds")
struct FetchedDocumentTests {
    private let url = URL(string: "https://example.com/page")!

    @Test("A normal page becomes a document")
    func acceptsNormalText() {
        let document = FetchedDocument(
            sourceURL: url,
            text: "Hello there.",
            responseByteCount: 128
        )
        #expect(document?.text == "Hello there.")
        #expect(document?.sourceURL == url)
        #expect(document?.responseByteCount == 128)
    }

    @Test("Surrounding whitespace is trimmed")
    func trimsText() {
        #expect(FetchedDocument(sourceURL: url, text: "  hi  ")?.text == "hi")
    }

    @Test(
        "Text that is empty once trimmed is refused",
        arguments: ["", "   ", "\n\n\t"]
    )
    func refusesEmptyText(raw: String) {
        #expect(FetchedDocument(sourceURL: url, text: raw) == nil)
    }

    /// Refuse rather than truncate: a caller must never act on a document that
    /// was silently shortened.
    @Test("Text over the cap is refused, not truncated")
    func refusesOversizeText() {
        let atCap = String(
            repeating: "a", count: FetchLimits.maximumExtractedCharacters
        )
        #expect(FetchedDocument(sourceURL: url, text: atCap)?.text.count
            == FetchLimits.maximumExtractedCharacters)

        let overCap = String(
            repeating: "a", count: FetchLimits.maximumExtractedCharacters + 1
        )
        #expect(FetchedDocument(sourceURL: url, text: overCap) == nil)
    }

    @Test("The documented limits are the ones in force")
    func limitsAreStable() {
        #expect(FetchLimits.maximumResponseBytes == 2_097_152)
        #expect(FetchLimits.maximumExtractedCharacters == 20_000)
        #expect(FetchLimits.timeoutSeconds == 15)
    }

    @Test(
        "Only HTML and plain text are accepted",
        arguments: [
            "text/html", "text/html; charset=utf-8", "TEXT/HTML",
            "text/plain", " text/plain ",
        ]
    )
    func acceptsTextContentTypes(rawValue: String) {
        #expect(FetchLimits.isAllowedContentType(rawValue))
    }

    @Test(
        "Everything else is refused",
        arguments: [
            "application/pdf", "image/png", "application/json",
            "application/octet-stream", "text/htmlx", "",
        ]
    )
    func refusesOtherContentTypes(rawValue: String) {
        #expect(!FetchLimits.isAllowedContentType(rawValue))
    }

    @Test("A missing content type is refused rather than assumed")
    func refusesMissingContentType() {
        #expect(!FetchLimits.isAllowedContentType(nil))
    }
}
