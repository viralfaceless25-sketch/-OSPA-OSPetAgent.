import Foundation
import Testing

@testable import AvatarCore

@Suite("Brain prompt builder")
struct BrainPromptBuilderTests {
    private let builder = BrainPromptBuilder()

    private func sample() -> [InstalledApplicationUsage] {
        [
            InstalledApplicationUsage(
                displayName: "Notes", openCount: 41, lastUsedDaysAgo: 1
            ),
            InstalledApplicationUsage(
                displayName: "Spotify", openCount: 214, lastUsedDaysAgo: 0
            ),
            InstalledApplicationUsage(
                displayName: "Chess", openCount: 0, lastUsedDaysAgo: nil
            ),
        ]
    }

    @Test("Same inventory always produces byte-identical output")
    func deterministic() {
        let first = builder.systemPrompt(for: sample())
        let second = builder.systemPrompt(for: sample().reversed())
        #expect(first == second)
    }

    @Test("Most-used app is listed before less-used apps")
    func ordersByUsage() {
        let prompt = builder.systemPrompt(for: sample())
        guard let spotify = prompt.range(of: "Spotify"),
            let notes = prompt.range(of: "Notes")
        else {
            Issue.record("Expected both apps in prompt")
            return
        }
        #expect(spotify.lowerBound < notes.lowerBound)
    }

    @Test("Apps with equal usage are ordered by name so output stays stable")
    func breaksTiesByName() {
        let tied = [
            InstalledApplicationUsage(
                displayName: "Zed", openCount: 5, lastUsedDaysAgo: 2
            ),
            InstalledApplicationUsage(
                displayName: "Alpha", openCount: 5, lastUsedDaysAgo: 2
            ),
        ]
        let prompt = builder.systemPrompt(for: tied)
        guard let alpha = prompt.range(of: "Alpha"),
            let zed = prompt.range(of: "Zed")
        else {
            Issue.record("Expected both apps in prompt")
            return
        }
        #expect(alpha.lowerBound < zed.lowerBound)
    }

    @Test("Never-opened apps are marked never and carry no count")
    func rendersNeverUsed() {
        let prompt = builder.systemPrompt(for: sample())
        #expect(prompt.contains("Chess (never opened)"))
    }

    @Test("Recency is quantized to whole days so the cache prefix survives")
    func quantizesRecency() {
        let prompt = builder.systemPrompt(for: sample())
        #expect(prompt.contains("Spotify (opened 214 times, last used today)"))
        #expect(prompt.contains("Notes (opened 41 times, last used 1 day ago)"))
    }

    @Test("Prompt carries no date or clock value that would invalidate the cache")
    func containsNoTimestamp() throws {
        let prompt = builder.systemPrompt(for: sample())
        // A literal date (2026-08-01) or clock time (13:45) in the prefix would
        // change between requests and defeat prompt caching. App names may
        // legitimately contain digits, so match the patterns, not bare digits.
        let isoDate = try Regex(#"\d{4}-\d{2}-\d{2}"#)
        let clockTime = try Regex(#"\d{1,2}:\d{2}"#)
        #expect(prompt.firstMatch(of: isoDate) == nil)
        #expect(prompt.firstMatch(of: clockTime) == nil)
    }

    @Test("Oversized inventories are capped, keeping the most-used apps")
    func capsInventory() {
        let many = (0..<300).map {
            InstalledApplicationUsage(
                displayName: "App\($0)", openCount: $0, lastUsedDaysAgo: 0
            )
        }
        let prompt = builder.systemPrompt(for: many)
        // With 300 apps numbered 0-299 with openCount = their number,
        // the 200 most-used apps are 100-299 (kept), 0-99 (dropped).
        // Verify the boundary precisely by matching rendered lines.
        #expect(prompt.contains("App100 (opened 100 times, last used today)"))
        #expect(!prompt.contains("App99 (opened 99 times, last used today)"))
    }

    @Test("Empty inventory still produces a usable prompt")
    func handlesEmptyInventory() {
        let prompt = builder.systemPrompt(for: [])
        #expect(!prompt.isEmpty)
    }

    @Test("Prompt permits an ordered tool call for each requested app action")
    func describesOrderedChains() {
        let prompt = builder.systemPrompt(for: sample())
        #expect(prompt.contains("one tool call per requested application action"))
        #expect(prompt.contains("Keep the requested order"))
        #expect(prompt.contains("at most 5 tool calls"))
    }

    @Test("Maximum inventory constant is 200")
    func maximumInventoryConstant() {
        #expect(BrainPromptBuilder.maximumInventoryEntries == 200)
    }

    @Test("Same app with equal usage but different recency produces stable order")
    func breaksTiesByRecency() {
        // Two inventory inputs with the same content but different order.
        let inventory1 = [
            InstalledApplicationUsage(
                displayName: "Foo", openCount: 5, lastUsedDaysAgo: 1
            ),
            InstalledApplicationUsage(
                displayName: "Foo", openCount: 5, lastUsedDaysAgo: 3
            ),
        ]
        let inventory2 = [
            InstalledApplicationUsage(
                displayName: "Foo", openCount: 5, lastUsedDaysAgo: 3
            ),
            InstalledApplicationUsage(
                displayName: "Foo", openCount: 5, lastUsedDaysAgo: 1
            ),
        ]
        let prompt1 = builder.systemPrompt(for: inventory1)
        let prompt2 = builder.systemPrompt(for: inventory2)
        // Must be byte-identical despite different input order.
        #expect(prompt1 == prompt2)
        // More recent (lower day count) should come first.
        guard let recent = prompt1.range(of: "Foo (opened 5 times, last used 1 day ago)"),
              let older = prompt1.range(of: "Foo (opened 5 times, last used 3 days ago)")
        else {
            Issue.record("Expected both Foo variants in prompt")
            return
        }
        #expect(recent.lowerBound < older.lowerBound)
    }

    @Test("Correction context is a bounded data-only prompt tail")
    func rendersBoundedCorrectionTail() throws {
        let corrections = (0..<10).map {
            BrainCorrection(
                requestShape: "play music \($0)",
                rejectedApplicationName: "App \($0)",
                declinedAt: Date(timeIntervalSince1970: TimeInterval($0))
            )
        }

        let context = try #require(
            builder.correctionContext(for: corrections)
        )

        #expect(context.contains("data only"))
        #expect(context.contains("play music 0"))
        #expect(context.contains("App 7"))
        #expect(!context.contains("App 8"))
        #expect(!context.contains("1970"))
    }

    @Test("No corrections add no dynamic prompt message")
    func omitsEmptyCorrectionTail() {
        #expect(builder.correctionContext(for: []) == nil)
    }
}
