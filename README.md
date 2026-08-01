# Avatar Companion

Native macOS foundation for a lightweight, draggable desktop avatar. Milestone 1
proves the interaction boundary. Milestone 2 adds app-agnostic discovery, research,
planning, consent, and audit contracts. Later bounded milestones add confirmed
native opening plus explicit, read-only Accessibility evidence collection.

## Included

- Borderless floating SwiftUI/AppKit panel across Spaces and full-screen apps
- Drag from window background; expand/collapse by clicking avatar
- Menu bar show/hide and quit (`⌘⇧A` while app menu handling is active)
- Observe-only safe default
- Emergency stop (`⌘.`) from avatar or menu bar
- Closed command allowlist
- Preview plus explicit confirmation before any side effect
- Safe demo action: `copy time` writes current local time to clipboard
- Pure policy layer with Swift Testing coverage
- Foreground app identification using app name and bundle ID only
- User-reviewed official-documentation research scope
- Untrusted research artifact and reviewed-claim boundary
- Generic capability profiles and foreground computer-use adapter contract
- App-targeted, expiring, one-shot consent and action plans
- Execution preflight for focus, Accessibility permission, stop, and expiry
- Redacted audit event model
- User-triggered macOS Accessibility check/request flow
- Typed, non-executable visible-step previews with readiness blockers
- Deterministic foreground-context natural-language command composer
- In-memory redacted preview audit records
- Exact-name native app launch and foreground switching
- Separate executable-action card with per-action confirmation and audit
- Spotlight-style ranked local name search with exact-result selection
- Discoverable native, Safari web-app, and Chrome web-app bundles
- Explicit 15-minute Desktop/Documents/Downloads metadata scopes
- Preview-only visible Command-Space plan plus confirmed native exact-item fallback
- Deterministic ordered app plan with one confirmable lifecycle step
- Explicitly deferred, non-executable app-specific follow-up goals
- One-shot, exact-foreground Accessibility UI inspection
- Bounded, allowlisted, redacted control/action evidence and preview
- Confirmed real execution of typed visible steps through Accessibility actions
  and one bounded keyboard chord

No credentials, screen capture, file-content reads, network fetch, shell,
AppleScript, or global keyboard monitoring are used. Accessibility inspection
reads only a bounded allowlist of interactive metadata after two explicit user
steps; unknown labels are discarded before snapshot storage. Search reads only
local name/path/type metadata from user-approved scopes. Accessibility is checked
or requested only after selecting the corresponding button.

Input events are generated in exactly one place: a plan the user explicitly
confirmed, executed under a one-shot contract that expires in 30 seconds. Element
presses go through `AXUIElementPerformAction` and never through screen
coordinates; the only synthesized input is a single `CGEvent` keyboard chord from
a closed key allowlist. Observe-only is still the default, and emergency stop
still blocks planning and execution. See **Try real execution**.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer with Swift 6

## Build and test

```sh
make test
make app
open build/AvatarCompanion.app
```

For development:

```sh
make run
```

The bundle is ad-hoc signed for local use. Distribution needs an Apple Developer
identity, hardened runtime, notarization, and a unique bundle identifier.

## Try the safe action

1. Click avatar to expand.
2. Enter `copy time`, then select **Preview**.
3. Turn off **Observe only**.
4. Review action card, then select **Confirm and copy**.
5. Paste elsewhere to verify.
6. Select **Emergency stop**; pending action clears and observe-only returns.

## Try app discovery and research approval

1. Bring any desktop app to foreground, then open Avatar Companion from menu bar.
2. Select **Identify foreground app**. Only name and bundle ID are collected.
3. Enter an official HTTPS documentation URL.
4. Select **Prepare research scope**.
5. Review exact host, five-document cap, 15-minute expiry, and trust warning.
6. Select **Approve this research scope**.

Approval is demonstrable state only. No page is fetched in this milestone.

## Try computer-use planning

1. Identify a foreground app.
2. Select **Check** to read current Accessibility trust without prompting.
3. Optionally select **Request from macOS** to trigger the system consent UI.
4. Select **Create preview-only ⌘S plan**.
5. Review exact app target, two typed visible steps, and readiness blockers.

The Command-S example is explicitly illustrative, not a learned universal shortcut.
Rendering the plan never runs it: `PreviewOnlyForegroundAdapter` has no execute
method. Running it requires the separate confirmation below.

## Ask for several things at once

Type one request containing several: `open Safari and open Notes`, or
`open Safari, open Notes and then switch to Music`. Clauses split on `and`,
`then`, commas, and semicolons, up to five requests.

1. Turn off **Observe only**.
2. Type the request and select **Preview**.
3. Review the numbered list — every step is shown before anything runs.
4. Select **Confirm and run all N**.

One confirmation authorizes that exact list. The chain is the consent unit, but
each step still mints its own least-privilege, one-shot, 30-second grant and
contract when it starts, so a step that never runs never held authority.
Emergency stop and expiry are re-checked before every step, and the first failure
stops the rest — the progress list shows exactly how far it got and why it
stopped.

