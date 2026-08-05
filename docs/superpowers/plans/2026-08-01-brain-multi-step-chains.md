# Brain Multi-Step Chains Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the local brain propose up to five ordered application actions that preview as one numbered list and run through the existing `TaskSequence` confirmation path, while refusing the entire chain if any call is invalid or cannot be planned.

**Architecture:** `MLXBrainClient` returns every raw tool call without trusting any of them. `BrainProposalValidator` owns atomic array validation and enforces `TaskSequence.maximumSteps`; it returns no proposals when any element fails. `AvatarModel` converts a fully validated array into either the existing single-application preview or a complete `TaskSequence`, embedding each validated reason in that step's user-visible summary and binding brain ownership to the published proposal/sequence ID for lifecycle cleanup.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, existing `AvatarCore` policy types, loopback MLX OpenAI-compatible chat completions.

## Global Constraints

- `AvatarCore` remains pure: no AppKit, network, or side effects.
- Model output remains untrusted until every call passes `BrainProposalValidator`.
- Accept 1 through `TaskSequence.maximumSteps` (5) calls; reject empty or oversized arrays.
- If any call fails validation or planning, publish nothing from the chain.
- A mixed chain containing `no_supported_action` publishes no executable subset.
- Existing one-shot, per-step consent and `TaskSequenceRunner` execution remain unchanged.
- Preview every step in model order before one explicit confirmation.
- No router, evaluator, cloud, web, persistence, or new capability.

---

### Task 1: Atomic validator and prompt contract

**Files:**
- Modify: `Sources/AvatarCore/BrainProposal.swift`
- Modify: `Sources/AvatarCore/BrainInventory.swift`
- Modify: `Tests/AvatarCoreTests/BrainProposalValidatorTests.swift`
- Modify: `Tests/AvatarCoreTests/BrainPromptBuilderTests.swift`

**Interfaces:**
- Consumes: `RawBrainToolCall`, `TaskSequence.maximumSteps`, installed display-name set.
- Produces: `BrainProposalValidator.validate(_:installedApplicationNames:) throws -> [BrainProposal]` overload, with `BrainProposalError.noToolCalls` and `.tooManyToolCalls`.

- [ ] **Step 1: Write failing validator tests**

Add tests proving the array overload preserves order, returns every valid proposal, rejects an invalid later call without returning the valid prefix, rejects zero calls, and rejects six calls. The atomicity test must place a valid installed-app call first and an unknown tool second.

```swift
@Test("A later invalid call refuses the whole brain chain")
func rejectsWholeChainWhenLaterCallIsInvalid() {
    let calls = [
        RawBrainToolCall(
            toolName: "open_application",
            argumentsJSON: #"{"name":"Safari","reason":"Browse first."}"#
        ),
        RawBrainToolCall(toolName: "run_shell", argumentsJSON: #"{}"#),
    ]

    #expect(throws: BrainProposalError.unknownTool("run_shell")) {
        try validator.validate(calls, installedApplicationNames: ["Safari"])
    }
}
```

- [ ] **Step 2: Run the focused validator suite and verify RED**

Run: `swift test --filter BrainProposalValidatorTests`

Expected: compilation fails because the array validation overload and new errors do not exist.

- [ ] **Step 3: Implement minimal atomic array validation**

Add the two errors and overload. Enforce count before mapping; map through the existing single-call method so there is one safety authority and no partially returned array.

```swift
public func validate(
    _ calls: [RawBrainToolCall],
    installedApplicationNames: Set<String>
) throws -> [BrainProposal] {
    guard !calls.isEmpty else { throw BrainProposalError.noToolCalls }
    guard calls.count <= TaskSequence.maximumSteps else {
        throw BrainProposalError.tooManyToolCalls
    }
    return try calls.map {
        try validate($0, installedApplicationNames: installedApplicationNames)
    }
}
```

- [ ] **Step 4: Add a failing prompt behavior test**

Assert the emitted system prompt instructs the model to preserve requested order, emit one tool call per requested application action, and cap the list at five. This catches a regression back to the current singular instruction.

- [ ] **Step 5: Run the prompt suite and verify RED**

Run: `swift test --filter BrainPromptBuilderTests`

