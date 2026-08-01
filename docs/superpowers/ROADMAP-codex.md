# OSPA Roadmap — Codex execution handoff

Companion to `HANDOFF-2026-08-01-codex.md` (read that first for repo layout,
architecture, environment, and safety invariants). This file is the **plan through
the end of the project**, divided into steps.

---

## How we work

**One step at a time. Finish it, report, stop.** The user reads your report and says
"next" when ready. Never chain into the following step on your own — they are
sequenced deliberately, and several of them change the security surface.

Every step ends the same way:

1. Full suite green (`make test`) and `make app` builds.
2. Commit with a clear message. Push.
3. Append to the ledger: `.superpowers/sdd/<plan-name>/progress.md`.
4. Report: what changed, test delta, anything you were unsure about, anything you
   deliberately did not do.
5. **Stop.**

**Never merge to `main` or open a PR unprompted.** That is always the user's call.

### When to use subagents

Use them when the work is genuinely parallel or benefits from fresh eyes:

- **A review after implementing.** Always worth a separate agent — an implementer
  reviewing its own work misses what it already decided was fine. Every real bug
  found in slice 1 came from a reviewer, not the implementer.
- **Independent files.** Two components that share no types can run in parallel.
- **An adversarial pass** on anything touching consent, untrusted input, or network.

Do **not** use them for:

- Single-file mechanical edits.
- Anything where you would spend more tokens briefing the agent than doing it.
- Two agents editing the same checkout concurrently — they contend on the SwiftPM
  build lock and race the git index. If you parallelize, give each a worktree and
  **verify with `git worktree list` that they branched from the right commit** (this
  bit us once; both worktrees came off an old ancestor and were missing three tasks).

### Standing rules

- Use **graphify** instead of reading large files: `graphify explain "X"`,
  `graphify path "A" "B"`. Rebuild with `graphify update .` (code-only, free).
  Never run bare `graphify .` — it attempts a paid semantic pass.
- Keep `AvatarCore` pure: no AppKit, no network, no side effects.
- Model output is untrusted until Swift validates it. The prompt is never the
  safety mechanism.
- Nothing auto-executes. Every action needs the existing preview + confirmation.
- Observe-only is the default; emergency stop clears pending state.
- Plain language in every user-facing string.
- Never commit secrets, API keys, or tokens.
- Budget: the user is on a $20 Codex plan. Use `model_reasoning_effort="medium"`
  for routine work, `high` for design and anything safety-critical.

### When to STOP and ask the user

Not just at step boundaries — immediately, mid-step, if any of these come up:

- A step would add **network access**, **cloud API calls**, or **credential
  handling** for the first time.
- You find a defect in an already-shipped slice's safety gates.
- The spec and the code disagree about a security property.
- A fix would require weakening any invariant above.
- You are about to spend significant budget on an approach you are unsure about.

---

## Step 0 — Close out slice 1  *(in progress)*

Push, open a PR to `main` (do not merge), save memory, refresh the handoff doc's
state section. Report the PR URL. **Done when** the user has the URL.

---

## Step 1 — Multi-step chains from the brain

**Goal:** "open Safari and put on some music" becomes an ordered chain the user
confirms once.

**Why now:** it is the cheapest real capability gain left. The machinery already
exists — `TaskSequence`, `TaskSequenceValidator`, `TaskSequenceRunner` handle
ordered chains under one confirmation, with per-step consent. Slice 1 deliberately
left this out to keep the untrusted-output boundary small. That boundary is now
proven, so extend it.

**Scope:** let the model return up to `TaskSequence.maximumSteps` (5) tool calls
instead of one. Validate **every** call through `BrainProposalValidator` before any
of them becomes a plan. If any single call fails validation, refuse the whole
chain — never half-run.

**Watch for:**
- The existing typed-path rule is that a partially-valid chain is refused entirely.
  Match it exactly; do not invent a "best effort" path.
- Each step still mints its own one-shot consent at execution time. Do not collapse
  them into one grant.
- The preview must show every step before confirmation, in order.

**Done when:** a multi-step natural request previews as a numbered list, one
confirmation authorizes exactly that list, and a chain containing one invalid step
is refused whole. Tests for all three.

---

## Step 2 — Intent router

**Goal:** OSPA tells the truth about what it cannot do yet.

**Why:** today every unparsed request goes to the app-picker, so "what's the weather
in Tokyo" gets answered with an app launch. That is a correctness and trust problem
before it is a capability problem.

**Scope:** a local classifier (same model, separate closed tool set) routing to
`native_app`, `chat`, or `unsupported`. `native_app` goes to the existing slice-1
path unchanged. `chat` answers in text without proposing any action. `unsupported`
says plainly what it cannot do. **No web, no network.**

