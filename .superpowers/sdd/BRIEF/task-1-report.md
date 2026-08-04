# Task 1 report — privacy-safe model split

## Scope and outcome

- Started from `9212519`; retained approved `56d2a74` (multiline chat) and `9212519` (AvatarView split).
- Completed only the preserved privacy-safe `AvatarModel` extraction. Core: 2,961 → 2,800 lines. Six extension files total 263 lines: `BrainMessages` (51), `ConfidenceGate` (41), `Presentation` (13), `ReadPage` (76), `Safety` (24), `TaskSequences` (58).
- Added MARK sections to core and every extension. No type, method, published property, control flow, ordering, timing, or authority changed.
- Removed exactly `"multiple\\nlines"` from `Tests/AvatarPlatformTests/MLXBrainClientTests.swift`; no other existing test changed. Untracked `BRIEF.md` remains untouched.

## TDD / stale-platform expectation

The production RED/GREEN for multiline chat text belongs to the earlier approved `56d2a74`; this task did not invent another production RED. Freshly reproduced the stale platform expectation before editing:

```
swift test --filter MLXBrainClientTests
24 tests in 1 suite; 1 issue/failure at MLXBrainClientTests.swift:279:
an error was expected but none was thrown and "multiple\nlines" was returned.
```

Root cause: this one invalid-answer table entry contradicted the approved sanitizer behavior. Deleted only that entry, then reran the same command: 24 tests in 1 suite passed.

## Access review

Only pure/UI helpers widened from `private` to module-internal so cross-file extensions can call them. None contains authority, pending-plan mutation, generation state, consent, authorization lifecycle, or audit writes.

| Former private member | New location | Why safe |
| --- | --- | --- |
| `unsupportedRequestMessage` | `+BrainMessages` | Fixed, non-model-authored unsupported copy. |
| `brainMessage(for:)` | `+BrainMessages` | Pure error-to-copy mapping. |
| `brainProposalConfidenceThreshold` | `+ConfidenceGate` | UX tuning only; validator remains authority. |
| `disambiguationMessage` | `+ConfidenceGate` | Pure presentation text. |
| `pageReadPrompt(question:document:)` | `+ReadPage` | Pure answer-only prompt construction; no executable type. |
| `researchErrorMessage(_:)` | `+ReadPage` | Pure error-to-copy mapping. |
| `readPageMessage(for:)` | `+ReadPage` | Pure error-to-copy mapping. |
| `taskSequenceResultMessage(_:)` | `+TaskSequences` | Pure typed-result-to-copy mapping. |
| `taskSequenceStepFailureMessage(_:index:total:requestedName:)` | `+TaskSequences` | Pure error-to-copy mapping. |

`toggleExpanded`, `hasLiveResearchAuthorization`, `setObserveOnly`, `resumeObservation`, and `taskSequenceExecutionReady` were already module-visible; moving them widened no modifier.

Load-bearing private flows deliberately left in `AvatarModel.swift`:

- generation/lifecycle: `brainGeneration`, brain task/idle-shutdown state, `cancelInFlightBrainTask`, and routing/chat/proposal launch paths;
- exact plan/reason binding: private binding types/state plus `bindBrainReason`, `bindBrainSequence`, and binding clearing;
- consent/execution: `computerUseConsentLedger`, consumed consent/request IDs, pending computer-use plan/profile, confirmation, and revalidation;
- research authorization/page-read lifecycle: approval/expiry scheduling, read budget, active read state, `readApprovedPage`, and transport/model rechecks;
- audit: private page-read byte/audit appenders, task outcomes, and accessibility audit recorders; published audit arrays remain `private(set)`.

The fuller split would require widening one or more private flows above. Stopped at this safe subset; no lane abstraction, coordinator, registry, or dependency-injection change.

## Structural and self review

- Extracted `readApprovedPage` body and searched for `pendingApplicationProposal|pendingTaskSequence|previewedAction|previewApplicationCommand|startBrainProposal|previewTaskSequence`: no matches.
- `git diff --check` passed. Manual diff review found the sole semantic test change is the approved stale-entry removal; remaining changes move helper bodies and add MARK/import scaffolding.
- Independent read-only bounded review: **APPROVED**, no Critical/Important/Minor findings. It independently confirmed all nine widened helpers are presentation-only, the load-bearing binding/generation/read/audit state remains private in core, and `readApprovedPage` has zero forbidden action-route symbols. The reviewer ran no build or test.
- Ran `graphify update .`; derived graph output is ignored by `.gitignore`, so no graph file requires staging.

## Verification

- `swift test --filter MLXBrainClientTests` — 24 passed after stale-case removal.
- `swift test --filter BrainProposalValidatorTests` — 40 passed, including two-line/tab acceptance, bidi/NUL refusal, and newline-flood cap.
- `swift test --filter AvatarModelBrainTests` — 34 passed.
- `swift test --filter AvatarModelReadPageTests` — 11 passed.
- `make test` — 307 tests in 34 suites passed.
- `make app` — release app built and signed.
- `graphify update .` — 1,948 nodes, 5,124 edges, 85 communities.

No live MLX server or real application action was exercised; all verification uses deterministic fakes.