Expected: the new chain instruction assertion fails against “Choose exactly one tool call”.

- [ ] **Step 6: Update the byte-stable prompt and verify GREEN**

Keep the inventory block and deterministic ordering unchanged. Replace only the singular selection instruction with stable text explaining one call for a single action or one ordered call per requested application action, maximum five.

Run: `swift test --filter BrainProposalValidatorTests && swift test --filter BrainPromptBuilderTests`

Expected: both suites pass.

- [ ] **Step 7: Commit Task 1**

```bash
git add Sources/AvatarCore/BrainProposal.swift Sources/AvatarCore/BrainInventory.swift Tests/AvatarCoreTests/BrainProposalValidatorTests.swift Tests/AvatarCoreTests/BrainPromptBuilderTests.swift
git commit -m "Validate brain tool-call chains atomically"
```

---

### Task 2: Preserve every raw model call

**Files:**
- Modify: `Sources/AvatarPlatform/LocalBrainService.swift`
- Modify: `Tests/AvatarPlatformTests/MLXBrainClientTests.swift`
- Modify: `Tests/AvatarCompanionTests/AvatarModelBrainTests.swift` (test doubles only in this task)

**Interfaces:**
- Consumes: OpenAI-compatible `message.tool_calls` array.
- Produces: `LocalBrainService.propose(request:inventory:) async throws -> [RawBrainToolCall]` in original order.

- [ ] **Step 1: Write failing client tests**

Change the response helper to accept several complete tool-call objects. Add a test with two calls and distinct names/reasons that asserts both raw calls are returned in order. Add a malformed-second-entry test proving the first entry is not returned alone.

```swift
let calls = try await client.propose(request: "open both", inventory: inventory)
#expect(calls.map(\.toolName) == ["open_application", "switch_to_application"])
#expect(calls[0].argumentsJSON.contains("Spotify"))
#expect(calls[1].argumentsJSON.contains("Music"))
```

- [ ] **Step 2: Run the client suite and verify RED**

Run: `swift test --filter MLXBrainClientTests`

Expected: compilation fails because `propose` returns one `RawBrainToolCall`.

- [ ] **Step 3: Implement all-call parsing**

Change the protocol/client result to an array. Rename `firstToolCall(in:)` to `toolCalls(in:)`, require a non-empty array, and use throwing `map` rather than `compactMap` so one malformed entry refuses the response. Preserve non-string `arguments` as an empty string so `BrainProposalValidator` rejects it as malformed. Increase the deterministic response token budget enough for five short calls.

- [ ] **Step 4: Update companion test doubles for the new protocol**

`RecordingBrainService` stores `.proposals([RawBrainToolCall])`; `ControlledBrainService` resumes with an array. Existing single-proposal fixtures become one-element arrays without changing their assertions.

- [ ] **Step 5: Verify GREEN**

Run: `swift test --filter MLXBrainClientTests`

