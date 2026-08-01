# Handoff to Codex — OSPA Sub-B (local brain), 2026-08-01

Written by Claude at the end of a long session. Read this top to bottom before
touching anything. It is written for an agent with zero prior context.

---

## 1. Machine, repos, paths

| Thing | Where |
| --- | --- |
| Project (work here) | `/Volumes/ai-hub/OSPA` |
| OSPA GitHub remote | `https://github.com/viralfaceless25-sketch/-OSPA-OSPetAgent..git` |
| Shared agent memory repo | `/Volumes/ai-hub/ai-agent-memory` |
| Shared memory remote | `https://github.com/viralfaceless25-sketch/ai-agent-memory` |
| Local model runtime (MLX) | `/Users/keyush/Models/.venv` |
| Local model weights | `~/.cache/huggingface/hub/models--mlx-community--Qwen3-8B-4bit` |
| Old rejected runtime + backup weights | `/Volumes/ai-hub/turbo-fieldfare` (see §7) |

`/Volumes/ai-hub` is a **removable SD card**. It can disconnect mid-session. If it
does: remount, `rm -rf .build`, retry. Nothing is lost — everything important is
pushed to GitHub.

Hardware: Apple M3 Pro, 18GB RAM, macOS 27, Swift 6.2.1, Xcode 26.1.1.

---

## 2. What OSPA is

A native macOS desktop assistant ("Open Source Pet Agent" / Avatar Companion): a
draggable avatar that can observe, plan, and — with explicit consent — actually act
on the user's Mac. Swift 6 / SwiftUI / macOS 14+. Written to be usable by a
non-technical person.

**The architecture's spine, which is load-bearing and must not be weakened:**

```
AvatarCore       pure policy. No AppKit, no network, no side effects.
                 Plans, consent grants, preflight, audit, validation.
AvatarPlatform   effects, behind injected protocols. AX, CGEvent, NSWorkspace,
                 Spotlight, HTTP.
AvatarCompanion  SwiftUI app + wiring.
```

