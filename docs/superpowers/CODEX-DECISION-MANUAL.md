# OSPA Codex Decision Manual

This manual teaches a zero-context Codex session how to make good decisions for
OSPA. It is not a status ledger, implementation plan, or permission to begin the
next feature. Its job is to preserve the reasoning discipline that makes OSPA safer,
more useful, and cheaper to build.

Read this file before project work. Then verify live repository state. A remembered
SHA, test count, handoff, roadmap label, or filename can be stale.

## 1. Product north star

OSPA is a native macOS companion for people who do not want to think like computer
operators. It should feel like a careful technical friend: understand plain
language, explain limitations honestly, help with information, and complete useful
computer chores only with authority the user knowingly granted.

The goal is not maximum autonomy. The goal is dependable assistance that earns
trust. Optimize decisions in this order:

1. Preserve the user's control, privacy, and data.
2. Tell the truth about what OSPA understood and can do.
3. Complete the user's real outcome, not merely the easiest technical proxy.
4. Prefer reversible, inspectable behavior.
5. Reuse one proven authority for each invariant.
6. Add the smallest complete capability that advances the product.
7. Optimize speed, model cleverness, and implementation novelty last.

A feature that appears capable but guesses, hides uncertainty, or weakens consent is
negative progress. A refusal that accurately explains the missing capability is
better than a confident wrong action.

## 2. Establish truth before deciding

Start every cold session in `/Volumes/ai-hub/OSPA`:

```sh
git status --short --branch
git log --oneline --decorate -12
git log origin/$(git branch --show-current)..HEAD --oneline
```

Then read, in order:

1. The user's current request. It defines present authority and scope.
2. This manual and the repository `AGENTS.md`.
3. `SECURITY.md` for shipped guarantees.
4. `docs/superpowers/ROADMAP-codex.md` for sequencing and stop boundaries.
5. The explicitly approved active spec and implementation plan.
6. The matching `.superpowers/sdd/<work-name>/progress.md` ledger.
7. Relevant recent commits and tests.

Use these truth rules:

- Running code and fresh verification outrank prose about code.
- The active ledger outranks old handoff or resume files for completed fix rounds.
- A newer user-approved spec can supersede roadmap detail, but not silently weaken a
  shipped security guarantee.
- An untracked or newly discovered plan is evidence of work, not proof of approval.
- Memory files are orientation aids, never authority for destructive or expansive
  action.
- When two sources disagree about a security property, stop and show the conflict.

Do not silently resolve a scope conflict in favor of more capability.

## 3. Architecture is a trust boundary

Keep the three layers distinct:

```text
AvatarCore
  Pure policy and value types. Validation, plans, consent, expiry, safety state,
  redacted audit shapes. No AppKit, network, process launch, or side effects.

AvatarPlatform
  Effectful adapters behind injected protocols. NSWorkspace, Accessibility,
  Spotlight, local model transport, HTTP, and future OS integrations.

AvatarCompanion
  SwiftUI presentation and composition. It wires policy to adapters and owns UI
  lifecycle, but must not become an alternate safety authority.
```

Put a rule at the narrowest layer that can enforce it for every caller. Safety rules
normally belong in `AvatarCore`. OS-specific preflight belongs at the adapter
boundary. UI readiness reflects policy; it does not replace policy.

Avoid parallel state that can drift. Prefer one immutable value binding all fields
that must share a lifecycle—for example, a plan ID and the model reason shown for
that exact plan. Derived UI state is safer than a second mutable source of truth.

Do not solve growth in `AvatarModel` or `AvatarView` by adding another unrelated
branch to the same god object without considering a focused component. Also do not
perform broad refactors unrelated to the approved step. Create a seam only when its
responsibility and consumers are known.

## 4. Classify every flow before building it

Every user flow belongs to one of four authority levels:

| Level | Output | May cause a side effect? | Required boundary |
| --- | --- | --- | --- |
| Observe | Local status or metadata | No | Bounded, privacy-aware read |
| Answer | User-visible text | No | Sanitized publication; no action route |
| Propose | Typed preview | No | Grounding and Swift validation |
| Execute | Exact typed effect | Yes | Preview, confirmation, consent, preflight, audit |

Do not blur these levels. In particular:

