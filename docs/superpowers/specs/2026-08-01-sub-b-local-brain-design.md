# Sub-B Slice 1: Local Brain — Natural-Language Front-End — Design

## Context

OSPA can act on the Mac safely, but only understands a closed literal vocabulary:
`open <ExactAppName>`, `switch to <ExactAppName>`, `focus this app`, `save this document`,
`find text`, `copy time`, and chains of those. The user must type the exact installed
display name. "i wanna listen to some music" is rejected. For a product whose whole point
is being a techy friend for a non-technical person, that is the gap that matters.

Sub-B gives OSPA a brain. This slice is the first and smallest useful piece: a local model
that turns plain language into the actions OSPA **already performs safely**. It adds zero
new capability. It makes the existing capability reachable by speaking normally.

Scope here is slice 1 only. The router/evaluator/cloud-escalation and the three-tier web
stack described in `docs/brain/ospa-brain-workflow.json` are later slices; OSPA has no
network capability today and web browsing is its own sub-project.

## Goal / success criteria

- A user types "i wanna listen to some music" and OSPA previews **Open Spotify** — chosen
  because that is the music app this user actually uses — then executes it only after the
  normal confirmation.
- The model can never cause OSPA to name an application that is not installed. This is
  enforced in Swift, not by prompting.
- Every existing Sub-A safety invariant holds unchanged: observe-only default, emergency
  stop, one-shot expiring consent, execution preflight, redacted audit.
- No public API of `AvatarCore` changes shape. All 106 existing tests stay green.
- The brain is a *fallback*: typed exact commands keep working instantly and never reach
  the model.

## Non-goals

- No network, no cloud, no web browsing, no vision. (Later slices.)
- No new `VisibleInteraction` cases and no new adapter. Execution stays exactly Sub-A's.
- No multi-step chains from the model in this slice. One proposal per request. Chains
  remain reachable by typing them, and `TaskSequence` already handles that path.
- No learned-preference store. macOS already knows usage; see below.

## Measured basis for the design

Benchmarked on this machine (Apple M3 Pro, 18GB, macOS 27) against the real 129-app
inventory. These numbers drove the decisions and are recorded so later changes can be
compared honestly.

| runtime / model | warm latency | accuracy | resident weights |
| --- | --- | --- | --- |
| TurboFieldfare / Gemma 4 26B-A4B | 44s | 6/6 | ~2GB (streams from disk) |
| MLX / Qwen3-1.7B-4bit | 0.66s | 2/7, hallucinated | ~1GB |
| MLX / Qwen3-8B-4bit | **2.45s** | **8/9** | **~4.5GB** |
| MLX / Qwen3-14B-4bit | 4.51s | 8/9, over-refused | ~8.5GB |

Three findings shaped the architecture:

1. **Storage placement dominates streaming runtimes.** TurboFieldfare streams MoE experts
   from disk per token. On the SD card (102 MB/s) a single tool call exceeded 300s; on
   internal SSD (6.05 GB/s) the same call took 9.9s. It is designed for 8GB Macs and
   deliberately keeps only ~2GB resident, which wastes ~10GB of RAM on this machine. The
   fix was replacing the runtime, not tuning it.
2. **Prompt caching makes the full inventory free.** MLX caches ~99% of a stable prefix
   (1425/1439 tokens), dropping 1.65s to ~0.5s. So the entire app inventory can be sent on
   every request; no shortlist or escalation heuristic is needed. This requires the system
   prompt to be **byte-stable** across requests.
3. **Prompt strictness cannot buy safety.** Adding "never name an app that is absent"
   fixed Qwen3-8B's hallucination but caused Qwen3-14B to refuse a legitimate request
   ("watch some anime" with YouTube and Netflix installed). Tuning severity trades one
   failure for the other. Therefore the prompt optimizes for helpfulness and **the
   validator is the sole safety authority**.

Chosen: MLX + Qwen3-8B-4bit, thinking disabled.

## Architecture

Three layers, mirroring Sub-A's separation. Policy stays pure; effects stay at the edge.

