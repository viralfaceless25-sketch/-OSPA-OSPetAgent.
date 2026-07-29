# Security model

Avatar Companion starts with zero ambient automation authority.

## Milestone 1 guarantees

- Observe-only mode is enabled by default.
- Action vocabulary is a closed Swift enum, not arbitrary shell or AppleScript.
- Unknown commands are rejected.
- Every side effect has a visible preview and separate confirmation.
- Emergency stop immediately returns to observe-only mode and clears pending work.
- Only implemented side effect: writing formatted local time to clipboard.
- No network client, subprocess execution, persistence agent, credential input,
  Accessibility API, screen capture, microphone, camera, or file access.

## Capability policy

Future capability additions must:

1. Declare exact resources and side effects.
2. Request macOS permission only in context.
3. Add a typed action and executor; never accept executable text.
4. Provide preview, explicit confirmation, audit record, cancellation, and timeout.
5. Remain blocked in observe-only and emergency-stop states.
6. Include policy tests before shipping.

## Reporting vulnerabilities

Do not include secrets, credentials, personal data, or exploit payloads in a public
issue. Until a private reporting address exists, open a minimal issue requesting a
private contact channel.
