# Confidence Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Suppress uncertain validated proposals and ask a short grounded clarification instead of previewing a guess.

**Architecture:** A separate loopback evaluator receives the request, installed inventory, and already-validated proposal names. It returns one strictly parsed score plus at most two installed alternatives. `AvatarModel` evaluates after `BrainProposalValidator` and before preview; scores below 0.65 publish text only, while passing scores enter the existing preview/confirmation path unchanged.

**Tech Stack:** Swift 6, existing MLX loopback transport, Swift Testing.

## Global Constraints

- Confidence is UX tuning, never safety authority.
- Validation always runs before evaluation; invalid model output never reaches evaluator.
- A high score skips no preview, confirmation, consent, expiry, Emergency Stop, or execution gate.
- Alternatives are display-only, maximum two, and exact installed names.
- No cloud, web, external network, persistence, or new action.

### Task 1: Strict evaluator boundary

**Files:** Modify `LocalBrainService.swift`, `MLXBrainClientTests.swift`.

- [x] RED: exact score parses; missing/multiple/unknown calls, non-finite/out-of-range score, more than two alternatives, uninstalled names, and proposed-name duplicates refuse.
- [x] Add `BrainProposalConfidence`, `LocalBrainProposalEvaluating`, and `MLXBrainClient.evaluate(...)` using one closed `score_proposal` tool.
- [x] Run `swift test --filter MLXBrainClientTests` GREEN.

Interface:

```swift
public struct BrainProposalConfidence: Equatable, Sendable {
    public let score: Double
    public let alternatives: [String]
}
```

### Task 2: Pre-preview gate

**Files:** Modify targeted `AvatarModel.swift` sections and `AvatarModelBrainTests.swift`.

- [x] RED: invalid proposal never evaluates; low score publishes no proposal and grounded clarification; empty alternatives asks user to name app; high score still requires normal confirmation; evaluator failure publishes no proposal; cancellation blocks late scores.
- [x] Inject evaluator. In `startBrainProposal`, validate raw calls first, then evaluate validated proposals. Extend the generation-bound outcome so only passing confidence reaches `finishBrainProposal` publication.
- [x] Keep threshold as documented `0.65` UX constant and alternatives display-only.
- [x] Run focused suites, `graphify update .`, `make test`, and `make app`; commit/push explicit paths.
- [ ] Dispatch one read-only Step 4 reviewer. TDD-fix verified Critical/Important findings, re-run gates only if code changes, append ledger, report both steps, stop.
