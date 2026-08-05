# OSPA — Final Push Plan (2026-08-03)

Supersedes the sequencing in `ROADMAP-codex.md` from Step 7 onward. That roadmap's
Steps 1–6 are **done**; its Steps 7–9 are folded in below alongside new capabilities
the user asked for.

**Baseline:** branch `feat/sub-b-local-brain` at `f637edc`. 302 tests / 34 suites
green on a clean rebuild. `make app` builds. PR #1 is an unmerged draft covering only
slice 1 — stale.

**Capacity tonight:** Claude (design, security review) + 2 Codex CLIs (implementation),
each in its own git worktree on internal disk.

---

## Target, as the user stated it

> modern tech UI all over the app, everything working, accepts all the commands, do
> computer chores, browse internet for user, collect information, can code in any
> language any architecture, can build softwares, can make websites, can create
> applications, can run commands, have skills and intelligence

Mapped to work, with an honest verdict on each:

| Ask | Path | Verdict |
| --- | --- | --- |
| Modern tech UI all over | Sub-C redesign (old Step 9) | tonight |
| Accepts all commands | broaden the tool menu behind the existing router | tonight |
| Computer chores | file/folder lane: move, rename, organize, trash, reveal | tonight |
| Browse internet, collect information | Brave search + existing approved-page read | tonight |
| Run commands | shell execution lane, jailed by default | tonight, needs a spec first |
| Code / build software, websites, apps | **delegate** to installed Claude Code / codex CLI | tonight |
| Skills and intelligence | skills library the local model selects from | after the above |
| Cloud escalation (old Step 7) | needs provider, key, spend cap | **not tonight** — user decision + real money |

### The one architectural call worth recording

"Can code in any language, build software" is not something a local 8B model does
well, and reimplementing a coding agent inside OSPA is weeks of work. The user
already runs Claude Code and two Codex CLIs on this machine.

**So OSPA delegates.** It creates a jailed project directory, spawns the installed
coding agent there, streams progress into its own UI, and gates the destructive
operations through the consent machinery it already has. OSPA becomes the
orchestrator and the safety layer — which is what it is already good at. Chosen by
the user on 2026-08-03.

---

## Ordering constraint that drives everything

`AvatarModel` has **204 graph edges** (next node: 55) across 2961 lines, one flat
class, 52 `@Published`, 82 funcs, zero MARK sections. `AvatarView` is 1122 lines with
a single `body`.

Every feature below touches those two files. Three agents working in parallel before
the split means a night of merge conflicts instead of shipping. **The split is the
critical path and it runs first.**

---

## Phase 0 — running now, three lanes in parallel

| Lane | Worker | Worktree / branch | Brief |
| --- | --- | --- | --- |
| Split the god objects + multi-line chat fix | Codex 1 | `/Users/keyush/ospa-wt-refactor` · `feat/lane-refactor` | `BRIEF.md` in that dir |
| Web search foundation, unwired | Codex 2 | `/Users/keyush/ospa-wt-search` · `feat/web-search` | `BRIEF.md` in that dir |
| Shell execution spec + plan | Claude | main checkout | this doc + spec |

These three cannot collide: Codex 1 owns `AvatarCompanion`, Codex 2 adds new files in
`AvatarCore`/`AvatarPlatform` only, Claude writes docs.

Both worktrees verified with `git worktree list` to be at `f637edc` — the roadmap
records that this check was skipped once and two worktrees came off an old ancestor,
silently missing three tasks.

Worktrees are on the **internal disk**, not `/Volumes/ai-hub` (a removable SD card,
`Protocol: Secure Digital`). `.build` is only 208 MB, so three checkouts cost ~750 MB
against 34 GB free, and compiles avoid the SD card's I/O penalty entirely.

### Deliberately excluded from Phase 0

Codex 1 is told **not** to introduce a capability-lane abstraction, even though one is
needed. A seam invented blind, before anyone has seen the split, is a seam that three
later features build on top of. Claude designs it from the actual split result.

---

## Phase 1 — after the split lands

| Lane | Worker | Depends on |
| --- | --- | --- |
| Capability-lane seam, derived from the split | Claude | Phase 0 refactor |
| Shell execution lane | Codex 1 | shell spec + seam |
| Modern UI / Sub-C, whole app | Codex 2 | Phase 0 refactor |