Expected: all client tests pass, including ordered multi-call parsing and malformed-entry refusal.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/AvatarPlatform/LocalBrainService.swift Tests/AvatarPlatformTests/MLXBrainClientTests.swift Tests/AvatarCompanionTests/AvatarModelBrainTests.swift
git commit -m "Preserve ordered brain tool-call responses"
```

---

### Task 3: Publish one complete brain sequence

**Files:**
- Modify: `Sources/AvatarCompanion/AvatarModel.swift`
- Modify: `Tests/AvatarCompanionTests/AvatarModelBrainTests.swift`

**Interfaces:**
- Consumes: atomically validated `[BrainProposal]`.
- Produces: existing single `ApplicationActionProposal` for one executable call, or existing `TaskSequence` for 2...5 executable calls.
- Preserves: `TaskSequenceValidator` and `TaskSequenceRunner` unchanged, including per-step grants.

- [ ] **Step 1: Write failing model tests**

Add tests using two uniquely resolvable installed applications:

1. Two valid calls publish one `pendingTaskSequence`, in original order, with each validated reason visible in its numbered step summary; no single application proposal is published.
2. Valid first call plus invalid second call publishes neither `pendingTaskSequence` nor `pendingApplicationProposal`.
3. Two valid calls followed by `no_supported_action` publish no executable subset.
4. Disabling the brain clears a brain-originated pending sequence, while typed task-sequence behavior remains unchanged.

The production mutation each test catches is respectively: dropping/reordering later calls, publishing a valid prefix, treating unsupported as skippable, and leaving a brain-created action confirmable after disabling its source.

- [ ] **Step 2: Run the companion brain suite and verify RED**

Run: `swift test --filter AvatarModelBrainTests`

Expected: the new chain tests fail because the model still expects one proposal and has no brain-sequence ownership binding.

- [ ] **Step 3: Make brain ownership one structural binding**

Replace the application-only private binding with one enum/small immutable value representing either `(planID, reason)` or `sequenceID`. Derive `brainReason` only from the application case. Reconcile it from both `pendingApplicationProposal.didSet` and `pendingTaskSequence.didSet`. Clearing/cancelling a brain-originated proposal switches on this one binding and clears the matching pending object plus expiry where applicable.

- [ ] **Step 4: Validate all calls before the main actor publishes anything**

In `startBrainProposal`, request `[RawBrainToolCall]` and call the new array validator. Change the async outcome to `Result<[BrainProposal], any Error>`.

- [ ] **Step 5: Build and publish the complete preview atomically**

Keep the one-call path behavior-compatible. For 2...5 proposals, first require every proposal to have a `parsedApplicationCommand`; if any is `no_supported_action`, set a plain-language refusal and publish nothing. Convert the complete list to private immutable preview inputs `(command, validated reason)`, plan every step into a local array, and assign `pendingTaskSequence` only after all planning succeeds. Format summaries as `Open App — validated reason` or `Switch to App — validated reason`, which the existing numbered SwiftUI card already renders before confirmation. Bind the resulting sequence ID after publication.

- [ ] **Step 6: Verify focused GREEN and existing consent behavior**

Run:

```bash
swift test --filter AvatarModelBrainTests
swift test --filter TaskSequenceTests
```

Expected: brain suite passes; existing ordered execution, first-failure halt, Emergency Stop, and per-step one-shot consent tests remain green without changes to runner policy.

- [ ] **Step 7: Commit Task 3**

```bash
git add Sources/AvatarCompanion/AvatarModel.swift Tests/AvatarCompanionTests/AvatarModelBrainTests.swift
git commit -m "Preview validated brain chains atomically"
```

---

### Task 4: Review, fix rounds, verification, and ledger

**Files:**
- Append: `.superpowers/sdd/2026-08-01-brain-multi-step-chains/progress.md`
- Modify only if review finds an issue: files above and their tests.

**Interfaces:**
- Review range starts at the commit immediately before Task 1.
- Completion requires no open Critical or Important finding.

- [ ] **Step 1: Rebuild the graph after code edits**

Run: `graphify update .`

Expected: deterministic code-only incremental rebuild; never run bare `graphify .`.

- [ ] **Step 2: Run fresh full verification**

Run:

```bash
make test
make app
git diff --check
```

Record exact test count and app-build result.

- [ ] **Step 3: Commit any final verification-only documentation changes**

Stage explicit paths only.

- [ ] **Step 4: Dispatch a separate read-only reviewer**

Review the full Step 1 diff against `docs/superpowers/ROADMAP-codex.md` Step 1 and this plan. Require adversarial checks for partial publication, oversized/malformed call arrays, model reasons in consent preview, binding lifecycle, and unchanged per-step consent.

- [ ] **Step 5: Process findings**

Verify each finding against the code. Fix every Critical/Important item using a new failing test first, rerun scoped tests, and request a scoped re-review. Record Minor items in the ledger if deliberately deferred. Stop after five fix rounds and ask the user if significant findings remain.

- [ ] **Step 6: Re-run final gates after the last fix**

Run `graphify update .`, `make test`, `make app`, and `git diff --check` fresh.

- [ ] **Step 7: Append the final ledger entry, commit, and push**

Record design choices, red/green evidence, review range and findings, fixes, exact test delta from 194, app build result, uncertainties, and deliberate non-goals. Commit tracked changes with explicit paths and push `feat/sub-b-local-brain`.