Every clause must be a supported command or the whole request is refused rather
than half-run. A request whose later clause is a goal rather than a command —
`open Netflix and continue playing One Piece` — keeps the existing behavior: the
first step is executable and the remainder is previewed as an explicitly
deferred, non-executable goal.

## Talk to it normally

Natural language is off until you turn it on. Nothing is sent anywhere: the
model runs on this Mac. OSPA lazily starts the configured MLX runtime at
`~/Models/.venv/bin/python`, or safely adopts a compatible server already running
on `127.0.0.1:8081` without taking ownership of it.

1. Turn on **Natural language**.
2. Type what you want in ordinary words, for example `i wanna listen to some music`.
3. Review the preview. It names one exact app and says why it chose it.
4. Confirm, exactly as you would for a typed command.

OSPA picks the app you actually use, not merely the one whose name matches the
topic, by reading how often you open each app from macOS itself. It never watches
you in the background to learn this.

The model only ever chooses from applications installed on this Mac. If it names
something that is not installed, OSPA refuses the suggestion and tells you the app
is missing rather than acting on it. Turning natural language on does not grant any
new ability: it can only reach actions you could already trigger by typing, and each
one still needs the same explicit confirmation.

## Try real execution

Only this flow generates input events. It stays behind every existing gate.

1. Bring the target app forward and identify it.
2. Grant Accessibility permission (**Check**, then **Request from macOS** if needed).
3. Turn off **Observe only**.
4. Build a plan — `focus this app`, or **Create preview-only ⌘S plan**.
5. Review the steps and confirm the readiness line reads *permission and
   foreground target match*.
6. Select **Confirm and run these steps**.

The button stays disabled unless a plan is pending, no readiness issue is open,
observe-only is off, emergency stop is clear, and the 60-second preview has not
expired. Confirming issues a fresh 30-second, one-shot `ExecutionContract`.

`RealForegroundInputAdapter` then re-runs the full preflight itself rather than
trusting the caller, burns the one-shot consent through `ConsentUseLedger`, and
re-checks expiry, emergency stop, and exact foreground bundle ID before *every*
step. Focus drift mid-plan stops the run. Confirming the same plan twice is
refused: the consent is already spent.

Steps execute by type. `accessibilityPress` resolves the element by role and
label in the live Accessibility tree, verifies it advertises `AXPress`, and calls
`AXUIElementPerformAction` — no screen coordinates are ever computed.
`keyboardShortcut` is the only path that synthesizes input, posting one bounded
`CGEvent` chord from a closed key allowlist. Activation steps reuse the native
workspace and generate no events.

Audit records keep outcome shape, contract ID, and plan ID only. Failure reasons
can name an on-screen control, so they appear in the status line and never in the
audit record. Accessibility is the only permission required; Input Monitoring is
not requested, because the app posts events and never taps them.

## Inspect one exact foreground app

1. Bring the target app forward, expand Avatar Companion, then select
   **Identify foreground app**.
2. Select **Check**. If permission is missing, use **Request from macOS**, approve
   in System Settings, then select **Check** again.
3. Select **Prepare inspection scope**. Nothing is read at this step.
4. Review exact bundle ID, 20-control/60-element/depth-4 caps, redaction rules, and
   60-second expiry.
5. Keep that exact app foreground and select **Approve and inspect once**.
6. Review sanitized controls and action evidence. Execution remains disabled.

The inspector checks exact foreground bundle ID and process before and during its
bounded traversal. It reads interactive roles, `AXTitle` or `AXDescription`, and
action names only. It never requests `AXValue`, selected text, document/static
text, pixels, browser data, or credentials. Labels survive only when equal to a
small generic-control allowlist such as Play, Pause, Search, or Settings. Every
other label becomes `[redacted label]` before snapshot storage. Audit records keep
request IDs, target bundle ID, counts, truncation, and outcome—never labels.

Some apps expose no supported controls because their UI is loading, isolated,
custom-drawn, or not Accessibility-compatible. Avatar Companion reports that
result and does not broaden inspection or fall back to screen capture.

## Try foreground-context commands

1. Bring a target app forward and select **Identify foreground app**.
2. In the command palette, enter one request:
   - `focus this app`
   - `save this document`
   - `find text`
3. Select **Preview**.
4. Review exact bundle ID, typed steps, effects, readiness blockers, expiry, and
   audit contract ID.

Parsing is deterministic and local. No LLM or network request occurs. Save and find
shortcuts are illustrative preview mappings, not claims that every app supports
them. Requests with multiple intents, unknown behavior, or high-impact verbs such
as send, delete, publish, or quit are rejected with a specific explanation.
Changing foreground apps after identification also blocks composition.

## Open or switch applications

Executable commands use exact locally installed application display names:

```text
open Safari
launch TextEdit
switch to Notes
focus Finder
```

1. Enter one command and select **Preview**.
2. Confirm the green card says **Executable native exact-app fallback** and review
   exact app name, bundle ID, effect, mechanism, and 60-second preview expiry.
3. Turn off **Observe only**.
4. Select **Confirm open** or **Confirm switch**.

