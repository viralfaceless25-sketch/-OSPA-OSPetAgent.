# Sub-B Slice 1: Local Brain — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user type plain language ("i wanna listen to some music") and have OSPA propose the app they actually use, using a local model whose output is treated as untrusted and grounded against the live installed-app inventory in Swift.

**Architecture:** Pure policy in `AvatarCore` (prompt building + validation of untrusted model output), effects behind injected protocols in `AvatarPlatform` (HTTP client, Spotlight usage source, lazy server lifecycle), wiring in `AvatarCompanion` as a fallback that runs only after the existing deterministic parsers decline. A validated proposal becomes a `ParsedApplicationCommand`, after which every downstream component is existing Sub-A code, unmodified.

**Tech Stack:** Swift 6, Swift Testing, Foundation, AppKit (companion only), MLX server over loopback HTTP (`mlx_lm.server`, Qwen3-8B-4bit).

## Global Constraints

- Package targets and layering are fixed: `AvatarCore` has no AppKit and no network. `AvatarPlatform` depends on `AvatarCore`. `AvatarCompanion` depends on both. (Package.swift)
- No public API of `AvatarCore` changes shape. All 106 existing tests must stay green. (spec)
- The model never emits a bundle identifier, capability ID, `ActionPlan`, or `VisibleInteraction`. It names an app; Swift builds everything else. (spec)
- The validator is the sole safety authority. The prompt is tuned for helpfulness, never relied on for correctness. (spec)
- Exactly three tools: `open_application`, `switch_to_application`, `no_supported_action`. Any other tool name is rejected. (spec)
- Brain output never auto-executes. It produces a preview requiring the same explicit confirmation as typed input. (spec)
- The system prompt must be byte-stable across requests or MLX prompt caching misses: deterministic ordering, recency quantized to whole days, no clock/session values. (spec)
- All user-facing strings are plain language with no jargon. (spec)
- Model endpoint is loopback only: `http://127.0.0.1:8081`. Never bind or call a non-loopback host. (spec)
- Tests must not require the model server, network, or a specific machine's installed apps. Inject fakes. (spec)
- Test style matches the existing suite: Swift Testing with `@Suite`, `@Test`, `#expect`, `Issue.record`.

---

### Task 1: Inventory value type and cache-stable prompt builder

**Files:**
- Create: `Sources/AvatarCore/BrainInventory.swift`
- Test: `Tests/AvatarCoreTests/BrainPromptBuilderTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `public struct InstalledApplicationUsage: Equatable, Sendable` with
    `public let displayName: String`, `public let openCount: Int`,
    `public let lastUsedDaysAgo: Int?`, and
    `public init(displayName: String, openCount: Int, lastUsedDaysAgo: Int?)`
  - `public struct BrainPromptBuilder: Sendable` with `public init()` and
    `public func systemPrompt(for inventory: [InstalledApplicationUsage]) -> String`
  - `public static let maximumInventoryEntries = 200` on `BrainPromptBuilder`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AvatarCoreTests/BrainPromptBuilderTests.swift`:

```swift
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
        #expect(prompt.contains("App299"))
        #expect(!prompt.contains("App0 "))
    }

    @Test("Empty inventory still produces a usable prompt")
    func handlesEmptyInventory() {
        let prompt = builder.systemPrompt(for: [])
        #expect(!prompt.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BrainPromptBuilderTests`
Expected: FAIL — `cannot find 'BrainPromptBuilder' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/AvatarCore/BrainInventory.swift`:

```swift
import Foundation

/// One installed application plus how much this user actually uses it.
///
/// Usage comes from macOS itself (Spotlight metadata), so OSPA never has to
/// observe the user in the background to learn their preferences.
public struct InstalledApplicationUsage: Equatable, Sendable {
    public let displayName: String
    public let openCount: Int
    /// Whole days since last launch. `nil` means never opened.
    public let lastUsedDaysAgo: Int?

    public init(displayName: String, openCount: Int, lastUsedDaysAgo: Int?) {
        self.displayName = displayName
        self.openCount = openCount
        self.lastUsedDaysAgo = lastUsedDaysAgo
    }
}

/// Builds the model's system prompt.
///
/// Output must be byte-stable for a given inventory: MLX reuses a cached prompt
/// prefix only when the prefix matches exactly, which is what makes sending the
/// whole inventory on every request affordable. So ordering is deterministic and
/// recency is quantized to whole days. Never put a clock value in here.
public struct BrainPromptBuilder: Sendable {
    /// Bound on prompt size. The most-used apps are kept.
    public static let maximumInventoryEntries = 200

    public init() {}

    public func systemPrompt(for inventory: [InstalledApplicationUsage]) -> String {
        let ordered =
            inventory
            .sorted {
                $0.openCount == $1.openCount
                    ? $0.displayName < $1.displayName
                    : $0.openCount > $1.openCount
            }
            .prefix(Self.maximumInventoryEntries)

        let lines = ordered.map(Self.line(for:)).joined(separator: "\n")

        return """
            You help someone use their Mac. They speak normally, not in commands.
            Choose exactly one tool call for what they asked.

            These are the applications installed on this Mac, most-used first, \
            with how often this person actually opens each one:
            \(lines)

            Choose the application this person actually uses for the task, not \
            merely the one whose name matches the topic. If they ask for music \
            and they never open one music app but use another constantly, choose \
            the one they use.

            If nothing installed can do what they asked, call no_supported_action \
            and say why in one plain sentence.
            """
    }

    private static func line(for app: InstalledApplicationUsage) -> String {
        guard let days = app.lastUsedDaysAgo else {
            return "\(app.displayName) (never opened)"
        }
        let recency: String =
            switch days {
            case 0: "today"
            case 1: "1 day ago"
            default: "\(days) days ago"
            }
        return "\(app.displayName) (opened \(app.openCount) times, last used \(recency))"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BrainPromptBuilderTests`
Expected: PASS, 8 tests

- [ ] **Step 5: Confirm no existing test regressed**

Run: `make test`
Expected: PASS, 114 tests total

- [ ] **Step 6: Commit**

```bash
git add Sources/AvatarCore/BrainInventory.swift Tests/AvatarCoreTests/BrainPromptBuilderTests.swift
git commit -m "Add cache-stable brain prompt builder"
```

---

### Task 2: Untrusted tool-call validation

This is the safety core. Everything the model produces is hostile input until this
type says otherwise.

**Files:**
- Create: `Sources/AvatarCore/BrainProposal.swift`
- Test: `Tests/AvatarCoreTests/BrainProposalValidatorTests.swift`