```
AvatarCore (pure, no network, no AppKit)
  InstalledApplicationUsage      value type: name, openCount, lastUsedDaysAgo
  BrainToolCatalog               the closed tool vocabulary (three tools, below)
  BrainPromptBuilder             deterministic, cache-stable system prompt
  RawBrainToolCall               untrusted model output, as received
  BrainProposal                  validated, safe, closed enum
  BrainProposalValidator         RawBrainToolCall + inventory -> BrainProposal | error

AvatarPlatform (effects, injected behind protocols)
  LocalBrainService (protocol)   request + inventory -> RawBrainToolCall
  MLXBrainClient                 HTTP to 127.0.0.1:8081, OpenAI chat/completions
  ApplicationUsageSource (proto) inventory provider
  SpotlightApplicationUsageSource  reads kMDItemUseCount / kMDItemLastUsedDate
  LocalBrainServerController     lazy spawn / idle shutdown of the MLX server

AvatarCompanion (UI + wiring)
  AvatarModel.previewCommand()   brain runs only after deterministic parsers decline
```

### The closed tool vocabulary

Exactly three tools are offered to the model. Each maps onto an operation OSPA already
performs; none introduces new capability.

| tool | arguments | maps to |
| --- | --- | --- |
| `open_application` | `name`, `reason` | `ParsedApplicationCommand(.launchOrActivate, name)` |
| `switch_to_application` | `name`, `reason` | `ParsedApplicationCommand(.switchToRunning, name)` |
| `no_supported_action` | `reason` | no plan; the reason is shown to the user |

`reason` is one short sentence and is displayed in the preview so the user can see why
this app was chosen. It carries no authority and is never parsed for meaning.

Adding a fourth tool is a deliberate future change requiring its own validation rules; the
validator rejects any tool name outside this table.

### The safety boundary

This is the load-bearing part, and the reason the slice is shaped this way.

**The model does not author plans. It selects an intent from a closed menu.** It returns a
tool name plus an application *display name*. It never emits a bundle identifier, a
capability ID, an `ActionPlan`, or a `VisibleInteraction`. Those are all constructed by
existing deterministic Swift code from the validated name.

`BrainProposalValidator` treats every field as hostile input and enforces:

- tool name is one of the three known tools, else `unknownTool`
- required arguments present and non-empty, else `missingArgument`
- for app tools, the name matches an entry in the **live inventory that was supplied to
  the model for this request**, compared exactly after Unicode normalization and
  whitespace trimming, else `applicationNotInstalled`
- name length and control-character rules identical to `ApplicationCommandParser`

A validated `BrainProposal` converts to a `ParsedApplicationCommand` — the exact type the
existing typed-command path produces. From that point every downstream component is Sub-A
code, unmodified:

```
plain language
  -> MLXBrainClient -> RawBrainToolCall            (untrusted)
  -> BrainProposalValidator -> BrainProposal       (trusted, grounded)
  -> ParsedApplicationCommand                      (existing type)
  -> InstalledApplicationResolver                  (existing: name -> bundle id)
  -> ApplicationActionPlanner -> ActionPlan        (existing)
  -> preview shown to user -> explicit confirmation (existing)
  -> PlanValidator -> ConsentGrant -> ExecutionContract (existing)
  -> RealForegroundInputAdapter -> AuditEvent      (existing)
```

Consequences worth stating plainly:

- The brain cannot expand what OSPA can do. It can only reach what typing could already
  reach. A compromised or confused model changes *which* safe action is proposed, never
  what class of action is possible.
- Prompt injection is bounded by construction. The only untrusted text entering the model
  is the user's own request; output is constrained to a closed menu over apps proven to
  exist; and the user still sees and confirms the preview. The worst case is a wrong but
  safe proposal that the user declines.
- Nothing auto-executes. Brain output produces a preview, identical to typed input.

### Why macOS supplies the usage signal

"Which app does this user actually use for music" needs real preference data. macOS already
tracks it: Spotlight exposes `kMDItemUseCount` and `kMDItemLastUsedDate` per bundle. OSPA
reads that at request time, read-only.

This avoids building a background observer, avoids a new permission, avoids a learned
preference store that would drift, and avoids OSPA watching the user. It is why the model
picks Spotify (90 opens) over the never-opened Music app, and WhatsApp (3455 opens) for
messaging.

Inventory is the top-level `.app` bundles in `/Applications`, `/System/Applications`,
`/System/Applications/Utilities`, and `~/Applications` — 129 on this machine. Nested helper
bundles are excluded; Spotlight's raw 449 results include updaters and embedded helpers
that are not user-facing apps.