**Watch for:** the router must not become a second place where actions are decided.
It only picks a lane. Everything in the `native_app` lane still goes through the
slice-1 validator untouched.

**Done when:** a weather question gets an honest "I can't browse the web yet"
instead of an app proposal, and app requests still work exactly as before.

---

## Step 3 — Learned corrections

**Goal:** when OSPA proposes the wrong app and the user declines, it learns.

**Why:** the confirmation gate is already a perfect labeled signal — a decline is
the user saying "not that one." Slice 1 gets preference from Spotlight usage, which
is good but static.

**Scope:** record declines locally (request shape → rejected app). Feed recent
corrections into the prompt as additional context. Local file, no network, no
telemetry, user can clear it.

**Watch for:**
- This is new persistent state about the user. Keep it local, make it inspectable,
  make clearing it easy and obvious.
- Do not let corrections override grounding. A corrected preference still has to be
  an installed app and still passes the validator.
- Cap the store; do not let it grow forever or drift the cached prompt prefix badly.

**Done when:** declining a proposal changes the next proposal for a similar request,
and the store is visible and clearable.

---

## Step 4 — Confidence gate

**Goal:** when the model is unsure, ask instead of guessing.

**Scope:** a local evaluator scoring proposals before preview. Below threshold,
present a short disambiguation ("did you mean Spotify or Music?") rather than a
confident wrong answer. Still no cloud.

**Watch for:** the threshold is a UX tuning value, not a safety mechanism — the
validator remains the safety authority regardless of confidence.

**Done when:** an ambiguous request produces a choice, not a guess.

---

## ⚠️ Step 5 — Network foundation  *(STOP AND ASK BEFORE STARTING)*

**This is the security-critical step. Get the user's explicit go-ahead, and expect
them to want Claude involved in the design.**

**Why it is different:** OSPA has **zero network code today**, by design. `SECURITY.md`
states no network fetch. Adding it changes the threat model for the whole product.
It needs its own brainstorm and spec, not just a plan.

**What it must include, at minimum:**
- A `network(hosts:)` permission scope wired into the existing consent system —
  the scope type already exists in `PermissionScope` but is unused.
- A host allowlist. No wildcard fetching.
- Explicit, expiring, user-approved network consent, same shape as the existing
  Accessibility consent.
- Redaction before anything leaves the machine.
- Audit records for every request.

**Do not start this without a spec the user has reviewed.**

---

## Step 6 — Web read (tier 0)

Depends on Step 5. Fetch + readability extraction, structure-first, read-only. The
model reads extracted text; it never gets raw pages. No page content is stored.

Per the design JSON this handles ~90% of web questions without a browser.

---

## ⚠️ Step 7 — Cloud escalation  *(STOP AND ASK)*

Depends on Steps 4 and 5. Hard steps escalate to a cloud model with a **redacted,
bounded task spec** — never full context, never raw page text, never AX labels.
See `handoff_contract` in `docs/brain/ospa-brain-workflow.json`.

**Involves credentials and real money.** Needs the user's explicit decision on
provider, key storage, and spend caps before any code. Design JSON caps it at 5
cloud calls per task and 4000 tokens per step — honor that.

---

## ⚠️ Step 8 — Web task / browser control  *(STOP AND ASK)*

Highest risk in the project: acting on live web pages. Depends on everything above.
Hand CAPTCHAs, logins, payments, and destructive confirmations back to the human —
never automate them. This needs its own full design cycle.

---

## Step 9 — Sub-C: the non-technical-user interface

The original point of OSPA: "a techy friend in a box" for someone who is scared of
their computer. Current UI is a developer's debugging surface — it exposes
observe-only toggles, audit records, capability profiles, and expiry timers.

**Goal:** an interface where the safety machinery is still fully in force but no
longer in the user's face. This is a design problem more than an engineering one,
and it deserves its own brainstorm with the user.

---

## Deferred items to fold in along the way

From the slice-1 ledger, consciously deferred and still open:

- `Calendar.current` in day-bucketing tests is timezone-dependent.
- Duplicate JSON keys rely on undocumented Darwin first-wins behavior.
- `@unchecked Sendable` test mocks are safe only because tests run sequentially.
- The `LocalBrainServerController` concurrency test is probabilistic (fails ~3/5
  runs when the guarantee is broken) rather than deterministic.
- Task 3: cancellation is reported as `.unavailable` — no enum case fits it.
- The local model is **text-only**. The design's tier-2 vision path needs a separate
  VLM. Relevant from Step 6 onward.

Fix these opportunistically when you are already in the relevant file. None justify
a dedicated step.
