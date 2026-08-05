# Learned Corrections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remember brain-originated app proposals the user declines and feed bounded, installed-app-grounded negative hints into later local proposals.

**Architecture:** An actor-backed JSON store under Application Support owns canonicalization, caps, atomic persistence, inspection, and clearing. `AvatarModel` binds the originating request to a brain proposal and records only an explicit decline. `MLXBrainClient` appends relevant corrections after the byte-stable inventory system message so the cached prefix remains reusable; `BrainProposalValidator` remains unchanged and authoritative.

**Tech Stack:** Swift 6, Foundation JSON/FileManager, SwiftUI, Swift Testing.

## Global Constraints

- Local file only; no network or telemetry.
- Maximum 100 stored records and 8 prompt records.
- Stored app names are filtered against the current installed inventory before prompting.
- Corrections never create a proposal or bypass `BrainProposalValidator`.
- README states the exact path and clear instructions.

### Task 1: Bounded persistent store

**Files:** Create `Sources/AvatarCore/BrainCorrection.swift`, `Sources/AvatarPlatform/BrainCorrectionStore.swift`; test both targets.

- [ ] Write RED tests for canonical equivalent requests, deduplication, 100-record eviction, malformed-file recovery, atomic local persistence, inspection, and clear.
- [ ] Run `swift test --filter BrainCorrection` and confirm missing types fail.
- [ ] Implement `BrainCorrection`, `BrainRequestShape`, `BrainCorrectionStoring`, and actor `BrainCorrectionStore` with injected file URL/date.
- [ ] Run focused tests GREEN.

Core interface:

```swift
public struct BrainCorrection: Codable, Equatable, Sendable {
    public let requestShape: String
    public let rejectedApplicationName: String
    public let declinedAt: Date
}
```

### Task 2: Stable prompt tail and unchanged validation

**Files:** Modify `BrainInventory.swift`, `LocalBrainService.swift`, and their tests.

- [ ] RED: assert base system prompt bytes are unchanged; correction context is a later message, capped at 8, contains only installed app names, and does not alter raw-call validation.
- [ ] Add a correction-aware `propose` overload with a default protocol implementation for existing fakes.
- [ ] Render corrections as bounded data-only guidance after the stable inventory message.
- [ ] Run `BrainPromptBuilderTests`, `MLXBrainClientTests`, and `BrainProposalValidatorTests` GREEN.

### Task 3: Decline, inspect, and clear

**Files:** Modify targeted sections of `AvatarModel.swift`, `AvatarView.swift`, `AvatarModelBrainTests.swift`, and `README.md`.

- [ ] RED: brain decline records request/app; typed decline does not; next canonical request receives correction; clear empties store; replacement/expiry/confirmation do not record.
- [ ] Bind request+reason+plan ID in one immutable brain binding. Add `declineApplicationAction()` and `clearBrainCorrections()`.
- [ ] Add **Not this app** beside confirmation and a visible learned-corrections status/clear control.
- [ ] Document `~/Library/Application Support/OSPA/brain-corrections.json` and UI/file deletion clearing.
- [ ] Run focused suites, `graphify update .`, `make test`, and `make app`; commit/push explicit paths.
- [ ] Dispatch one read-only Step 3 reviewer. TDD-fix verified Critical/Important findings, re-run gates only if code changes, append ledger.