- An answer is not a proposal.
- A proposal carries no executable authority.
- A preview is not consent.
- OS permission is not OSPA consent.
- A high confidence score is not validation.
- A skill or stored correction is not a new permission.

If a lane is meant to be answer-only, make action types structurally absent. A
runtime boolean saying “do not execute” is weaker than having no plan, preview,
consent, adapter, or executor reachable from that method.

## 5. Non-negotiable safety invariants

### Untrusted model output

The model interprets; Swift decides. The prompt may improve usefulness but is never
the safety mechanism.

- The model selects from a closed tool menu. It does not author `ActionPlan`, bundle
  identifiers, permission scopes, consent, shell authority, or executor payloads.
- Every proposed app must be grounded in the same installed-app inventory and pass
  `BrainProposalValidator`.
- Multi-step output is atomic. Validate every call before publishing anything. One
  invalid call refuses the entire chain; never run a valid prefix.
- The intent router chooses only a lane. It cannot decide an action.
- The confidence evaluator runs only after proposal validation. Its threshold tunes
  UX and can only ask for clarification or allow the normal preview path.
- Stored corrections are bounded local hints. They never override grounding or
  validation.

### Preview and authorization integrity

The user must authorize the same thing that can execute.

- Bind user-visible justification to the exact pending plan or sequence.
- Sanitize and bound every model-authored field shown during authorization,
  including the reason and app name. Control and bidirectional-format characters are
  security-relevant.
- Replacement, cancellation, decline, expiry, disable, confirmation, and Emergency
  Stop must clear all state belonging to the ended proposal.
- Consent is one-shot, short-lived, scoped to an exact plan and exact permission
  set. Never widen, reuse, refresh, or infer a grant.
- Execution revalidates target, capability, expiry, safety state, and required OS
  conditions. It does not trust the preview's earlier result.
- Observe-only is default. Nothing auto-executes.

### Async lifecycle integrity

Every suspension point is a state-change opportunity. After an `await`, actor hop,
server startup, network response, evaluator call, or adapter boundary, ask:

1. Was this task cancelled or replaced?
2. Is its generation/request/plan ID still current?
3. Is Emergency Stop still clear?
4. Is the exact authorization or consent lease still live?
5. Is the target and permission state still the same?

Recheck immediately before model use, publication, and execution. A check made only
before a slow operation does not protect what happens afterward.

### Emergency Stop

Emergency Stop returns to observe-only, cancels in-flight work, and clears pending
confirmable state. A late result must not republish. A side effect already handed to
macOS might be irreversible; do not pretend it can be recalled, but prevent every
follow-on action.

### Local model process ownership

Only terminate a model server OSPA started. If OSPA adopts a compatible external
server, never launch a competing process against it and never kill it. Remaining
degraded until app restart after an adopted server dies is safer than taking
ownership the user did not grant.

### Network and fetched content

The current approved-page lane is deliberately narrow:

- The user supplies the exact URL. The model is not asked where to connect.
- `ResearchGate` remains the single authorization authority: HTTPS, exact approved
  host, live expiry, and document budget.
- Redirects are refused before an off-host connection; post-fetch URL validation is
  retained as defence in depth.
- No credentials, cookies, persistent cache, URL path audit, or page-content audit.
- Response bytes and extracted text are bounded and refused rather than silently
  truncated when that would change meaning.
- Fetched text is untrusted and answer-only. Prompt injection in a page has no route
  to an action.

Search results, page links, and model suggestions do not authorize a destination.
Any future model-selected host, cloud call, credential handling, browser control,
or shell execution changes the threat model and needs an explicit design plus user
approval before implementation.

### Audit and privacy

Audit enough to explain authority and outcome, not enough to create a new sensitive
dataset. Prefer generated IDs, exact approved host when needed, timestamps, closed
outcomes, and byte counts. Do not store page content, prompts, URL paths, secrets,
tokens, or unnecessary user text.

Persistent user data must be local, inspectable, bounded, documented, and easy to
clear. No telemetry unless separately designed and explicitly approved.

## 6. Decision procedure for a new capability

Use this sequence before writing code:

1. Restate the human outcome in plain language.
2. Name what OSPA still cannot do. Do not disguise a missing capability as a nearby
   action.
