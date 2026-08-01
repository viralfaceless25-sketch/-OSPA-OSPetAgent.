# Intent Router Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify otherwise-unparsed natural-language requests as `native_app`, `chat`, or `unsupported` before the existing app proposal path, so OSPA reports unsupported current/web requests honestly.

**Architecture:** Add a strict local routing boundary whose model call receives only the request and three zero-argument tools—never the app inventory or action arguments. `native_app` calls the existing `startBrainProposal(for:)` path unchanged, `chat` starts a separate text-only local-model call, and `unsupported` publishes fixed local copy without any second call. Router output can choose a lane only; `BrainProposalValidator` remains the sole authority for every native app proposal.

**Tech Stack:** Swift 6, Swift Testing, existing loopback OpenAI-compatible MLX transport, AppKit/SwiftUI model wiring.

## Global Constraints

- The router selects exactly one of `native_app`, `chat`, or `unsupported`; it never selects an app, emits action arguments, or constructs a plan.
- Every `native_app` result enters the existing slice-1 proposal and `BrainProposalValidator` path unchanged.
- `chat` may publish one trimmed paragraph of 1...2,000 Unicode scalars with no control or format characters, but no proposal, plan, consent, or executable action.
- `unsupported` publishes `“I can’t browse the web or use current online information yet. I can open or switch Mac apps, or chat about things that don’t need current information.”` and no action.
- No web access, external network, router persistence, cloud escalation, evaluator, or new action kind.
- Existing deterministic typed parsing remains ahead of the router.

---

### Task 1: Strict Local Routing and Chat Boundaries

**Files:**
- Modify: `Sources/AvatarPlatform/LocalBrainService.swift`
- Modify: `Tests/AvatarPlatformTests/MLXBrainClientTests.swift`

**Interfaces:**
- Produces: `LocalBrainIntentLane`, `LocalBrainIntentRouting.route(request:)`, and `LocalBrainChatService.answer(request:)`.
- Preserves: `LocalBrainService.propose(request:inventory:)` and its payload/parser behavior.

- [ ] **Step 1: Write failing router tests**

Add transport-level tests proving the wished-for API and wire contract:

```swift
let lane = try await client.route(request: "what's the weather in Tokyo")
#expect(lane == .unsupported)
```

Capture the request body and assert it contains exactly the three zero-argument route tools, contains no installed-app inventory, uses greedy sampling, and asks for exactly one tool. Add malformed-boundary cases: missing, multiple, unknown, non-empty-argument, and malformed route calls are refused rather than guessed.

- [ ] **Step 2: Run router tests and verify RED**

Run: `swift test --filter MLXBrainClientTests`

Expected: compile failures because routing types and `route(request:)` do not exist.

- [ ] **Step 3: Implement the minimal routing boundary**

Add:

```swift
public enum LocalBrainIntentLane: String, Equatable, Sendable {
    case nativeApp = "native_app"
    case chat
    case unsupported
}

public protocol LocalBrainIntentRouting: Sendable {
    func route(request: String) async throws -> LocalBrainIntentLane
}
```

Make `MLXBrainClient` conform. Its route request has no inventory and exactly three empty-object tool schemas. Parse exactly one tool call, require its arguments to decode as an empty JSON object, and map only an exact allowlisted tool name.

- [ ] **Step 4: Verify routing GREEN**

Run: `swift test --filter MLXBrainClientTests`

Expected: all existing proposal tests plus new routing tests pass.

- [ ] **Step 5: Write failing chat-boundary tests**

Test that `answer(request:)` sends no tools or inventory, accepts one bounded non-empty `message.content`, and refuses empty, overlong, control/format-character, malformed, and non-200 output. The production mutation caught is returning arbitrary untrusted model text directly to the UI.

- [ ] **Step 6: Run chat tests and verify RED**

Run: `swift test --filter MLXBrainClientTests`

Expected: compile failures because `LocalBrainChatService` and `answer(request:)` do not exist.

- [ ] **Step 7: Implement minimal offline chat response handling**

Add:

```swift
public protocol LocalBrainChatService: Sendable {
    func answer(request: String) async throws -> String
}
```

Use a separate text-only payload with no tools, a fixed offline/no-current-data system prompt, greedy sampling, and `max_tokens: 600`. Trim the returned text; accept 1...2,000 Unicode scalars and reject control/format characters before publication. Do not introduce any action representation.

- [ ] **Step 8: Verify Task 1 and commit**