Confirmation creates fresh 30-second, one-shot consent. `switch` works only for an
already-running app; `open` launches or activates. Resolution accepts no paths,
`.app` suffixes, multiple targets, documents, URLs, or fuzzy names. Execution uses
native `NSWorkspace`/`NSRunningApplication` activation and needs no Accessibility
permission. Started/result audit events contain generated IDs and redacted outcome.

## Search this Mac

1. Select **Search this Mac** or the same menu-bar command.
2. Review scope. Applications is required. Desktop, Documents, and Downloads are
   off until individually selected.
3. Select **Approve scope for 15 minutes**.
4. Type at least two characters, such as `net`.
5. Select one ranked exact result. Selection does not open anything.
6. Review the purple visible Command-Space plan and exact name, type, and path.
7. To use the current native fallback, review the green card, turn off
   **Observe only**, then confirm once.

Application search combines running apps, standard system/local/user Application
folders, and the local Spotlight application-bundle catalog. Native `APPL` bundles
and Safari `AAPL` web-app bundles are accepted; discoverable Chrome web apps use
normal application bundles. Personal search is query-scoped: matching filename,
path, and type metadata only within approved Desktop/Documents/Downloads roots.
It does not pre-index personal names, read file contents, traverse hidden items or
package internals, inspect browser profiles/history, search the network, or guess a
website/URL when no local result exists.

The purple route documents intended foreground behavior: invoke macOS Spotlight
with Command-Space, enter the selected name, verify exact result, then open. It is
deliberately non-executable because this build cannot inspect Spotlight results or
send Accessibility input safely. The green fallback uses macOS workspace services
to open only the selected URL; it is separately previewed, expiring, confirmed,
and audited. Avatar Companion does not replace or capture macOS Command-Space.

## Preview a bounded multi-step request

Enter:

```text
open Netflix and continue playing One Piece
```

The local deterministic parser renders:

1. **Open Netflix** — exact installed app identity, available through the existing
   green native fallback and separate confirmation.
2. **Continue playing One Piece** — unsupported, non-executable, and not queued.

Confirming step 1 authorizes only one app launch/focus action. Step 2 is not part of
the executable `ActionPlan`, consent grant, execution contract, or audit payload.
It would require a future foreground-computer-use adapter that can inspect visible
app state, present exact UI steps, and obtain a new confirmation. Current code may
collect one explicitly approved, redacted Accessibility metadata snapshot, but
does not sign in, search a catalog, resume media, send input, or make network
requests.

The sequence parser recognizes one exact launch/focus clause followed by a bounded
app goal. Known continue/resume-playing wording receives a precise deferred
playback label. Other allowlisted goal verbs render as unsupported. A bare second
application name remains rejected, so `open Safari and Notes` cannot become two
actions.

## Architecture

```text
AvatarView / menu bar
        │ intent
        ▼
    AvatarModel
      ├── CommandInterpreter ── ActionGate ── clipboard demo
      └── AppIdentity ── ResearchGate ── user-approved scope

ResearchArtifact (untrusted) ── review ── CapabilityProfile
        │
        ▼
ActionPlan ── ConsentGrant ── PlanValidator
        │
        ▼
ExecutionContract ── foreground preflight ── adapter + audit

PreviewValidatedPlan ── ComputerUsePreviewContract
        │
        ▼
PreviewOnlyForegroundAdapter ── exact steps + readiness, never events

Command palette ── ForegroundCommandComposer (local allowlist)
        │ exact AppIdentity + typed intent
        ▼
PreviewValidatedPlan ── preview contract ── redacted audit record

Exact app command ── installed-app metadata catalog ── green preview
        │ separate confirmation + action mode
        ▼
ExecutionContract ── native NSWorkspace activation ── redacted audit

Approved search scope ── local name metadata ── ranked candidates
        │ exact selection
        ├── purple Command-Space route ── preview only
        └── green exact-item fallback ── one-shot consent + redacted audit

Local sequence text ── exact app clause + deferred goal
        ├── step 1 ── existing one-step native plan + confirmation
        └── step 2 ── preview label only; unsupported and never queued

Exact foreground app + explicit inspection approval
        │ one-shot exact Accessibility scope + fresh focus checks
        ▼
Bounded AX metadata read ── allowlist/redaction ── evidence preview, never events
```

`AvatarCore` has no AppKit dependency. UI and side-effect code live in the
executable target. See [SECURITY.md](SECURITY.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for capability requirements.

## Future real-action opt-in

Real computer use requires a later, separately reviewed executable adapter plus all
of these user actions: grant macOS Accessibility permission, disable observe-only,
review an evidence-backed capability profile, approve an exact expiring plan, and
confirm meaningful effects. Current build cannot generate keyboard or mouse events
even when Accessibility permission is granted. Read-only inspection does not
disable observe-only or create execution authority. Current opening execution uses
only the separately confirmed native exact-item fallback.

## License

MIT. Chosen for simple reuse and contribution. See [LICENSE](LICENSE).

## Repository status

Local Git only. No remote repository is configured or pushed by setup.
