import Foundation
import Testing

@testable import AvatarCore

@Suite("Readability extraction")
struct ReadabilityExtractorTests {
    private let extractor = ReadabilityExtractor()
    private let url = URL(string: "https://example.com/page")!

    @Test("Tags are removed and text survives")
    func extractsText() {
        let html = "<html><body><h1>Title</h1><p>Body text.</p></body></html>"
        #expect(extractor.extract(html: html, sourceURL: url)?.text
            == "Title Body text.")
    }

    /// Script and style bodies are code, not prose. Emitting them would feed
    /// the model noise and could smuggle instruction-shaped text.
    @Test("Script and style contents never appear in the text")
    func stripsScriptAndStyle() {
        let html = """
            <html><head><style>body { color: red; }</style></head>
            <body><script>alert("run me")</script><p>Real text.</p></body></html>
            """
        let text = try? #require(extractor.extract(html: html, sourceURL: url)?.text)
        #expect(text == "Real text.")
    }

    @Test("Comments are removed")
    func stripsComments() {
        let html = "<p>Before<!-- hidden note -->After</p>"
        let text = extractor.extract(html: html, sourceURL: url)?.text
        #expect(text?.contains("hidden") == false)
    }

    @Test("Common entities are decoded")
    func decodesEntities() {
        let html = "<p>Tom &amp; Jerry &lt;3 &quot;quotes&quot;&nbsp;here</p>"
        #expect(extractor.extract(html: html, sourceURL: url)?.text
            == "Tom & Jerry <3 \"quotes\" here")
    }

    @Test("Whitespace is collapsed to single spaces")
    func collapsesWhitespace() {
        let html = "<p>One\n\n   two\t\tthree</p>"
        #expect(extractor.extract(html: html, sourceURL: url)?.text
            == "One two three")
    }

    @Test("Extraction is deterministic")
    func isDeterministic() {
        let html = "<html><body><p>Same every time.</p></body></html>"
        #expect(extractor.extract(html: html, sourceURL: url)
            == extractor.extract(html: html, sourceURL: url))
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
        #expect(extractor.extract(html: html, sourceURL: url) == nil)
    }

    @Test("A page over the character cap is refused, not truncated")
    func refusesOversizePage() {
        let long = String(
            repeating: "word ", count: FetchLimits.maximumExtractedCharacters
        )
        #expect(extractor.extract(html: "<p>\(long)</p>", sourceURL: url) == nil)
    }

    @Test("Plain text with no markup passes through")
    func handlesPlainText() {
        #expect(extractor.extract(html: "Just words.", sourceURL: url)?.text
            == "Just words.")
    }
}
