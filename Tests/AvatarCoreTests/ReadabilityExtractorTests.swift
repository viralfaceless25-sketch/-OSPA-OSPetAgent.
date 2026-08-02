import Foundation
import Testing

@testable import AvatarCore

@Suite("Readability extraction")
struct ReadabilityExtractorTests {
    private let extractor = ReadabilityExtractor()
    private let url = URL(string: "https://example.com/page")!

    private func extract(
        _ html: String,
        responseByteCount: Int? = nil
    ) -> FetchedDocument? {
        extractor.extract(
            html: html,
            sourceURL: url,
            responseByteCount: responseByteCount ?? html.utf8.count
        )
    }

    @Test("Tags are removed and text survives")
    func extractsText() {
        let html = "<html><body><h1>Title</h1><p>Body text.</p></body></html>"
        #expect(extract(html)?.text == "Title Body text.")
    }

    /// Script and style bodies are code, not prose. Emitting them would feed
    /// the model noise and could smuggle instruction-shaped text.
    @Test("Script and style contents never appear in the text")
    func stripsScriptAndStyle() {
        let html = """
            <html><head><style>body { color: red; }</style></head>
            <body><script>alert("run me")</script><p>Real text.</p></body></html>
            """
        let text = try? #require(extract(html)?.text)
        #expect(text == "Real text.")
    }

    @Test(
        "Unterminated script and style contents are discarded through EOF",
        arguments: [
            "<p>Before</p><script>ignore()",
            "<p>Before</p><style>.ignore { color: red; }",
        ]
    )
    func stripsUnterminatedRawText(html: String) {
        #expect(extract(html)?.text == "Before")
    }

    @Test("Comments are removed")
    func stripsComments() {
        let html = "<p>Before<!-- hidden note -->After</p>"
        let text = extract(html)?.text
        #expect(text?.contains("hidden") == false)
    }

    @Test("Common entities are decoded")
    func decodesEntities() {
        let html = "<p>Tom &amp; Jerry &lt;3 &quot;quotes&quot;&nbsp;here</p>"
        #expect(extract(html)?.text == "Tom & Jerry <3 \"quotes\" here")
    }

    @Test("Whitespace is collapsed to single spaces")
    func collapsesWhitespace() {
        let html = "<p>One\n\n   two\t\tthree</p>"
        #expect(extract(html)?.text == "One two three")
    }

    @Test("Extraction is deterministic")
    func isDeterministic() {
        let html = "<html><body><p>Same every time.</p></body></html>"
        #expect(extract(html) == extract(html))
    }

    @Test(
        "A page with no readable text yields nothing",
        arguments: [
            "<html><body></body></html>",
            "<html><body><script>only()</script></body></html>",
            "   ",
        ]
    )
    func refusesEmptyPages(html: String) {
        #expect(extract(html) == nil)
    }

    @Test("A page over the character cap is refused, not truncated")
    func refusesOversizePage() {
        let long = String(
            repeating: "word ", count: FetchLimits.maximumExtractedCharacters
        )
        #expect(extract("<p>\(long)</p>") == nil)
    }

    @Test("Plain text with no markup passes through")
    func handlesPlainText() {
        #expect(extract("Just words.")?.text == "Just words.")
    }

    @Test("Quoted greater-than signs do not end a tag")
    func handlesGreaterThanInAttribute() {
        let html = #"<p title="1 > 0">Visible</p>"#
        #expect(extract(html)?.text == "Visible")
    }

    @Test("Plain-text comparisons are not mistaken for tags")
    func preservesComparisons() {
        let text = "2 < 3 and 5 > 4"
        #expect(extract(text)?.text == text)
    }

    @Test("Transport byte count is preserved exactly")
    func preservesResponseByteCount() {
        #expect(extract("Words", responseByteCount: 12_345)?.responseByteCount
            == 12_345)
    }
}