**Interfaces:**
- Consumes: `InstalledApplicationUsage` (Task 1); existing `ParsedApplicationCommand` and `ApplicationOperation` from `Sources/AvatarCore/ApplicationCommand.swift`.
- Produces:
  - `public struct RawBrainToolCall: Equatable, Sendable` with
    `public let toolName: String`, `public let argumentsJSON: String`,
    `public init(toolName: String, argumentsJSON: String)`
  - `public enum BrainProposal: Equatable, Sendable` with cases
    `.openApplication(name: String, reason: String)`,
    `.switchToApplication(name: String, reason: String)`,
    `.noSupportedAction(reason: String)`, and
    `public var parsedApplicationCommand: ParsedApplicationCommand?`
  - `public enum BrainProposalError: Error, Equatable` with cases
    `.unknownTool(String)`, `.malformedArguments`, `.missingArgument(String)`,
    `.applicationNotInstalled(String)`, `.unsafeApplicationName`
  - `public struct BrainProposalValidator: Sendable` with `public init()` and
    `public func validate(_ call: RawBrainToolCall, installedApplicationNames: Set<String>) throws -> BrainProposal`
  - `public enum BrainTool: String, CaseIterable, Sendable` with cases
    `openApplication = "open_application"`,
    `switchToApplication = "switch_to_application"`,
    `noSupportedAction = "no_supported_action"`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AvatarCoreTests/BrainProposalValidatorTests.swift`:

```swift
import Foundation
import Testing

@testable import AvatarCore

@Suite("Brain proposal validation")
struct BrainProposalValidatorTests {
    private let validator = BrainProposalValidator()
    private let installed: Set<String> = ["Spotify", "Notes", "Google Chrome"]

    private func call(_ tool: String, _ json: String) -> RawBrainToolCall {
        RawBrainToolCall(toolName: tool, argumentsJSON: json)
    }

    @Test("A well-formed open call for an installed app is accepted")
    func acceptsOpen() throws {
        let proposal = try validator.validate(
            call("open_application", #"{"name":"Spotify","reason":"You use it for music."}"#),
            installedApplicationNames: installed
        )
        #expect(
            proposal == .openApplication(
                name: "Spotify", reason: "You use it for music."
            )
        )
    }

    @Test("A well-formed switch call for an installed app is accepted")
    func acceptsSwitch() throws {
        let proposal = try validator.validate(
            call("switch_to_application", #"{"name":"Notes","reason":"Already running."}"#),
            installedApplicationNames: installed
        )
        #expect(
            proposal == .switchToApplication(
                name: "Notes", reason: "Already running."
            )
        )
    }

    @Test("no_supported_action needs only a reason")
    func acceptsNoSupportedAction() throws {
        let proposal = try validator.validate(
            call("no_supported_action", #"{"reason":"Nothing installed can book flights."}"#),
            installedApplicationNames: installed
        )
        #expect(
            proposal == .noSupportedAction(
                reason: "Nothing installed can book flights."
            )
        )
    }

