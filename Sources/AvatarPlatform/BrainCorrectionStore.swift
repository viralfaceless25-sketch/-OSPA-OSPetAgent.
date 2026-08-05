import AvatarCore
import Foundation

public protocol BrainCorrectionStoring: Sendable {
    func recordDecline(
        request: String,
        rejectedApplicationName: String
    ) async throws

    func recentCorrections(
        for request: String,
        installedApplicationNames: Set<String>,
        limit: Int
    ) async -> [BrainCorrection]

    func allCorrections() async -> [BrainCorrection]
    func clear() async throws
}

public actor BrainCorrectionStore: BrainCorrectionStoring {
    public static let maximumRecordCount = 100
    public static let maximumPromptCount = 8
    public static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent("OSPA", isDirectory: true)
        .appendingPathComponent("brain-corrections.json")

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var hasLoaded = false
    private var records: [BrainCorrection] = []

    public init(
        fileURL: URL = BrainCorrectionStore.defaultFileURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.now = now
    }

    public func recordDecline(
        request: String,
        rejectedApplicationName: String
    ) async throws {
        loadIfNeeded()
        guard let shape = BrainRequestShape.canonical(request),
            Self.isSafeApplicationName(rejectedApplicationName)
        else {
            return
        }

        records.removeAll {
            $0.requestShape == shape
                && $0.rejectedApplicationName == rejectedApplicationName
        }
        records.append(
            BrainCorrection(
                requestShape: shape,
                rejectedApplicationName: rejectedApplicationName,
                declinedAt: now()
            )
        )
        if records.count > Self.maximumRecordCount {
            records.removeFirst(records.count - Self.maximumRecordCount)
        }
        try persist()
    }

    public func recentCorrections(
        for request: String,
        installedApplicationNames: Set<String>,
        limit: Int
    ) async -> [BrainCorrection] {
        loadIfNeeded()
        guard let shape = BrainRequestShape.canonical(request) else { return [] }
        let boundedLimit = max(0, min(limit, Self.maximumPromptCount))
        return records
            .reversed()
            .filter {
                $0.requestShape == shape
                    && installedApplicationNames.contains(
                        $0.rejectedApplicationName
                    )
            }
            .prefix(boundedLimit)
            .map { $0 }
    }

    public func allCorrections() async -> [BrainCorrection] {
        loadIfNeeded()
        return records
    }

    public func clear() async throws {
        hasLoaded = true
        records = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(
                [BrainCorrection].self,
                from: data
            )
        else {
            records = []
            return
        }
        records = decoded
            .filter(Self.isValidPersistedRecord)
            .sorted { $0.declinedAt < $1.declinedAt }
            .suffix(Self.maximumRecordCount)
            .map { $0 }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func isValidPersistedRecord(
        _ record: BrainCorrection
    ) -> Bool {
        BrainRequestShape.canonical(record.requestShape) == record.requestShape
            && isSafeApplicationName(record.rejectedApplicationName)
    }

    private static func isSafeApplicationName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return !name.isEmpty && name == name.trimmingCharacters(in: .whitespaces)
            && scalars.count <= 200
            && !scalars.contains {
                switch $0.properties.generalCategory {
                case .control, .format:
                    true
                default:
                    false
                }
            }
    }
}
