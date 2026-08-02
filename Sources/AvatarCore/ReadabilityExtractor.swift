import Foundation

/// Turns HTML into plain text. Pure and deterministic: no network, no parsing
/// library, no article heuristics.
///
/// Deliberately minimal. A cleverer extractor would be harder to reason about
/// for no safety gain, and the text is only ever read by a model and shown to
/// the user — never executed and never turned into an action.
public struct ReadabilityExtractor: Sendable {
    public init() {}

    public func extract(
        html: String,
        sourceURL: URL,
        responseByteCount: Int
    ) -> FetchedDocument? {
        var working = Self.removingMarkup(from: html)
        working = Self.decodingEntities(in: working)
        working = Self.collapsingWhitespace(in: working)
        return FetchedDocument(
            sourceURL: sourceURL,
            text: working,
            responseByteCount: responseByteCount
        )
    }

    private struct Tag {
        let end: Int
        let name: String?
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    /// Removes tags with a small quote-aware scanner. Script and style bodies
    /// are raw text in HTML, so an opening element discards through its close
    /// tag or EOF. Requiring a tag-name character after `<` preserves prose
    /// such as `2 < 3 and 5 > 4`.
    private static func removingMarkup(from html: String) -> String {
        let characters = Array(html)
        var output: [Character] = []
        var index = 0

        while index < characters.count {
            if matches("<!--", at: index, in: characters) {
                output.append(" ")
                index = endOfComment(startingAt: index + 4, in: characters)
                continue
            }

            guard characters[index] == "<",
                let tag = parseTag(at: index, in: characters)
            else {
                output.append(characters[index])
                index += 1
                continue
            }

            output.append(" ")
            index = tag.end + 1
            guard !tag.isClosing, !tag.isSelfClosing,
                let name = tag.name,
                name == "script" || name == "style"
            else { continue }

            guard let closing = closingTag(
                named: name,
                startingAt: index,
                in: characters
            ) else {
                index = characters.count
                continue
            }
            index = closing.end + 1
        }

        return String(output)
    }

    private static func parseTag(
        at start: Int,
        in characters: [Character]
    ) -> Tag? {
        var cursor = start + 1
        guard cursor < characters.count else { return nil }

        var isClosing = false
        if characters[cursor] == "/" {
            isClosing = true
            cursor += 1
        }
        guard cursor < characters.count else { return nil }

        var name: String?
        if characters[cursor] == "!" || characters[cursor] == "?" {
            cursor += 1
        } else {
            let nameStart = cursor
            guard isTagNameStart(characters[cursor]) else { return nil }
            cursor += 1
            while cursor < characters.count,
                isTagNameCharacter(characters[cursor])
            {
                cursor += 1
            }
            name = String(characters[nameStart..<cursor]).lowercased()
        }

        var quote: Character?
        var lastNonWhitespace: Character?
        while cursor < characters.count {
            let character = characters[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return Tag(
                    end: cursor,
                    name: name,
                    isClosing: isClosing,
                    isSelfClosing: lastNonWhitespace == "/"
                )
            }
            if !character.isWhitespace { lastNonWhitespace = character }
            cursor += 1
        }
        return nil
    }

    private static func closingTag(
        named name: String,
        startingAt start: Int,
        in characters: [Character]
    ) -> Tag? {
        var cursor = start
        while cursor < characters.count {
            if characters[cursor] == "<",
                let tag = parseTag(at: cursor, in: characters),
                tag.isClosing,
                tag.name == name
            {
                return tag
            }
            cursor += 1
        }
        return nil
    }

    private static func endOfComment(
        startingAt start: Int,
        in characters: [Character]
    ) -> Int {
        var cursor = start
        while cursor < characters.count {
            if matches("-->", at: cursor, in: characters) {
                return cursor + 3
            }
            cursor += 1
        }
        return characters.count
    }

    private static func matches(
        _ token: String,
        at start: Int,
        in characters: [Character]
    ) -> Bool {
        let tokenCharacters = Array(token)
        guard start + tokenCharacters.count <= characters.count else {
            return false
        }
        return zip(
            characters[start..<(start + tokenCharacters.count)],
            tokenCharacters
        ).allSatisfy(==)
    }

    private static func isTagNameStart(_ character: Character) -> Bool {
        character.isLetter
    }

    private static func isTagNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
            || character == "-" || character == ":"
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
