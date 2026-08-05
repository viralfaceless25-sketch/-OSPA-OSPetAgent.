import Foundation

/// Bounds for reading one approved page.
///
/// These live in the pure layer, not the transport, so they are testable
/// offline and cannot drift apart from the type that enforces them. Every one
/// refuses rather than truncates: a silently shortened document is one a caller
/// could act on without knowing it was cut.
public enum FetchLimits: Sendable {
    /// Comfortably holds a large documentation page; far below anything that
    /// would pressure memory.
    public static let maximumResponseBytes = 2_097_152

    /// Roughly ten pages of prose — already beyond what the local model uses
    /// well.
    public static let maximumExtractedCharacters = 20_000

    public static let timeoutSeconds: TimeInterval = 15

    public static let allowedContentTypes: Set<String> = [
        "text/html", "text/plain",
    ]

    /// Compares only the media type, ignoring parameters such as `charset`.
    /// A missing header is refused rather than assumed to be text.
    public static func isAllowedContentType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let mediaType =
            rawValue
            .split(
                separator: ";",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let mediaType else { return false }
        return allowedContentTypes.contains(mediaType)
    }
}

/// Text read from an approved page, plus inert provenance metadata.
///
/// Deliberately carries no capability, plan, or action. There is no member here
/// that any executor can consume — the read path's safety rests on this type
/// being inert, not on a downstream check.
public struct FetchedDocument: Equatable, Sendable {
    public let sourceURL: URL
    public let text: String
    /// Original response bytes for redacted audit only; never page content.
    public let responseByteCount: Int

    /// Fails when the page had no usable text or exceeded the character cap.
    public init?(
        sourceURL: URL,
        text: String,
        responseByteCount: Int
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            trimmed.count <= FetchLimits.maximumExtractedCharacters,
            responseByteCount >= 0
        else {
            return nil
        }
        self.sourceURL = sourceURL
        self.text = trimmed
        self.responseByteCount = responseByteCount
    }
}