3. Classify the flow as observe, answer, propose, or execute.
4. Draw the trust path: user input, model output, stored data, fetched data, policy,
   adapter, UI, and side effect.
5. Identify whether it introduces network access, credentials, persistence, money,
   destructive operations, broader filesystem access, or a new executor.
6. Find the existing authority to reuse. Do not create a second permission,
   validator, router, audit format, or plan type without a demonstrated mismatch.
7. Define exact types and closed limits before prompt wording or UI polish.
8. Make invalid, partial, expired, replaced, and cancelled states fail closed.
9. Ensure the preview describes the exact executable payload.
10. Specify redaction and lifecycle clearing.
11. Write adversarial tests that prove the trust boundary, including after actor
    hops and expiry.
12. Implement the smallest end-to-end slice, review it, and stop at the approved
    boundary.

When choosing between designs, prefer the one with fewer authorities, fewer mutable
fields, less ambient access, and a smaller reachable action graph. Capability can be
added later. Authority leaks are expensive to remove.

## 7. Product and UX judgment

OSPA is for non-technical users, but hiding machinery must not remove control.

- Use plain language, exact app names, and concrete outcomes.
- Show uncertainty as a short question instead of a confident guess.
- Disable an affordance when the required live authorization is absent.
- Keep deterministic typed paths fast; use the local brain as fallback where that
  is the established design.
- Preserve honest unsupported/chat lanes. Never answer a weather question by
  launching a weather-like app.
- Put advanced diagnostics behind progressive disclosure rather than deleting the
  safety information they represent.
- Manual live testing matters for UX thresholds, wording, and macOS behavior, but it
  does not replace deterministic boundary tests.

“Full-fledged” means a coherent set of trustworthy lanes, not one omnipotent prompt.
Add capability behind explicit typed interfaces, then make the interface feel
unified to the user.

## 8. Capability direction without automatic authority

The long-term product direction is broader than today's shipped surface. This
section guides architecture; it does not approve starting any capability. The user
must still approve the active spec and step.

- **Unified modern UI:** move from a developer control panel toward a calm companion
  interface. Preserve all gates underneath and expose technical detail progressively.
- **Capability lanes:** app actions, chat, local search, page reading, file chores,
  shell work, delegated coding, and browser work should have focused typed
  interfaces. The router chooses a lane; each lane owns neither more nor less
  authority than its validator and adapter grant.
- **Web search:** search may discover candidate URLs, but a result does not authorize
  fetching one. Keep destination discovery separate from `ResearchGate` approval.
- **File chores:** prefer typed move, rename, organize, reveal, and trash operations
  inside user-chosen scope. Show exact sources and destinations; revalidate scope at
  execution; prefer recoverable trash over permanent deletion.
- **Shell work:** treat shell as a higher-risk executor than browser control. If
  approved, begin jailed in a user-chosen project directory, use structured and
  sanitized argv rather than an opaque shell string, prohibit silent `sudo`, and
  require one-shot confirmation per command. Any unrestricted mode needs a separate,
  explicit, expiring escalation and must remain unreachable from fetched content.
- **Coding and software creation:** orchestrate a mature installed coding agent in a
  user-approved project directory instead of pretending the local 8B model is a
  full coding agent. OSPA should provide the UI, bounded workspace, progress,
  consent, and audit boundary; the delegated agent supplies coding expertise.
- **Skills:** a skill is a curated procedure over already approved capabilities. It
  may select and order valid typed operations, but it cannot create a permission,
  bypass a validator, or turn answer content into action authority.
- **Cloud and browser control:** these add credentials, cost, remote data exposure,
  and live-page actions. Keep them separate from local capability work and require a
  fresh threat model, spend/data decisions, and explicit user approval.

Build the shared lane seam from actual consumers, not an abstract framework invented
ahead of them. Split oversized composition/UI objects when that unlocks isolated
work, but preserve behavior with tests before layering new capabilities on top.

## 9. Efficient engineering workflow

### Orient with Graphify

The code graph is derived and gitignored:

```sh
graphify explain "AvatarModel"
graphify path "SourceType" "DestinationType"
graphify query "focused architecture question" --budget 2000
graphify update .    # rebuild after code edits; code-only, no LLM, free
```

Never run bare `graphify .`; it can initiate a paid semantic pass over documents.
Use Graphify before reading large files. Then open only the relevant line ranges.