### Shell execution — risk posture, decided 2026-08-03

This is now the **highest-risk capability in the project**, above browser control.
Browser control acts on a page; shell acts on the disk, the Keychain, the network.

The user asked for full shell access. It is being built as **jailed-by-default with a
deliberate escalation**, not as an always-on toggle:

**Default lane — jailed freeform:**
- Runs only inside a user-chosen project directory. No escaping it.
- No `sudo`. Ever, in this lane.
- Hard-refuse list: `rm -rf /`, `curl … | sh`, disk utilities, `security`/Keychain,
  `launchctl`, anything writing outside the jail.
- **argv previewed as a structured list, not a shell string** — with cwd, sudo state,
  and network access as separate labeled fields.
- One-shot expiring consent per command. Nothing batches.
- Full audit.

**Escalation lane — unrestricted:**
- Its own consent surface, off by default, expiring, same shape as the Accessibility
  consent the user already approves.
- Per-command confirmation still required.
- **Structurally unreachable from the web-read path and from search results.**

Why the preview is not itself a safety mechanism, recorded so nobody relaxes this
later:

1. A truthful preview still under-informs. `git push` and `git push --force` look
   nearly identical. `npm install` runs arbitrary postinstall scripts.
2. Compound commands hide in one line: `mkdir build && rm -rf ~/Documents`.
3. **The preview string is attacker-reachable.** This project already shipped a
   Critical of exactly this shape — the model's `reason` string had no
   control-character guard, so U+202E could reorder the justification the user read
   while authorizing. A command preview has the same weakness and higher stakes.
   Hence: structured argv, sanitized, never a raw shell string.
4. Slice 5 put web page text into the model's context. The answer-only rule makes
   actions structurally unreachable from that path today. Unrestricted shell must
   inherit that same structural block, not a validated one.

---

## Phase 2

- **Delegated coding agent.** Jailed project dir, spawn the installed CLI, stream
  progress into OSPA's UI, gate writes and commands. Depends on the shell lane.
- **Search wiring.** Connect Codex 2's search foundation to the UI and the router.
  Hard rule carried from the slice-5 design: a search result **never** authorizes
  fetching its URL. The user approves each host through the existing `ResearchGate`
  flow. Otherwise the model is choosing where the machine connects — the exact thing
  that design refused.
- **Skills library.** Curated procedures the local model selects from. Each skill
  names only capabilities that already exist and pass the existing validators; a
  skill is a plan template, never a new permission.

## Phase 3 — not tonight

- **Cloud escalation** (old Step 7). Needs the user's decision on provider, key
  storage, and spend cap before any code. Redacted, bounded task specs only — never
  full context, never raw page text, never Accessibility labels. Design JSON caps it
  at 5 cloud calls per task / 4000 tokens per step; honor that.
- **The live run.** All 302 tests use fakes. Nobody has started the MLX server and
  watched a real app open. This costs zero tokens and should be done by the user.
  It is also the only way to tune the 0.65 confidence threshold.
- **Merge.** PR #1 is stale and covers slice 1 only. Merge decisions are the user's.

---

## Standing rules for every lane

- `AvatarCore` stays pure: no AppKit, no network, no side effects.
- Model output is untrusted until Swift validates it. The prompt is never the safety
  mechanism.
- Nothing auto-executes. Preview + confirmation, always.
- Observe-only default; emergency stop clears pending state.
- One-shot expiring consent. Never widen or extend a grant.
- Audit is redacted — never page content, never user content, never keys.
- Plain language in every user-facing string.
- Never commit secrets, API keys, or tokens.
- Use `graphify explain` / `graphify path` instead of reading large files. Rebuild
  with `graphify update .`. **Never bare `graphify .`** — paid semantic pass.
- One step at a time: finish, `make test` green, `make app` builds, commit, push,
  append to the ledger, report, **stop**.
- Never merge or open a PR unprompted.

## Stop-and-ask triggers, mid-step

- First-time network access, cloud calls, or credential handling in a lane.
- A defect in an already-shipped safety gate.
- Spec and code disagree about a security property.
- A fix would require weakening any invariant above.
- Widening access on consent, pending plans, reasons, generation tokens, or audit.
