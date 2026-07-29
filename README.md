# Avatar Companion

Native macOS foundation for a lightweight, draggable desktop avatar. Milestone 1
deliberately proves the interaction and safety boundary before adding automation.

## Included

- Borderless floating SwiftUI/AppKit panel across Spaces and full-screen apps
- Drag from window background; expand/collapse by clicking avatar
- Menu bar show/hide (`⌘⇧A`) and quit
- Observe-only safe default
- Emergency stop (`⌘.`) from avatar or menu bar
- Closed command allowlist
- Preview plus explicit confirmation before any side effect
- Safe demo action: `copy time` writes current local time to clipboard
- Pure policy layer with Swift Testing coverage

No credentials, screen capture, Accessibility permission, files, network, shell,
AppleScript, or global keyboard monitoring are used.

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

## Architecture

```text
AvatarView / menu bar
        │ intent
        ▼
    AvatarModel ─── CommandInterpreter (closed vocabulary)
        │
        ▼
     ActionGate ─── observe-only + emergency-stop + confirmation
        │ allowed only
        ▼
 AppKit executor ── clipboard write (only current capability)
```

`AvatarCore` has no AppKit dependency. UI and side-effect code live in the
executable target. See [SECURITY.md](SECURITY.md) for capability requirements.

## License

MIT. Chosen for simple reuse and contribution. See [LICENSE](LICENSE).

## Repository status

Local Git only. No remote repository is configured or pushed by setup.
