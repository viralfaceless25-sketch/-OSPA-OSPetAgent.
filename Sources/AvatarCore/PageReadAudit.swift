import Foundation

/// Redacted outcome shape for one page-read request. Error details stay in the
/// transient user-facing status and never enter the audit record.
public enum PageReadAuditOutcome: Equatable, Sendable {
    case succeeded
    case denied
    case failed
    case cancelled
}

/// Inspectable local audit metadata for outside-world reads.
///
/// Deliberately stores only request identity, host, outcome, and byte count.
/// URL paths and fetched content can be sensitive and are never retained here.
public struct PageReadAuditEvent: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let host: String
    public let timestamp: Date
    public let outcome: PageReadAuditOutcome
    public let byteCount: Int

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        host: String,
        timestamp: Date,
        outcome: PageReadAuditOutcome,
        byteCount: Int
    ) {
        self.id = id
        self.requestID = requestID
        self.host = host
        self.timestamp = timestamp
        self.outcome = outcome
        self.byteCount = byteCount
    }
}