### Scope reasoning and tests

- Use medium reasoning for routine implementation.
- Use high reasoning for designs, consent gates, untrusted input, network, process,
  credential, shell, and browser boundaries, and the one focused review.
- Iterate with `swift test --filter <SuiteName>`.
- Run `make test` once after the final code change for the step.
- Run `make app` before declaring the step finishable.
- Use a clean `.build` rebuild when requested, when paths changed, or at a milestone
  gate—not after every small edit.
- Do not run concurrent SwiftPM builds in one checkout.
- Do not poll agents or processes repeatedly. Use one blocking wait.

### TDD honestly

A RED test must reach the code path it claims to test and fail for the intended
reason. Assert the specific error or state. Do not claim RED if an earlier invariant
already made the new test pass. Record that fact and explain which existing boundary
provided coverage.

For security fixes, test both the pure policy and the integration boundary when
possible. If a platform callback cannot be exercised end to end offline, say so
plainly; do not write a test that merely resembles coverage.

### Review efficiently

Use a fresh, bounded adversarial review for meaningful changes, especially consent,
untrusted input, persistence, network, and execution. Give the reviewer exact files,
diff base, invariants, and two or three questions. Fix verified findings, add focused
regressions, then re-review only the fix diff. Do not create an expensive broad sweep
to look thorough.

Technical verification outranks agreement. If a requested fix names the wrong choke
point, trace callers and explain the correction before implementing a structurally
incomplete patch.

## 10. Git, ledgers, and stopping discipline

- Preserve dirty work you did not create.
- Stage explicit paths; never use `git add -A` in a mixed worktree.
- Do not amend, merge to `main`, open a PR, or perform destructive cleanup without
  explicit user authority.
- Follow the active step contract. Normally: focused tests while iterating, final
  `make test`, `make app`, Graphify update after code edits, commit, push, append the
  ledger, report, and stop.
- One roadmap step means one step. Do not begin the next security surface because
  time or context remains.
- Record every review finding and fix round in the active ledger. Do not erase
  uncertainty or consciously deferred work.
- If pausing mid-step, write a resume file with exact branch, HEAD, clean/dirty
  state, test evidence, completed work, open findings verbatim, and one concrete next
  command.

A good final report is short and auditable:

```text
Changed: <user-visible and architectural result>
Tests: <old count -> new count; commands run>
Uncertain: <anything not proven live or end to end>
Skipped: <adjacent capability deliberately not started>
Commit/push: <SHA and remote state>
```

Never report “complete” from an agent message, old ledger line, or incremental build
alone. Run the command that proves the claim and read its exit status.

## 11. Stop and ask immediately when

Stop mid-step, present evidence, and request direction if:

- Work would introduce a new network destination policy, cloud provider, credential,
  spend, browser controller, unrestricted shell, destructive filesystem operation,
  or ambient permission.
- A shipped safety gate is defective.
- The approved spec and code disagree on a security property.
- A fix requires weakening an invariant.
- The preview could differ from what executes.
- Untrusted answer content can reach a proposal or action.
- Ownership of an external process or user data is unclear.
- A discovered plan conflicts with the current user instruction or lacks explicit
  approval.
- Continuing would consume substantial budget on an uncertain architecture.

Do not stop for ordinary implementation ambiguity that can be resolved safely inside
the approved scope. Make a conservative, reversible assumption, record it, and keep
the step moving.

## 12. Durable pointers

- Security guarantees: `SECURITY.md`
- Architecture: `docs/ARCHITECTURE.md`
- Sequencing and hard stops: `docs/superpowers/ROADMAP-codex.md`
- Historical local-brain handoff:
  `docs/superpowers/HANDOFF-2026-08-01-codex.md`
- Active implementation ledgers: `.superpowers/sdd/*/progress.md`
- Approved specs: `docs/superpowers/specs/`
- Approved implementation plans: `docs/superpowers/plans/`
- Shared continuity memory: `/Volumes/ai-hub/ai-agent-memory/memory/`

At the time this manual was written, the approved single-page-read ledger recorded
302 tests in 34 suites and a successful app build on
`feat/sub-b-local-brain`. Treat that only as a starting clue. Re-run live state
checks before using it in a report or making the next decision.