### Cache-stable prompt construction

Because MLX caching requires a byte-identical prefix, `BrainPromptBuilder` must be
deterministic:

- inventory sorted by `openCount` descending, then by name ascending as a tiebreak
- recency quantized to whole days (`"last 3d ago"`, `"never"`), never minutes or timestamps
- no clock value, no request ID, no session data anywhere in the system prompt
- the user's request is the only varying part, and it goes in the user message

A changed inventory (app installed or removed) legitimately invalidates the prefix: one
slow request, then fast again.

### Server lifecycle

`LocalBrainServerController` is an actor owning the MLX server as a child process.

- **Lazy start.** Spawned on the first natural-language request, not at app launch. First
  request pays ~10s of model load; subsequent requests are ~2s.
- **Idle shutdown.** After a configurable idle interval the server is terminated and the
  ~4.5GB is returned. This matters: the 14B measurably thrashed this machine (free memory
  0.08GB, 8.68GB compressed, 3.3GB swap) and unloading recovered 8.44GB immediately.
- **Health gate.** `GET /v1/models` must answer before any request is issued.
- **Graceful degradation.** If the server cannot start or does not become healthy within a
  timeout, OSPA reports plainly that the brain is unavailable and continues to accept typed
  exact commands. The brain is never required for OSPA to function.
- **Emergency stop** terminates the server along with clearing pending state.
- OSPA only ever stops a server it started.

## Error handling

Every failure produces plain, non-technical language, because these strings reach a
non-technical user.

| condition | behavior |
| --- | --- |
| server unavailable / unhealthy | "I can't think right now." Typed commands still work. |
| request timeout (default 30s) | cancelled, user told it took too long, no partial state |
| malformed JSON / unknown tool | treated as no proposal; never guessed at |
| `applicationNotInstalled` | "<Name> isn't installed on this Mac." — the hallucination path |
| `noSupportedAction` | model's own reason, surfaced verbatim |
| emergency stop mid-request | request abandoned, server stopped, nothing proposed |

The `applicationNotInstalled` case is expected in normal operation, not exceptional: an 8B
model will occasionally name a plausible-but-absent app, and this is precisely where the
validator earns its place. It becomes a helpful message rather than a failure.

## Testing

Following Sub-A's split: pure policy is exhaustively unit-tested; the model boundary is
mocked so tests stay deterministic and offline.

`AvatarCoreTests`:
- validator accepts each known tool with well-formed arguments
- validator rejects: unknown tool, missing/empty arguments, malformed shape
- **validator rejects an app name absent from the supplied inventory** (the hallucination
  regression test, drawn from a real observed failure: Qwen3-8B proposing Photoshop)
- name rules match `ApplicationCommandParser` (length, control characters, no paths)
- validated proposal converts to the expected `ParsedApplicationCommand`
- prompt builder is deterministic: same inventory produces byte-identical output
- prompt builder orders by usage then name, and quantizes recency to days
- inventory containing an app never opened renders as `never`

`AvatarPlatformTests` (fake `LocalBrainService`, no network):
- client maps a well-formed tool-call response to `RawBrainToolCall`
- HTTP error, timeout, and unparseable body each surface as a typed failure, never a crash
- server controller: starts once under concurrent demand, reports unhealthy correctly,
  shuts down when idle, and never terminates a process it did not start

Manual end-to-end, documented in the README:
1. Enable the brain, leave observe-only on.
2. Type "i wanna listen to some music"; confirm the preview names the expected app and
   that nothing executed.
3. Turn observe-only off, confirm, observe the app open, and check the audit event.
4. Type a request naming an uninstalled app; confirm the plain "isn't installed" message.

## Rollout

Feature branch `feat/sub-b-local-brain`, off the current `feat/sub-a-real-execution`. TDD
per component: failing tests, implement, green, commit. Wire into `AvatarModel` last, then
add the manual walkthrough to the README.

## Open questions, deliberately deferred

- Idle-shutdown interval needs real use to tune; starts at a conservative default.
- Whether the model should be allowed to propose short chains (the `TaskSequence` path
  already exists and is confirmed as one unit) — revisit once single proposals are proven.
- Model choice is recorded, not frozen. The `LocalBrainService` protocol makes swapping
  models or runtimes a one-file change, and the benchmark harness is retained for honest
  comparison.