Run: `swift test --filter MLXBrainClientTests`

Stage explicit paths and commit:

```bash
git add Sources/AvatarPlatform/LocalBrainService.swift Tests/AvatarPlatformTests/MLXBrainClientTests.swift
git commit -m "feat(brain): add closed intent routing"
git push
```

---

### Task 2: Route AvatarModel Fallbacks Without Bypassing Validation

**Files:**
- Modify: `Sources/AvatarCompanion/AvatarModel.swift`
- Modify: `Tests/AvatarCompanionTests/AvatarModelBrainTests.swift`

**Interfaces:**
- Consumes: `LocalBrainIntentRouting`, `LocalBrainChatService`, and unchanged `LocalBrainService`.
- Preserves: deterministic parser precedence, `startBrainProposal(for:)`, `finishBrainProposal(_:)`, and `BrainProposalValidator` use.

- [ ] **Step 1: Write failing model-routing tests**

Add deterministic fakes and tests for observable behavior:

```swift
// unsupported
model.command = "what's the weather in Tokyo"
model.previewCommand()
await waitUntil { !model.isBrainThinking }
#expect(model.pendingApplicationProposal == nil)
#expect(model.pendingTaskSequence == nil)
#expect(model.brainStatus.contains("can’t browse"))
```

Also prove: a `chat` lane publishes validated text and no action; a `native_app` lane calls the existing proposal service and still rejects an invalid proposal through `BrainProposalValidator`; exact typed commands and deterministic foreground composition never call the router; disabling brain, Emergency Stop, and exact search replacement cancel a routing/chat task so late results cannot publish.

- [ ] **Step 2: Run model tests and verify RED**

Run: `swift test --filter AvatarModelBrainTests`

Expected: compile failures for the new injected router/chat interfaces or behavior failures because all unparsed requests still call the app proposal service directly.

- [ ] **Step 3: Implement classification-only orchestration**

Inject router and chat services into `AvatarModel`. Replace only the final unparsed fallback call with `startBrainRouting(for:)`. On completion:

```swift
switch lane {
case .nativeApp:
    startBrainProposal(for: request)
case .chat:
    startBrainChat(for: request)
case .unsupported:
    clear action previews and publish fixed unsupported copy
}
```

Reuse the existing brain task cancellation, idle shutdown, Emergency Stop, and late-result guard. Do not move, duplicate, weaken, or bypass the existing validator call in `startBrainProposal(for:)`.

- [ ] **Step 4: Verify model GREEN**

Run: `swift test --filter AvatarModelBrainTests`

Expected: all model brain tests pass, including weather honesty, chat no-action, native validation continuity, deterministic precedence, and cancellation.

- [ ] **Step 5: Update graph and commit**

Run: `graphify update .`

Stage explicit paths and commit:

```bash
git add Sources/AvatarCompanion/AvatarModel.swift Tests/AvatarCompanionTests/AvatarModelBrainTests.swift
git commit -m "feat(brain): route natural language honestly"
git push
```

---

### Task 3: Review, Fix Rounds, and Final Gates

**Files:**
- Modify only files required by verified review findings.
- Append: `.superpowers/sdd/2026-08-01-intent-router/progress.md` (gitignored ledger).

- [ ] **Step 1: Run pre-review gates**

Run `make test`, then `make app`. Record exact counts and build output in the ledger.

- [ ] **Step 2: Dispatch independent scoped review**

Review the Step 2 commit range against the roadmap and hard constraints. Trace every `native_app` path to `BrainProposalValidator`; verify router schemas cannot carry action data; verify chat/unsupported publish no action; verify cancellation and no external-network additions.

- [ ] **Step 3: TDD every verified Critical or Important finding**

For each real finding: add a focused failing regression test, observe RED, apply the minimal fix, run focused GREEN, commit/push explicit paths, and request a scoped re-review. Record deferred Minor findings explicitly.

- [ ] **Step 4: Run final verification**

Run, in order:

```bash
graphify update .
make test
make app
git diff --check 270c839..HEAD
git status -sb
git rev-list --left-right --count origin/feat/sub-b-local-brain...HEAD
```

Expected: full suite green, signed release app produced, no whitespace errors, clean branch, and `0 0` remote divergence.

- [ ] **Step 5: Append ledger and report**

Record design decisions, RED/GREEN evidence, commit SHAs, review findings/fix rounds, test delta from 211, uncertainty, and deliberate non-goals. Report Step 2 only, then stop without starting Step 3, altering the PR, or merging.
