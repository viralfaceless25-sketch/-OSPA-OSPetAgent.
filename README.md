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

No credentials, screen capture, Accessibility request, input generation, files,
network fetch, shell, AppleScript, or global keyboard monitoring are used.

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
```

`AvatarCore` has no AppKit dependency. UI and side-effect code live in the
executable target. See [SECURITY.md](SECURITY.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for capability requirements.

## License

MIT. Chosen for simple reuse and contribution. See [LICENSE](LICENSE).

## Repository status

Local Git only. No remote repository is configured or pushed by setup.