    /// Regression test for a real observed failure: Qwen3-8B proposed opening
    /// Photoshop on a Mac where Photoshop is not installed. The model is allowed
    /// to be wrong; the validator is not.
    @Test("An app that is not installed is rejected, never passed through")
    func rejectsHallucinatedApplication() {
        #expect(throws: BrainProposalError.applicationNotInstalled("Photoshop")) {
            try validator.validate(
                call("open_application", #"{"name":"Photoshop","reason":"To edit photos."}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("An unknown tool name is rejected")
    func rejectsUnknownTool() {
        #expect(throws: BrainProposalError.unknownTool("delete_everything")) {
            try validator.validate(
                call("delete_everything", #"{"name":"Spotify","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test(
        "Malformed argument JSON is rejected rather than guessed at",
        arguments: ["not json at all", "", "{\"name\":", "[]", "null"]
    )
    func rejectsMalformedArguments(json: String) {
        #expect(throws: BrainProposalError.malformedArguments) {
            try validator.validate(
                call("open_application", json),
                installedApplicationNames: installed
            )
        }
    }

    @Test("A missing or empty name is rejected")
    func rejectsMissingName() {
        #expect(throws: BrainProposalError.missingArgument("name")) {
            try validator.validate(
                call("open_application", #"{"reason":"no name here"}"#),
                installedApplicationNames: installed
            )
        }
        #expect(throws: BrainProposalError.missingArgument("name")) {
            try validator.validate(
                call("open_application", #"{"name":"   ","reason":"blank"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("A missing reason is rejected so the preview can always explain itself")
    func rejectsMissingReason() {
        #expect(throws: BrainProposalError.missingArgument("reason")) {
            try validator.validate(
                call("open_application", #"{"name":"Spotify"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("Surrounding whitespace in a name is tolerated")
    func trimsName() throws {
        let proposal = try validator.validate(
            call("open_application", #"{"name":"  Spotify  ","reason":"music"}"#),
            installedApplicationNames: installed
        )
        #expect(proposal == .openApplication(name: "Spotify", reason: "music"))
    }

    @Test(
        "Names with paths, suffixes, or control characters are refused",
        arguments: [
            "/Applications/Spotify.app",
            "Spotify.app",
            "Spotify\u{0}",
            "~/Spotify",
        ]
    )
    func rejectsUnsafeNames(name: String) {
        let json = #"{"name":"\#(name)","reason":"x"}"#
        #expect(throws: (any Error).self) {
            try validator.validate(
                call("open_application", json),
                installedApplicationNames: installed
            )
        }
    }

    @Test("An absurdly long name is refused before it reaches the resolver")
    func rejectsOverlongName() {
        let long = String(repeating: "a", count: 200)
        #expect(throws: BrainProposalError.unsafeApplicationName) {
            try validator.validate(
                call("open_application", #"{"name":"\#(long)","reason":"x"}"#),
                installedApplicationNames: installed
            )
        }
    }

    @Test("An empty installed set can never yield an app proposal")
    func rejectsEverythingWhenNothingInstalled() {
        #expect(throws: BrainProposalError.applicationNotInstalled("Spotify")) {
            try validator.validate(
                call("open_application", #"{"name":"Spotify","reason":"x"}"#),
                installedApplicationNames: []
            )
        }
    }

    @Test("An accepted open proposal converts to the existing launch command")
    func convertsToLaunchCommand() throws {
        let proposal = try validator.validate(
            call("open_application", #"{"name":"Spotify","reason":"music"}"#),
            installedApplicationNames: installed
        )
        let command = proposal.parsedApplicationCommand
        #expect(command?.operation == .launchOrActivate)
        #expect(command?.requestedApplicationName == "Spotify")
    }

    @Test("An accepted switch proposal converts to the existing switch command")
    func convertsToSwitchCommand() throws {
        let proposal = try validator.validate(
            call("switch_to_application", #"{"name":"Notes","reason":"running"}"#),
            installedApplicationNames: installed
        )
        #expect(proposal.parsedApplicationCommand?.operation == .switchToRunning)
    }

    @Test("no_supported_action yields no executable command")
    func noSupportedActionHasNoCommand() throws {
        let proposal = try validator.validate(
            call("no_supported_action", #"{"reason":"nope"}"#),
            installedApplicationNames: installed
        )
        #expect(proposal.parsedApplicationCommand == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BrainProposalValidatorTests`
Expected: FAIL — `cannot find 'BrainProposalValidator' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/AvatarCore/BrainProposal.swift`:

```swift
import Foundation

/// The closed set of tools offered to the model. Anything outside this is
/// rejected; adding a case is a deliberate change requiring new validation.
public enum BrainTool: String, CaseIterable, Sendable {
    case openApplication = "open_application"
    case switchToApplication = "switch_to_application"
    case noSupportedAction = "no_supported_action"
}

/// Exactly what the model returned, unvalidated and untrusted.
///
/// Arguments stay as raw JSON text so that parsing failures are caught by the
/// pure validator below, where they are exhaustively tested, rather than in the
/// networking layer.
public struct RawBrainToolCall: Equatable, Sendable {
    public let toolName: String
    public let argumentsJSON: String

    public init(toolName: String, argumentsJSON: String) {
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

/// A model suggestion that has been proven safe: the tool is known and any named
/// application is one that actually exists on this Mac.
public enum BrainProposal: Equatable, Sendable {
    case openApplication(name: String, reason: String)
    case switchToApplication(name: String, reason: String)
    case noSupportedAction(reason: String)

    /// Hands off to the existing typed-command pipeline. Everything downstream of
    /// this point is unchanged Sub-A code.
    public var parsedApplicationCommand: ParsedApplicationCommand? {
        switch self {
        case let .openApplication(name, _):
            ParsedApplicationCommand(
                operation: .launchOrActivate,
                requestedApplicationName: name
            )
        case let .switchToApplication(name, _):
            ParsedApplicationCommand(
                operation: .switchToRunning,
                requestedApplicationName: name
            )
        case .noSupportedAction:
            nil
        }
    }

    public var reason: String {
        switch self {
        case let .openApplication(_, reason): reason
        case let .switchToApplication(_, reason): reason
        case let .noSupportedAction(reason): reason
        }
    }
}

public enum BrainProposalError: Error, Equatable {
    case unknownTool(String)
    case malformedArguments
    case missingArgument(String)
    /// The model named an application that is not installed. Expected in normal
    /// operation, not exceptional: this is the hallucination backstop.
    case applicationNotInstalled(String)
    case unsafeApplicationName
}

/// The sole safety authority over model output.
///
/// Prompt wording cannot be relied on for correctness: making the prompt strict
/// enough to stop one model hallucinating made a larger model refuse legitimate
/// requests. So the prompt is tuned for helpfulness and every guarantee is
/// enforced here, in code, against the same inventory the model was shown.
public struct BrainProposalValidator: Sendable {
    private static let maximumNameLength = 80

    public init() {}

    public func validate(
        _ call: RawBrainToolCall,
        installedApplicationNames: Set<String>
    ) throws -> BrainProposal {
        guard let tool = BrainTool(rawValue: call.toolName) else {
            throw BrainProposalError.unknownTool(call.toolName)
        }

        let arguments = try Self.decodeArguments(call.argumentsJSON)
        let reason = try Self.requiredValue(named: "reason", from: arguments)

        switch tool {
        case .noSupportedAction:
            return .noSupportedAction(reason: reason)
        case .openApplication, .switchToApplication:
            let name = try Self.requiredValue(named: "name", from: arguments)
            try Self.validateNameShape(name)
            guard
                let installed = Self.installedMatch(
                    for: name,
                    in: installedApplicationNames
                )
            else {
                throw BrainProposalError.applicationNotInstalled(name)
            }
            return tool == .openApplication
                ? .openApplication(name: installed, reason: reason)
                : .switchToApplication(name: installed, reason: reason)
        }
    }

    private static func decodeArguments(_ json: String) throws -> [String: String] {
        guard let data = json.data(using: .utf8), !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            throw BrainProposalError.malformedArguments
        }
        return dictionary.compactMapValues { $0 as? String }
    }

    private static func requiredValue(
        named key: String,
        from arguments: [String: String]
    ) throws -> String {
        let value =
            arguments[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw BrainProposalError.missingArgument(key)
        }
        return value
    }

    /// Same shape rules the typed-command parser enforces, so the brain path can
    /// never smuggle in a target the typed path would have refused.
    private static func validateNameShape(_ name: String) throws {
        guard name.count <= maximumNameLength else {
            throw BrainProposalError.unsafeApplicationName
        }
        guard !name.lowercased().hasSuffix(".app") else {
            throw BrainProposalError.unsafeApplicationName
        }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("~")
        else {
            throw BrainProposalError.unsafeApplicationName
        }
        guard
            name.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw BrainProposalError.unsafeApplicationName
        }
    }

    /// Returns the inventory's own spelling so downstream resolution uses the
    /// canonical name rather than the model's rendering of it.
    private static func installedMatch(
        for name: String,
        in installed: Set<String>
    ) -> String? {
        installed.first { normalize($0) == normalize(name) }
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BrainProposalValidatorTests`
Expected: PASS, 18 tests (the parameterized cases count individually)

- [ ] **Step 5: Confirm no existing test regressed**

Run: `make test`
Expected: PASS, all green

- [ ] **Step 6: Commit**

```bash
git add Sources/AvatarCore/BrainProposal.swift Tests/AvatarCoreTests/BrainProposalValidatorTests.swift
git commit -m "Validate untrusted brain output against live app inventory"
```

---

### Task 3: Local brain HTTP client

**Files:**
- Create: `Sources/AvatarPlatform/LocalBrainService.swift`
- Test: `Tests/AvatarPlatformTests/MLXBrainClientTests.swift`

**Interfaces:**
- Consumes: `InstalledApplicationUsage`, `BrainPromptBuilder`, `RawBrainToolCall`, `BrainTool` (Tasks 1–2).
- Produces:
  - `public enum LocalBrainError: Error, Equatable` with cases
    `.unavailable`, `.timedOut`, `.badResponse(String)`, `.noToolCall`
  - `public protocol BrainHTTPTransport: Sendable` with
    `func post(url: URL, body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data)`
  - `public struct URLSessionBrainTransport: BrainHTTPTransport` with `public init()`
  - `public protocol LocalBrainService: Sendable` with
    `func propose(request: String, inventory: [InstalledApplicationUsage]) async throws -> RawBrainToolCall`
  - `public struct MLXBrainClient: LocalBrainService` with
    `public init(endpoint: URL = URL(string: "http://127.0.0.1:8081/v1/chat/completions")!, modelIdentifier: String = "mlx-community/Qwen3-8B-4bit", timeout: TimeInterval = 30, transport: any BrainHTTPTransport = URLSessionBrainTransport())`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AvatarPlatformTests/MLXBrainClientTests.swift`:

```swift
import AvatarCore
import Foundation
import Testing

@testable import AvatarPlatform

private struct StubTransport: BrainHTTPTransport {
    let status: Int
    let body: Data
    let error: (any Error)?

    init(status: Int = 200, body: Data = Data(), error: (any Error)? = nil) {
        self.status = status
        self.body = body
        self.error = error
    }

    func post(
        url: URL, body requestBody: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        if let error { throw error }
        return (status, body)
    }
}

/// Captures the outgoing request so we can assert what the model was shown.
private final class CapturingTransport: BrainHTTPTransport, @unchecked Sendable {
    private(set) var sentBody: Data?
    private(set) var sentURL: URL?
    let response: Data

    init(response: Data) { self.response = response }

    func post(
        url: URL, body: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        sentURL = url
        sentBody = body
        return (200, response)
    }
}

private func toolCallResponse(
    name: String = "open_application",
    arguments: String = #"{\"name\":\"Spotify\",\"reason\":\"music\"}"#
) -> Data {
    Data(
        """
        {"choices":[{"message":{"role":"assistant","tool_calls":[
        {"type":"function","function":{"name":"\(name)","arguments":"\(arguments)"}}
        ]}}]}
        """.utf8
    )
}

@Suite("MLX brain client")
struct MLXBrainClientTests {
    private let inventory = [
        InstalledApplicationUsage(
            displayName: "Spotify", openCount: 12, lastUsedDaysAgo: 0
        )
    ]

    @Test("A tool call in the response becomes a raw proposal")
    func parsesToolCall() async throws {
        let client = MLXBrainClient(transport: StubTransport(body: toolCallResponse()))
        let call = try await client.propose(
            request: "i want music", inventory: inventory
        )
        #expect(call.toolName == "open_application")
        #expect(call.argumentsJSON.contains("Spotify"))
    }

    @Test("A response with no tool call is reported, never invented")
    func rejectsMissingToolCall() async {
        let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.utf8)
        let client = MLXBrainClient(transport: StubTransport(body: body))
        await #expect(throws: LocalBrainError.noToolCall) {
            try await client.propose(request: "hello", inventory: inventory)
        }
    }

    @Test("A non-200 status is surfaced as a bad response")
    func rejectsHTTPError() async {
        let client = MLXBrainClient(
            transport: StubTransport(status: 500, body: Data("boom".utf8))
        )
        await #expect(throws: (any Error).self) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("Unparseable JSON is surfaced, never crashes")
    func rejectsUnparseableBody() async {
        let client = MLXBrainClient(transport: StubTransport(body: Data("<html>".utf8)))
        await #expect(throws: (any Error).self) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("A transport failure becomes unavailable")
    func mapsTransportFailure() async {
        struct Boom: Error {}
        let client = MLXBrainClient(transport: StubTransport(error: Boom()))
        await #expect(throws: LocalBrainError.unavailable) {
            try await client.propose(request: "x", inventory: inventory)
        }
    }

    @Test("The request targets loopback only")
    func usesLoopback() async throws {
        let transport = CapturingTransport(response: toolCallResponse())
        let client = MLXBrainClient(transport: transport)
        _ = try await client.propose(request: "i want music", inventory: inventory)
        let host = transport.sentURL?.host
        #expect(host == "127.0.0.1")
    }

    @Test("The inventory and the user request are both sent to the model")
    func sendsInventoryAndRequest() async throws {
        let transport = CapturingTransport(response: toolCallResponse())
        let client = MLXBrainClient(transport: transport)
        _ = try await client.propose(request: "i want music", inventory: inventory)
        guard let sent = transport.sentBody,
            let text = String(data: sent, encoding: .utf8)
        else {
            Issue.record("Expected a request body")
            return
        }
        #expect(text.contains("Spotify"))
        #expect(text.contains("i want music"))
        #expect(text.contains("open_application"))
        #expect(text.contains("no_supported_action"))
    }

    @Test("Sampling is deterministic so the same request behaves the same way")
    func usesGreedySampling() async throws {
        let transport = CapturingTransport(response: toolCallResponse())
        let client = MLXBrainClient(transport: transport)
        _ = try await client.propose(request: "x", inventory: inventory)
        guard let sent = transport.sentBody,
            let object = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        else {
            Issue.record("Expected a JSON body")
            return
        }
        #expect((object["temperature"] as? Double) == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MLXBrainClientTests`
Expected: FAIL — `cannot find 'MLXBrainClient' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/AvatarPlatform/LocalBrainService.swift`:

```swift
import AvatarCore
import Foundation

public enum LocalBrainError: Error, Equatable {
    case unavailable
    case timedOut
    case badResponse(String)
    case noToolCall
}

/// Injected so the client can be tested without a running model or a network.
public protocol BrainHTTPTransport: Sendable {
    func post(
        url: URL, body: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data)
}

public struct URLSessionBrainTransport: BrainHTTPTransport {
    public init() {}

    public func post(
        url: URL, body: Data, timeout: TimeInterval
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }
}

/// Turns plain language plus an app inventory into one untrusted tool call.
public protocol LocalBrainService: Sendable {
    func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> RawBrainToolCall
}

/// Talks to a local `mlx_lm.server` over loopback using the OpenAI chat
/// completions shape. Returns the model's tool call verbatim; validation is
/// deliberately somebody else's job.
public struct MLXBrainClient: LocalBrainService {
    private let endpoint: URL
    private let modelIdentifier: String
    private let timeout: TimeInterval
    private let transport: any BrainHTTPTransport
    private let promptBuilder = BrainPromptBuilder()

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:8081/v1/chat/completions")!,
        modelIdentifier: String = "mlx-community/Qwen3-8B-4bit",
        timeout: TimeInterval = 30,
        transport: any BrainHTTPTransport = URLSessionBrainTransport()
    ) {
        self.endpoint = endpoint
        self.modelIdentifier = modelIdentifier
        self.timeout = timeout
        self.transport = transport
    }

    public func propose(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) async throws -> RawBrainToolCall {
        let body = try JSONSerialization.data(
            withJSONObject: requestPayload(request: request, inventory: inventory)
        )

        let response: (status: Int, body: Data)
        do {
            response = try await transport.post(
                url: endpoint, body: body, timeout: timeout
            )
        } catch {
            throw LocalBrainError.unavailable
        }

        guard response.status == 200 else {
            throw LocalBrainError.badResponse("status \(response.status)")
        }
        return try Self.firstToolCall(in: response.body)
    }

    private func requestPayload(
        request: String,
        inventory: [InstalledApplicationUsage]
    ) -> [String: Any] {
        [
            "model": modelIdentifier,
            // Greedy: the same request should behave the same way every time.
            "temperature": 0,
            "max_tokens": 200,
            "messages": [
                [
                    "role": "system",
                    "content": promptBuilder.systemPrompt(for: inventory),
                ],
                ["role": "user", "content": request],
            ],
            "tools": Self.toolSchemas,
        ]
    }

    private static let toolSchemas: [[String: Any]] = [
        functionSchema(
            name: BrainTool.openApplication.rawValue,
            description: "Launch an installed application, or bring it to the front if it is already running.",
            properties: [
                "name": [
                    "type": "string",
                    "description": "Exact display name, copied from the installed list.",
                ],
                "reason": [
                    "type": "string",
                    "description": "One short sentence explaining why this app suits the request.",
                ],
            ],
            required: ["name", "reason"]
        ),
        functionSchema(
            name: BrainTool.switchToApplication.rawValue,
            description: "Bring an application that is already running to the front.",
            properties: [
                "name": [
                    "type": "string",
                    "description": "Exact display name, copied from the installed list.",
                ],
                "reason": ["type": "string"],
            ],
            required: ["name", "reason"]
        ),
        functionSchema(
            name: BrainTool.noSupportedAction.rawValue,
            description: "Use when no installed application can satisfy the request, or the application the person named is not installed.",
            properties: ["reason": ["type": "string"]],
            required: ["reason"]
        ),
    ]

    private static func functionSchema(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ],
            ],
        ]
    }

    private static func firstToolCall(in data: Data) throws -> RawBrainToolCall {
        guard
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw LocalBrainError.badResponse("unrecognized response shape")
        }
        guard
            let calls = message["tool_calls"] as? [[String: Any]],
            let function = calls.first?["function"] as? [String: Any],
            let name = function["name"] as? String
        else {
            throw LocalBrainError.noToolCall
        }
        let arguments = function["arguments"] as? String ?? ""
        return RawBrainToolCall(toolName: name, argumentsJSON: arguments)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MLXBrainClientTests`
Expected: PASS, 8 tests

- [ ] **Step 5: Confirm no existing test regressed**

Run: `make test`
Expected: PASS, all green

- [ ] **Step 6: Commit**

```bash
git add Sources/AvatarPlatform/LocalBrainService.swift Tests/AvatarPlatformTests/MLXBrainClientTests.swift
git commit -m "Add loopback MLX brain client behind an injected transport"
```

---

### Task 4: Spotlight application usage source

**Files:**
- Create: `Sources/AvatarPlatform/ApplicationUsageSource.swift`
- Test: `Tests/AvatarPlatformTests/ApplicationUsageSourceTests.swift`

**Interfaces:**
- Consumes: `InstalledApplicationUsage` (Task 1).
- Produces:
  - `public protocol ApplicationUsageSource: Sendable` with
    `func currentInventory() -> [InstalledApplicationUsage]`
  - `public struct SpotlightApplicationUsageSource: ApplicationUsageSource` with
    `public init(searchDirectories: [URL] = SpotlightApplicationUsageSource.standardDirectories)`
    and `public static var standardDirectories: [URL]`
  - `public static func usage(forApplicationAt url: URL, now: Date) -> InstalledApplicationUsage?`

The real Spotlight read cannot be unit-tested deterministically, so the pure
day-bucketing logic is separated out and tested directly.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AvatarPlatformTests/ApplicationUsageSourceTests.swift`:

```swift
import AvatarCore
import Foundation
import Testing

@testable import AvatarPlatform

@Suite("Application usage source")
struct ApplicationUsageSourceTests {
    @Test("Standard directories are the user-facing application folders only")
    func standardDirectories() {
        let paths = SpotlightApplicationUsageSource.standardDirectories.map(\.path)
        #expect(paths.contains("/Applications"))
        #expect(paths.contains("/System/Applications"))
    }

    @Test("Whole days are computed by calendar difference, not by rounding hours")
    func bucketsWholeDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let elevenHoursAgo = now.addingTimeInterval(-11 * 3600)
        #expect(
            SpotlightApplicationUsageSource.wholeDaysBetween(
                elevenHoursAgo, and: now
            ) == 0
        )
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        #expect(
            SpotlightApplicationUsageSource.wholeDaysBetween(
                threeDaysAgo, and: now
            ) == 3
        )
    }

    @Test("A future timestamp is clamped to today rather than going negative")
    func clampsFutureDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tomorrow = now.addingTimeInterval(86_400)
        #expect(
            SpotlightApplicationUsageSource.wholeDaysBetween(tomorrow, and: now) == 0
        )
    }

    @Test("A real inventory read returns apps and never crashes")
    func readsRealInventory() {
        let inventory = SpotlightApplicationUsageSource().currentInventory()
        #expect(!inventory.isEmpty)
        #expect(inventory.allSatisfy { !$0.displayName.isEmpty })
        #expect(inventory.allSatisfy { !$0.displayName.hasSuffix(".app") })
        #expect(inventory.allSatisfy { ($0.lastUsedDaysAgo ?? 0) >= 0 })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ApplicationUsageSourceTests`
Expected: FAIL — `cannot find 'SpotlightApplicationUsageSource' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/AvatarPlatform/ApplicationUsageSource.swift`:

```swift
import AvatarCore
import Foundation

/// Supplies the installed-app inventory the model reasons over, and that the
/// validator grounds the model's answer against.
public protocol ApplicationUsageSource: Sendable {
    func currentInventory() -> [InstalledApplicationUsage]
}

/// Reads how much each app is actually used from macOS's own Spotlight metadata
/// (`kMDItemUseCount`, `kMDItemLastUsedDate`).
///
/// This is why OSPA needs no background observer and no learned-preference
/// store: the operating system already knows, the read is one-shot and
/// read-only, and it requires no additional permission.
public struct SpotlightApplicationUsageSource: ApplicationUsageSource {
    public static var standardDirectories: [URL] {
        var directories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
        ]
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications")
        )
        return directories
    }

    private let searchDirectories: [URL]

    public init(searchDirectories: [URL] = SpotlightApplicationUsageSource.standardDirectories) {
        self.searchDirectories = searchDirectories
    }

    public func currentInventory() -> [InstalledApplicationUsage] {
        let now = Date()
        var seen = Set<String>()
        var inventory: [InstalledApplicationUsage] = []

        for directory in searchDirectories {
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )) ?? []

            for url in contents where url.pathExtension == "app" {
                guard let usage = Self.usage(forApplicationAt: url, now: now),
                    seen.insert(usage.displayName).inserted
                else { continue }
                inventory.append(usage)
            }
        }
        return inventory
    }

    /// Only top-level bundles are considered. Spotlight's raw application query
    /// also returns embedded helpers and updaters, which are not apps a person
    /// would ever ask for.
    public static func usage(
        forApplicationAt url: URL, now: Date
    ) -> InstalledApplicationUsage? {
        let name = url.deletingPathExtension().lastPathComponent
        guard !name.isEmpty else { return nil }

        guard let item = MDItemCreateWithURL(nil, url as CFURL) else {
            return InstalledApplicationUsage(
                displayName: name, openCount: 0, lastUsedDaysAgo: nil
            )
        }

        let count =
            (MDItemCopyAttribute(item, kMDItemUseCount) as? NSNumber)?.intValue
            ?? 0
        let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date

        return InstalledApplicationUsage(
            displayName: name,
            openCount: count,
            lastUsedDaysAgo: lastUsed.map { wholeDaysBetween($0, and: now) }
        )
    }

    /// Calendar-day difference, clamped at zero. Quantizing to whole days is what
    /// keeps the model's system prompt byte-stable between requests, which is
    /// what makes prompt caching work.
    public static func wholeDaysBetween(_ earlier: Date, and later: Date) -> Int {
        let days = Calendar.current.dateComponents(
            [.day], from: earlier, to: later
        ).day ?? 0
        return max(0, days)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ApplicationUsageSourceTests`
Expected: PASS, 4 tests

- [ ] **Step 5: Confirm no existing test regressed**

Run: `make test`
Expected: PASS, all green

- [ ] **Step 6: Commit**

```bash
git add Sources/AvatarPlatform/ApplicationUsageSource.swift Tests/AvatarPlatformTests/ApplicationUsageSourceTests.swift
git commit -m "Read app usage preference from macOS Spotlight metadata"
```

---

### Task 5: Lazy model server lifecycle

**Files:**
- Create: `Sources/AvatarPlatform/LocalBrainServerController.swift`
- Test: `Tests/AvatarPlatformTests/LocalBrainServerControllerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (standalone lifecycle).
- Produces:
  - `public struct LocalBrainServerConfiguration: Sendable` with
    `public let executableURL: URL`, `public let arguments: [String]`,
    `public let idleShutdownInterval: TimeInterval`,
    `public let startupTimeout: TimeInterval`, and a memberwise
    `public init(executableURL:arguments:idleShutdownInterval:startupTimeout:)`
  - `public enum LocalBrainServerState: Equatable, Sendable`: `.stopped`, `.starting`, `.ready`, `.failed(String)`
  - `public actor LocalBrainServerController` with
    `public init(launch: @Sendable @escaping () throws -> Void, terminate: @Sendable @escaping () -> Void, isHealthy: @Sendable @escaping () async -> Bool, now: @Sendable @escaping () -> Date, startupTimeout: TimeInterval, idleShutdownInterval: TimeInterval)`,
    `public func ensureReady() async -> LocalBrainServerState`,
    `public func noteRequestFinished()`,
    `public func shutdownIfIdle() async`,
    `public func shutdown()`,
    `public var state: LocalBrainServerState { get }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AvatarPlatformTests/LocalBrainServerControllerTests.swift`:

```swift
import Foundation
import Testing

@testable import AvatarPlatform

/// Mutable scoreboard shared with the controller's injected closures.
private final class Recorder: @unchecked Sendable {
    var launches = 0
    var terminations = 0
    var healthy = false
    var launchError: (any Error)?
    var now = Date(timeIntervalSince1970: 1_000_000)
}

/// Controller whose server does NOT answer until it is launched. Use this for
/// anything about launching, idle shutdown, or termination — the controller only
/// terminates a server it started itself.
private func makeLaunchingController(
    _ recorder: Recorder,
    startupTimeout: TimeInterval = 5,
    idleShutdownInterval: TimeInterval = 300
) -> LocalBrainServerController {
    LocalBrainServerController(
        launch: {
            recorder.launches += 1
            if let error = recorder.launchError { throw error }
            recorder.healthy = true
        },
        terminate: {
            recorder.terminations += 1
            recorder.healthy = false
        },
        isHealthy: { recorder.healthy },
        now: { recorder.now },
        startupTimeout: startupTimeout,
        idleShutdownInterval: idleShutdownInterval
    )
}

/// Controller whose server is already answering before it is asked. Use this for
/// adoption behavior.
private func makeController(
    _ recorder: Recorder,
    startupTimeout: TimeInterval = 5,
    idleShutdownInterval: TimeInterval = 300
) -> LocalBrainServerController {
    LocalBrainServerController(
        launch: {
            recorder.launches += 1
            if let error = recorder.launchError { throw error }
        },
        terminate: { recorder.terminations += 1 },
        isHealthy: { recorder.healthy },
        now: { recorder.now },
        startupTimeout: startupTimeout,
        idleShutdownInterval: idleShutdownInterval
    )
}

@Suite("Local brain server controller")
struct LocalBrainServerControllerTests {
    @Test("A stopped server is launched once and then reused")
    func startsOnce() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder)

        #expect(await controller.ensureReady() == .ready)
        #expect(await controller.ensureReady() == .ready)
        #expect(recorder.launches == 1)
    }

    @Test("A server already answering is adopted, never launched a second time")
    func adoptsRunningServer() async {
        let recorder = Recorder()
        recorder.healthy = true
        let controller = makeController(recorder)

        #expect(await controller.ensureReady() == .ready)
        #expect(recorder.launches == 0)
        #expect(recorder.terminations == 0)
    }

    @Test("A server this controller did not start is never terminated")
    func leavesAdoptedServerRunning() async {
        let recorder = Recorder()
        recorder.healthy = true
        let controller = makeController(recorder)

        _ = await controller.ensureReady()
        await controller.shutdown()

        #expect(recorder.terminations == 0)
    }

    @Test("A launch failure is reported and never leaves the state as ready")
    func reportsLaunchFailure() async {
        struct Boom: Error {}
        let recorder = Recorder()
        recorder.launchError = Boom()
        let controller = makeLaunchingController(recorder)

        let state = await controller.ensureReady()
        guard case .failed = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
    }

    @Test("A server that never becomes healthy times out instead of hanging")
    func timesOutWhenNeverHealthy() async {
        let recorder = Recorder()
        // Launch succeeds but the server never answers.
        let controller = LocalBrainServerController(
            launch: { recorder.launches += 1 },
            terminate: { recorder.terminations += 1 },
            isHealthy: { false },
            now: { recorder.now },
            startupTimeout: 0,
            idleShutdownInterval: 300
        )

        let state = await controller.ensureReady()
        guard case .failed = state else {
            Issue.record("Expected failed state, got \(state)")
            return
        }
    }

    @Test("An idle server is shut down and its memory returned")
    func shutsDownWhenIdle() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 60)

        _ = await controller.ensureReady()
        await controller.noteRequestFinished()

        recorder.now = recorder.now.addingTimeInterval(120)
        await controller.shutdownIfIdle()

        #expect(recorder.terminations == 1)
        #expect(await controller.state == .stopped)
    }

    @Test("A server still inside its idle window is left running")
    func keepsRecentlyUsedServer() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder, idleShutdownInterval: 600)

        _ = await controller.ensureReady()
        await controller.noteRequestFinished()

        recorder.now = recorder.now.addingTimeInterval(60)
        await controller.shutdownIfIdle()

        #expect(recorder.terminations == 0)
        #expect(await controller.state == .ready)
    }

    @Test("Shutdown is idempotent and never terminates a server twice")
    func shutdownIsIdempotent() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder)

        _ = await controller.ensureReady()
        await controller.shutdown()
        await controller.shutdown()

        #expect(recorder.terminations == 1)
    }

    @Test("A server that was never started is not terminated")
    func neverTerminatesUnstartedServer() async {
        let recorder = Recorder()
        let controller = makeLaunchingController(recorder)
        await controller.shutdown()
        #expect(recorder.terminations == 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LocalBrainServerControllerTests`
Expected: FAIL — `cannot find 'LocalBrainServerController' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/AvatarPlatform/LocalBrainServerController.swift`:

```swift
import Foundation

public struct LocalBrainServerConfiguration: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let idleShutdownInterval: TimeInterval
    public let startupTimeout: TimeInterval

    public init(
        executableURL: URL,
        arguments: [String],
        idleShutdownInterval: TimeInterval = 300,
        startupTimeout: TimeInterval = 60
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.idleShutdownInterval = idleShutdownInterval
        self.startupTimeout = startupTimeout
    }
}

public enum LocalBrainServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

/// Owns the local model server's lifetime.
///
/// The server is started on first need rather than at app launch, and released
/// once idle, because a resident model is several gigabytes: on an 18GB machine a
/// larger model measurably pushed the system into compression and swap. Only a
/// server this controller started is ever terminated.
public actor LocalBrainServerController {
    private let launchServer: @Sendable () throws -> Void
    private let terminateServer: @Sendable () -> Void
    private let isHealthy: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let startupTimeout: TimeInterval
    private let idleShutdownInterval: TimeInterval

    private var currentState: LocalBrainServerState = .stopped
    private var didLaunch = false
    private var lastRequestFinishedAt: Date?

    public init(
        launch: @Sendable @escaping () throws -> Void,
        terminate: @Sendable @escaping () -> Void,
        isHealthy: @Sendable @escaping () async -> Bool,
        now: @Sendable @escaping () -> Date,
        startupTimeout: TimeInterval = 60,
        idleShutdownInterval: TimeInterval = 300
    ) {
        self.launchServer = launch
        self.terminateServer = terminate
        self.isHealthy = isHealthy
        self.now = now
        self.startupTimeout = startupTimeout
        self.idleShutdownInterval = idleShutdownInterval
    }

    public var state: LocalBrainServerState { currentState }

    /// Starts the server if needed and waits for it to answer. Safe to call
    /// concurrently: actor isolation serializes it, so only one launch happens.
    public func ensureReady() async -> LocalBrainServerState {
        if currentState == .ready, await isHealthy() {
            return .ready
        }

        // Adopt a server that is already answering, whoever started it.
        if await isHealthy() {
            currentState = .ready
            return .ready
        }

        currentState = .starting
        do {
            try launchServer()
            didLaunch = true
        } catch {
            currentState = .failed("The local assistant could not be started.")
            return currentState
        }

        let deadline = now().addingTimeInterval(startupTimeout)
        while now() < deadline {
            if await isHealthy() {
                currentState = .ready
                return .ready
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        currentState = .failed("The local assistant took too long to start.")
        return currentState
    }

    public func noteRequestFinished() {
        lastRequestFinishedAt = now()
    }

    public func shutdownIfIdle() async {
        guard currentState == .ready, let last = lastRequestFinishedAt else {
            return
        }
        guard now().timeIntervalSince(last) >= idleShutdownInterval else {
            return
        }
        shutdown()
    }

    /// Idempotent, and only ever terminates a server this controller launched.
    public func shutdown() {
        guard didLaunch else {
            currentState = .stopped
            return
        }
        terminateServer()
        didLaunch = false
        lastRequestFinishedAt = nil
        currentState = .stopped
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LocalBrainServerControllerTests`
Expected: PASS, 8 tests

- [ ] **Step 5: Confirm no existing test regressed**

Run: `make test`
Expected: PASS, all green

- [ ] **Step 6: Commit**

```bash
git add Sources/AvatarPlatform/LocalBrainServerController.swift Tests/AvatarPlatformTests/LocalBrainServerControllerTests.swift
git commit -m "Add lazy local brain server lifecycle with idle shutdown"
```

---

### Task 6: Wire the brain into the command palette

**Files:**
- Modify: `Sources/AvatarCompanion/AvatarModel.swift` (add stored properties near the
  existing `private let` block at lines 66–103; add the fallback in
  `previewCommand()` at lines 327–349 where `interpreter.interpret` currently
  handles `.rejected`; extend `emergencyStop()` at lines 377–403)
- Modify: `README.md` (add a "Talk to it normally" section after "Ask for several things at once")

**Interfaces:**
- Consumes: `BrainProposalValidator`, `BrainProposal`, `BrainProposalError` (Task 2);
  `MLXBrainClient`, `LocalBrainService`, `LocalBrainError` (Task 3);
  `SpotlightApplicationUsageSource`, `ApplicationUsageSource` (Task 4);
  `LocalBrainServerController` (Task 5); existing `previewApplicationCommand(_:)`
  at `AvatarModel.swift:1246`.
- Produces: no new public API.

- [ ] **Step 1: Add the brain state and dependencies to AvatarModel**

Add to the `@Published` block (after line 61):

```swift
    @Published var isBrainEnabled = false
    @Published var isBrainThinking = false
    @Published var brainStatus = "Natural language is off. Type exact commands."
    @Published var brainReason: String?
```

Add to the private dependency block (after line 103):

```swift
    private let brainValidator = BrainProposalValidator()
    private let usageSource: any ApplicationUsageSource =
        SpotlightApplicationUsageSource()
    private let brainService: any LocalBrainService = MLXBrainClient()
    private var brainTask: Task<Void, Never>?
```

- [ ] **Step 2: Add the fallback branch in previewCommand()**

Replace the `case .rejected:` arm inside the `interpreter.interpret(command)`
switch (currently lines 332–336) with:

```swift
        case .rejected:
            previewedAction = nil
            pendingApplicationProposal = nil
            applicationProposalExpiresAt = nil
            if isBrainEnabled {
                // Deterministic parsing already declined, so ask the local model.
                // Typed exact commands never reach this path.
                startBrainProposal(for: command)
            } else {
                composeForegroundCommand()
            }
```

- [ ] **Step 3: Add the brain request method**

Add these private methods to `AvatarModel`:

```swift
    /// Asks the local model to interpret plain language, then treats its answer
    /// as untrusted input. A validated proposal is handed to exactly the same
    /// preview path a typed command uses, so confirmation and every gate below
    /// it are unchanged.
    private func startBrainProposal(for request: String) {
        brainTask?.cancel()
        brainReason = nil
        isBrainThinking = true
        brainStatus = "Thinking…"

        let inventory = usageSource.currentInventory()
        let installedNames = Set(inventory.map(\.displayName))
        let service = brainService
        let validator = brainValidator

        brainTask = Task { [weak self] in
            let outcome: Result<BrainProposal, any Error>
            do {
                let raw = try await service.propose(
                    request: request, inventory: inventory
                )
                outcome = .success(
                    try validator.validate(
                        raw, installedApplicationNames: installedNames
                    )
                )
            } catch {
                outcome = .failure(error)
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishBrainProposal(outcome)
            }
        }
    }

    private func finishBrainProposal(
        _ outcome: Result<BrainProposal, any Error>
    ) {
        isBrainThinking = false

        guard !safety.emergencyStopped else {
            brainStatus = "Emergency stop is active."
            return
        }

        switch outcome {
        case let .success(proposal):
            brainReason = proposal.reason
            if let command = proposal.parsedApplicationCommand {
                brainStatus = proposal.reason
                previewApplicationCommand(command)
            } else {
                brainStatus = proposal.reason
            }
        case let .failure(error):
            brainReason = nil
            brainStatus = Self.brainMessage(for: error)
        }
    }

    /// Plain language only. These strings are read by someone who does not know
    /// what a model, a port, or a tool call is.
    private static func brainMessage(for error: any Error) -> String {
        switch error {
        case BrainProposalError.applicationNotInstalled(let name):
            "\(name) isn’t installed on this Mac."
        case BrainProposalError.unknownTool, BrainProposalError.malformedArguments,
            BrainProposalError.missingArgument, BrainProposalError.unsafeApplicationName:
            "I didn’t understand that well enough to suggest something safe."
        case LocalBrainError.unavailable:
            "I can’t think right now. You can still type an exact command."
        case LocalBrainError.timedOut:
            "That took too long, so I stopped."
        case LocalBrainError.noToolCall, LocalBrainError.badResponse:
            "I couldn’t work out what to do with that."
        default:
            "Something went wrong working that out."
        }
    }
```

- [ ] **Step 4: Cancel brain work on emergency stop**

Add to `emergencyStop()`, immediately after `previewedAction = nil` (line 380):

```swift
        brainTask?.cancel()
        brainTask = nil
        isBrainThinking = false
        brainReason = nil
        brainStatus = "Emergency stop active. Thinking cancelled."
```

- [ ] **Step 5: Build and verify the whole suite still passes**

Run: `make test`
Expected: PASS, all previous tests plus the new ones green

Run: `make app`
Expected: build succeeds

- [ ] **Step 6: Manual end-to-end check**

Start the model server:

```bash
cd /Users/keyush/Models && ./.venv/bin/python -m mlx_lm server \
  --model mlx-community/Qwen3-8B-4bit --port 8081 \
  --chat-template-args '{"enable_thinking": false}'
```

Then run `open build/AvatarCompanion.app` and confirm, in order:

1. Observe-only stays on. Enable natural language. Type `i wanna listen to some music`.
   The preview names a music app you actually use, with a reason. Nothing runs.
2. Type `i want to edit this photo in photoshop` (with Photoshop not installed).
   The status reads `Photoshop isn't installed on this Mac.` and no plan appears.
3. Turn observe-only off, repeat step 1, confirm the action, and verify the app opens
   and an audit event is recorded.
4. Stop the model server, type another request, and confirm the status reads
   `I can't think right now.` while a typed `open Safari` still previews normally.
5. Start a request and press Emergency stop mid-thought. Thinking cancels and nothing
   is proposed.

- [ ] **Step 7: Document it in the README**

Add after the "Ask for several things at once" section:

````markdown
## Talk to it normally

Natural language is off until you turn it on, and it needs the local model server
running. Nothing is sent anywhere: the model runs on this Mac.

1. Turn on **Natural language**.
2. Type what you want in ordinary words, for example `i wanna listen to some music`.
3. Review the preview. It names one exact app and says why it chose it.
4. Confirm, exactly as you would for a typed command.

OSPA picks the app you actually use, not merely the one whose name matches the
topic, by reading how often you open each app from macOS itself. It never watches
you in the background to learn this.

The model only ever chooses from applications installed on this Mac. If it names
something that is not installed, OSPA refuses the suggestion and tells you the app
is missing rather than acting on it. Turning natural language on does not grant any
new ability: it can only reach actions you could already trigger by typing, and each
one still needs the same explicit confirmation.
````

- [ ] **Step 8: Commit**

```bash
git add Sources/AvatarCompanion/AvatarModel.swift README.md
git commit -m "Wire local brain into the command palette as a fallback"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: inventory type and cache-stable
prompt (Task 1); closed tool vocabulary and the validator that is the sole safety
authority, including the Photoshop hallucination regression (Task 2); loopback MLX
client with injected transport (Task 3); Spotlight usage source replacing a background
observer (Task 4); lazy start, idle shutdown, health gate, graceful degradation, and
"only stop a server you started" (Task 5); fallback-only wiring, plain-language errors,
emergency-stop cancellation, and the manual walkthrough (Task 6).

**Placeholders.** None. Every step carries the actual code or the exact command and its
expected result.

**Type consistency.** `InstalledApplicationUsage` (Task 1) is consumed unchanged by
Tasks 3, 4, and 6. `RawBrainToolCall` is produced by Task 3 and consumed by Task 2's
validator via Task 6. `BrainProposal.parsedApplicationCommand` returns the existing
`ParsedApplicationCommand`, which `previewApplicationCommand(_:)` at
`AvatarModel.swift:1246` already accepts. `BrainTool` raw values match the tool names in
Task 3's schemas and Task 2's validation exactly.

**Deliberately not covered.** Model-proposed multi-step chains and learned corrections
from rejected previews are out of scope for this slice and recorded as open questions in
the spec.