Every capability terminates through the same gates: observe-only by default,
emergency stop, one-shot expiring consent, execution preflight, redacted audit log.
Nothing bypasses them. Sub-A (already merged into this branch's history) added the
first real executor, `RealForegroundInputAdapter`.

Docs worth reading: `README.md`, `SECURITY.md`, `docs/ARCHITECTURE.md`.

---

## 3. What Sub-B slice 1 is (the current work)

**Goal:** the user types plain language ("i wanna listen to some music") and OSPA
proposes the app they actually use. A local LLM does the interpretation.

**It adds zero new capability.** It only makes OSPA's *existing* actions reachable by
speaking normally instead of typing exact commands.

Spec: `docs/superpowers/specs/2026-08-01-sub-b-local-brain-design.md`
Plan: `docs/superpowers/plans/2026-08-01-sub-b-local-brain.md`

### The three decisions you must not undo

**1. The Swift validator is the sole safety authority — never the prompt.**
Benchmarking showed the shipped model proposing "Photoshop" on a Mac without it.
Making the prompt strict enough to stop that made a *larger* model start refusing
legitimate requests. Prompt severity only trades one failure for the other. So the
prompt is tuned for helpfulness and every guarantee is enforced in code, in
`Sources/AvatarCore/BrainProposal.swift`, against the same inventory the model saw.

**2. The model selects from a closed menu; it never authors a plan.**
It returns one of exactly three tool names plus an app *display name*. It never emits
a bundle identifier, capability ID, `ActionPlan`, or `VisibleInteraction`. A validated
`BrainProposal` converts to a `ParsedApplicationCommand` — the same type the typed
path produces — and from there every downstream component is untouched Sub-A code.

**3. Usage preference comes from macOS, not from watching the user.**
Spotlight already tracks `kMDItemUseCount` / `kMDItemLastUsedDate` per app. OSPA reads
that at request time, read-only. No background observer, no new permission, no
learned-preference store. This is why it picks Spotify (90 opens) over the never-opened
Music app, and WhatsApp (3455 opens) for messaging.

### Data flow

```
plain language
  -> MLXBrainClient          -> RawBrainToolCall   (untrusted)
  -> BrainProposalValidator  -> BrainProposal      (trusted, grounded)
  -> ParsedApplicationCommand                      (existing type)
  -> InstalledApplicationResolver                  (existing)
  -> ApplicationActionPlanner -> ActionPlan        (existing)
  -> preview -> explicit user confirmation         (existing)
  -> PlanValidator -> ConsentGrant -> ExecutionContract  (existing)
  -> RealForegroundInputAdapter -> AuditEvent      (existing)
```

The brain is a **fallback**: it runs only after the deterministic parsers in
`AvatarModel.previewCommand()` decline. Typed exact commands stay instant and free and
never reach the model.

---

## 4. Exact current state

Branch `feat/sub-b-local-brain`, HEAD `31d8b37`, pushed and working tree clean.
**177 tests green** (baseline before Sub-B was 106).

⚠️ **Only pushed through `260ea1a`.** Commits `b373ea8`, `10c7d76`, `5627a2d`,
`666f05b`, `863496a` are LOCAL ONLY. Push early.

| Task | File(s) | State |
| --- | --- | --- |
| 1 prompt builder | `Sources/AvatarCore/BrainInventory.swift` | done, review clean |
| 2 validator | `Sources/AvatarCore/BrainProposal.swift` | done, re-review PASS |
| 3 MLX client | `Sources/AvatarPlatform/LocalBrainService.swift` | done, re-review PASS |
| 4 usage source | `Sources/AvatarPlatform/ApplicationUsageSource.swift` | done, re-review PASS |
| 5 server lifecycle | `Sources/AvatarPlatform/LocalBrainServerController.swift` | done, re-review PASS |
| 6 wiring + README | `Sources/AvatarCompanion/AvatarModel.swift`, `README.md` | done, re-review PASS |

---

## 5. COMPLETION STATE AND NEXT DECISION

Sub-B slice 1 is complete. Tasks 1-6 and every scoped re-review passed. The final
whole-branch review found no remaining Critical or Important issue. A clean rebuild
with no prior `.build` state passed 190 tests and built/signed the release app.

Branch `feat/sub-b-local-brain` is pushed through `31d8b37`. There is no remaining
implementation queue in this slice. Stop and ask the user to choose whether to merge
to `main`, open a PR, or keep the branch as-is. Never merge or open a PR unprompted.

Do **not** start Sub-B slice 2 (router/evaluator/cloud escalation) or the web tiers.
Those require a separate spec and explicit user approval.

---

## 6. The process being followed

Subagent-driven development. Per task: dispatch a fresh implementer → review (spec
compliance **and** code quality, both required) → fix round if findings → scoped
re-review of the fix diff only → mark complete. Max 5 fix rounds, then adjudicate.

**The ledger is the recovery map:**
`.superpowers/sdd/2026-08-01-sub-b-local-brain/progress.md` (git-ignored).
It holds every finding, every fix round, deferred minors, and resume points. Read it.
Append to it as you go — it is what survives a context loss.

Briefs and reports for each task live in the same directory.

Helper scripts (from the superpowers plugin):
`scripts/task-brief PLAN N`, `scripts/review-package PLAN BASE HEAD`.

**Deferred minors** are recorded in the ledger and must be triaged by the final review
before merge — they are not silently dropped.

---

## 7. Environment: the local model

Chosen after benchmarking: **MLX + `mlx-community/Qwen3-8B-4bit`**, thinking disabled,
loopback `127.0.0.1:8081`. ~2.45s warm. Free, offline, no tokens, no API cost.

Start it (only needed for Task 6's manual check — Tasks 1–5 tests are all offline):
```sh
cd /Users/keyush/Models && ./.venv/bin/python -m mlx_lm server \
  --model mlx-community/Qwen3-8B-4bit --port 8081 \
  --chat-template-args '{"enable_thinking": false}'
```

**Measured facts worth not rediscovering:**
- **Never run a local model off the SD card.** TurboFieldfare streams MoE experts from
  storage per token; on the SD card (102 MB/s) one tool call exceeded a 300s timeout,
  on internal SSD (6.05 GB/s) the same call took 9.9s. 59x.
- TurboFieldfare/Gemma was **rejected**: it is built for 8GB Macs, keeps only ~2GB
  resident, and wasted ~10GB of RAM on this machine while costing 44s/request. The fix
  was replacing the runtime, not tuning it. Backup weights remain at
  `/Volumes/ai-hub/turbo-fieldfare/scratch/gemma4.gturbo` (13GB, verified).
- MLX prompt caching reuses ~99% of a stable prefix, which is why the **full** app
  inventory is sent every request and no shortlist is needed. This requires the system
  prompt to be **byte-stable**: deterministic ordering, recency quantized to whole days,
  no clock value anywhere.
- Model size matters: Qwen3-1.7B hallucinated an uninstalled app and scored 2/7.
  Qwen3-8B scores 8/9. Qwen3-14B is equally accurate but drove the machine to 0.08GB
  free with 8.68GB compressed and 3.3GB swap — too heavy for an always-on assistant.
- Qwen3 emits `<think>` by default, which eats the token budget and truncates the tool
  call. Always disable thinking for structured tool use.
- Hugging Face throttles unauthenticated downloads to ~2-3 MB/s. A token is already
  configured at `~/.cache/huggingface/token` (user `ViralFaceless`).

---

## 8. Build and test

```sh
cd /Volumes/ai-hub/OSPA
make test      # full suite — must be green, currently 177
make app       # builds build/AvatarCompanion.app
swift test --filter <SuiteName>   # one suite
```

**Stale build cache:** if you see `PCH was compiled with module cache path ...` or
`missing required module 'SwiftShims'`, the `.build` directory remembers an old
absolute path. `rm -rf .build` and retry. Not a code problem — it happens because this
repo was moved onto the SD card.

**Do not run two `swift test` processes in the same checkout concurrently** — they
contend on the SwiftPM build lock, and concurrent commits race the git index. Earlier
in this session a parallel-agent attempt also failed because the worktrees branched
from an old commit and were missing Tasks 1–3. If you parallelize, verify the base
commit with `git worktree list` before letting agents work.

---

## 9. Safety invariants — do not break these

1. `AvatarCore` stays pure: no AppKit, no network, no side effects.
2. Model output is untrusted input. It is validated in Swift, never trusted because
   the prompt asked nicely.
3. The model can only ever name an app that is genuinely installed. If it names
   something absent, OSPA refuses and says so — it does not act.
4. Nothing auto-executes. Brain output produces a preview requiring the same explicit
   confirmation as typed input.
5. Observe-only is the default. Emergency stop clears pending state and cancels
   in-flight brain work.
6. **Only ever terminate a model server this controller started.** The user may be
   running their own for other work; killing it would be destructive.
7. All user-facing strings are plain language — a non-technical person reads them.
8. Never commit secrets. Never write tokens or keys to the memory repo.

---

## 10. Memory and session close

Shared memory (read at session start, write at session end):
- `/Volumes/ai-hub/ai-agent-memory/memory/MEMORY.md`
- `/Volumes/ai-hub/ai-agent-memory/memory/projects.md` — OSPA section has the status
- `/Volumes/ai-hub/ai-agent-memory/memory/decisions.md`, `open-loops.md`

Claude's own per-project memory (useful background, Codex may read it):
`/Users/keyush/.claude/projects/-Volumes-ai-hub/memory/` — see `project_ospa.md` and
`reference_local_llm_mac_perf.md`.

The user's session-close codeword is **`brain-sync`**. On it, run:
```sh
/Volumes/ai-hub/ai-agent-memory/scripts/session-end.sh codex "<summary>" /Volumes/ai-hub/OSPA
```
which appends a session log, commits and pushes shared memory, and commits and pushes
the project.

---

## 11. Two lessons from this session's reviews

Worth internalizing, because both were caught in code that looked fine:

**The plan's own reference code shipped a Critical.** The model's `reason` string is
what the user reads when deciding whether to authorize launching an app — and it had
no control-character guard and no length cap. A U+202E bidi override could reorder the
displayed justification; a 20,000-character reason could push the actual action out of
the dialog. It was the least-validated field in the file whose entire job is validation.

**A test that could not fail.** The case meant to prove the control-character guard
worked embedded a raw NUL directly in the JSON document, so it died at JSON parsing and
never reached the guard — while asserting only `any Error`. It would have passed
against a stub that always threw. Assert the *specific* error, and check that a test's
input actually reaches the code it claims to cover.
