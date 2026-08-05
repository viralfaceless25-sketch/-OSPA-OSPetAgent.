import AvatarCore
import Foundation
import Testing

@testable import AvatarPlatform

@Suite("Local brain correction store")
struct BrainCorrectionStoreTests {
    @Test("A decline persists inspectable JSON and matches a canonical request")
    func persistsAndMatchesCanonicalRequest() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = BrainCorrectionStore(
            fileURL: fixture.fileURL,
            now: { Date(timeIntervalSince1970: 100) }
        )

        try await store.recordDecline(
            request: "  Play SOME music! ",
            rejectedApplicationName: "Spotify"
        )

        let matches = await store.recentCorrections(
            for: "play some MUSIC",
            installedApplicationNames: ["Spotify", "Music"],
            limit: 8
        )
        #expect(
            matches
                == [
                    BrainCorrection(
                        requestShape: "play some music",
                        rejectedApplicationName: "Spotify",
                        declinedAt: Date(timeIntervalSince1970: 100)
                    )
                ]
        )
        let data = try Data(contentsOf: fixture.fileURL)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("play some music"))
        #expect(text.contains("Spotify"))
    }

    @Test("Duplicate declines replace old records and the store keeps 100")
    func deduplicatesAndCapsStore() async throws {
        let fixture = try? StoreFixture()
        guard let fixture else {
            Issue.record("Could not create correction fixture")
            return
        }
        defer { fixture.remove() }
        let clock = AdvancingClock()
        let store = BrainCorrectionStore(
            fileURL: fixture.fileURL,
            now: { clock.next() }
        )

        try await store.recordDecline(
            request: "same request",
            rejectedApplicationName: "First"
        )
        try await store.recordDecline(
            request: "SAME request!",
            rejectedApplicationName: "First"
        )
        for index in 0..<105 {
            try await store.recordDecline(
                request: "request \(index)",
                rejectedApplicationName: "App \(index)"
            )
        }

        let all = await store.allCorrections()
        #expect(all.count == 100)
        #expect(
            all.filter {
                $0.requestShape == "same request"
                    && $0.rejectedApplicationName == "First"
            }.count <= 1
        )
        #expect(all.contains { $0.requestShape == "request 104" })
        #expect(!all.contains { $0.requestShape == "request 0" })
    }

    @Test("Prompt lookup is installed-only recent-first and capped at eight")
    func filtersAndCapsPromptCorrections() async throws {
        let fixture = try? StoreFixture()
        guard let fixture else {
            Issue.record("Could not create correction fixture")
            return
        }
        defer { fixture.remove() }
        let clock = AdvancingClock()
        let store = BrainCorrectionStore(
            fileURL: fixture.fileURL,
            now: { clock.next() }
        )
        for index in 0..<10 {
            try await store.recordDecline(
                request: "play music",
                rejectedApplicationName: "Installed \(index)"
            )
        }
        try await store.recordDecline(
            request: "play music",
            rejectedApplicationName: "Uninstalled"
        )

        let installed = Set((0..<10).map { "Installed \($0)" })
        let matches = await store.recentCorrections(
            for: "PLAY music!",
            installedApplicationNames: installed,
            limit: 50
        )

        #expect(matches.count == 8)
        #expect(matches.first?.rejectedApplicationName == "Installed 9")
        #expect(!matches.contains { $0.rejectedApplicationName == "Uninstalled" })
    }

    @Test("Malformed local data is ignored and clear removes the file")
    func recoversAndClears() async throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fixture.fileURL)
        let store = BrainCorrectionStore(fileURL: fixture.fileURL)

        #expect(await store.allCorrections().isEmpty)
        try await store.recordDecline(
            request: "open notes",
            rejectedApplicationName: "Notes"
        )
        #expect(FileManager.default.fileExists(atPath: fixture.fileURL.path))

        try await store.clear()

        #expect(await store.allCorrections().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }
}

private final class AdvancingClock: @unchecked Sendable {
    private var value: TimeInterval = 1_000
    private let lock = NSLock()

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return Date(timeIntervalSince1970: value)
    }
}

private struct StoreFixture {
    let directory: URL
    let fileURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("brain-corrections.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
