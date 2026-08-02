import Foundation

/// Turns HTML into plain text. Pure and deterministic: no network, no parsing
/// library, no article heuristics.
///
/// Deliberately minimal. A cleverer extractor would be harder to reason about
/// for no safety gain, and the text is only ever read by a model and shown to
/// the user — never executed and never turned into an action.
public struct ReadabilityExtractor: Sendable {
    public init() {}

    public func extract(html: String, sourceURL: URL) -> FetchedDocument? {
        var working = html
        // Element contents, not just the tags: script and style bodies are
        // code, and emitting them would feed the model noise.
        for element in ["script", "style"] {
            working = Self.removingElement(element, from: working)
        }
        working = Self.removingComments(from: working)
        working = Self.removingTags(from: working)
        working = Self.decodingEntities(in: working)
        working = Self.collapsingWhitespace(in: working)
        return FetchedDocument(
            sourceURL: sourceURL,
            text: working,
            responseByteCount: html.utf8.count
        )
    }

    private static func removingElement(
        _ name: String, from html: String
    ) -> String {
        guard
            let expression = try? NSRegularExpression(
                pattern: "<\(name)\\b[^>]*>.*?</\(name)\\s*>",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        else { return html }
        return expression.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: " "
        )
    }

    private static func removingComments(from html: String) -> String {
        guard
            let expression = try? NSRegularExpression(
                pattern: "<!--.*?-->",
                options: [.dotMatchesLineSeparators]
            )
        else { return html }
        return expression.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: " "
        )
    }

    private static func removingTags(from html: String) -> String {
        guard
            let expression = try? NSRegularExpression(
                pattern: "<[^>]+>",
                options: [.dotMatchesLineSeparators]
            )
        else { return html }
        return expression.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: " "
        )
    }

    /// A small closed set. Unrecognized entities are left as written rather
    /// than guessed at.
    private static func decodingEntities(in text: String) -> String {
        var working = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            // Ampersand last, so a decoded value cannot form a new entity.
            ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            working = working.replacingOccurrences(of: entity, with: replacement)
        }
        return working
    }

    private static func collapsingWhitespace(in text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
