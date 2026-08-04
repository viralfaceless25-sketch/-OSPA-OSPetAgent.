# SDD ledger — plan: BRIEF.md

- Resume baseline: `9212519`; existing safe commits are `56d2a74` (multiline chat behavior and core tests) and `9212519` (AvatarView panel split).
- User ruling (2026-08-03): remove the stale multiline rejection from `MLXBrainClientTests.swift` and complete only the privacy-safe `AvatarModel` split.
- Binding constraint: consent, pending-plan/reason binding, generation-token, authorization, and audit flows remain private in `AvatarModel.swift`.
- Root cause reproduced: `swift test --filter MLXBrainClientTests` ran 24 tests with one failure because `"multiple\nlines"` remains in the existing invalid-answer table after multiline answers became valid.
- Task 1: in progress — finish privacy-safe model split, remove only the stale test case, verify, review, commit, and push.
- Task 1 implementation: removed only the stale multiline table entry and retained the maximal privacy-safe split: `AvatarModel+BrainMessages`, `+ConfidenceGate`, `+Presentation`, `+ReadPage`, `+Safety`, and `+TaskSequences`. All consent, plan/reason binding, generation-token, authorization, and audit flows remain private in `AvatarModel.swift`.
- Fresh RED/GREEN record: before removal, `swift test --filter MLXBrainClientTests` ran 24 tests with exactly one failure at line 279 because the accepted multiline result was still expected to throw; after removing only that entry, 24 passed.
- Verification: focused MLX (24), BrainProposalValidator (40), AvatarModelBrain (34), and AvatarModelReadPage (11) suites passed; `make test` passed 307 tests in 34 suites; `make app` passed; `graphify update .` refreshed the ignored graph (1,948 nodes / 5,124 edges).
- Task 1 review: independent read-only bounded review APPROVED with no findings; it confirmed the exact private→internal list is presentation-only, private binding/generation/read/audit state remains core-local, and `readApprovedPage` contains none of the six forbidden action-route symbols. No reviewer build/test ran.
- Task 1: commit pending. Detailed work, access audit, privacy boundaries, TDD history, and self-review: `.superpowers/sdd/BRIEF/task-1-report.md`.
