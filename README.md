# Avatar Companion

Native macOS foundation for a lightweight, draggable desktop avatar. Milestone 1
proves the interaction boundary. Milestone 2 adds app-agnostic discovery, research,
planning, consent, and audit contracts without enabling live automation.

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

No credentials, screen capture, accessibility-element inspection, input generation,
files, network fetch, shell, AppleScript, or global keyboard monitoring are used.
Accessibility is checked or requested only after selecting the corresponding button.

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

## Try preview-only computer use

1. Identify a foreground app.
2. Select **Check** to read current Accessibility trust without prompting.
3. Optionally select **Request from macOS** to trigger the system consent UI.
4. Select **Create preview-only ⌘S plan**.
5. Review exact app target, two typed visible steps, and readiness blockers.

The Command-S example is explicitly illustrative, not a learned universal shortcut.
The preview adapter has no execute method and always reports execution disabled.

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
```

`AvatarCore` has no AppKit dependency. UI and side-effect code live in the
executable target. See [SECURITY.md](SECURITY.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for capability requirements.

## Future real-action opt-in

Real computer use requires a later, separately reviewed executable adapter plus all
of these user actions: grant macOS Accessibility permission, disable observe-only,
review an evidence-backed capability profile, approve an exact expiring plan, and
confirm meaningful effects. Current build cannot generate events even when
Accessibility permission is granted.

## License

MIT. Chosen for simple reuse and contribution. See [LICENSE](LICENSE).

## Repository status

Local Git only. No remote repository is configured or pushed by setup.
