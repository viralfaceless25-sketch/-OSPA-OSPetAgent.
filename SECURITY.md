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

## Milestone 2 trust boundaries

- Foreground app discovery reads only localized name and bundle identifier.
- Documentation research requires exact HTTPS host, small document cap, explicit
  approval, and short expiry.
- Research authorization is demonstrated, but no network fetcher ships yet.
- Retrieved content is modeled as untrusted provenance. It cannot define or invoke
  executable behavior.
- Claims require explicit review before capability profiles may reference them.
- Action plans bind typed capabilities to an exact foreground bundle identifier.
- Consent binds one plan, exact permission scopes, expiry, and one-shot use.
- Execution preflight rejects focus drift, missing Accessibility permission,
  emergency stop, or expired contracts.
- Audit events contain contract/plan IDs and redacted outcomes, not raw secrets.
- No accessibility-element inspection or keyboard/mouse/window event generation
  ships. Permission request arrives only in milestone 3.

## Milestone 3 permission and preview boundary

- Accessibility status checks use `AXIsProcessTrusted()` and do not prompt.
- The macOS permission prompt uses `AXIsProcessTrustedWithOptions` only from the
  explicit **Request from macOS** button.
- Granting OS permission does not enable execution.
- Visible steps are typed descriptions: target activation, shortcut, or named
  accessibility press. No raw coordinate or event payload exists.
- `PreviewValidatedPlan` checks exact target, capability, consent, expiry, risk,
  and permission scope without creating executable authority.
- `ComputerUsePreviewContract` is separate from `ExecutionContract`.
- `PreviewOnlyForegroundAdapter` has no execute method and always returns
  `executionEnabled = false`.
- Preview readiness reports focus drift, missing permission, emergency stop, and
  expiry. It reads no screen or accessibility-element content.

Real event generation requires a future explicit product milestone, executable
adapter review, user-granted Accessibility permission, action-mode opt-in,
evidence-backed profile, exact plan approval, and meaningful-action confirmation.

## Milestone 4 command-composer boundary

- Natural-language matching is deterministic, local, and token-based.
- Supported intents are a closed enum: focus app, illustrative save preview, and
  illustrative find preview.
- Exact foreground bundle ID must still match the previously identified app.
- Multiple supported intents are rejected as ambiguous.
- Unknown requests and high-impact verbs are rejected before plan creation.
- User text never becomes a raw event, script, coordinate, accessibility query, or
  audit payload.
- Composed interactions remain typed `VisibleInteraction` values.
- Preview contracts preserve exact permission scope, one-shot consent, 60-second
  expiry, stop state, and unconditional execution disablement.
- Preview audit records store generated IDs, target bundle ID, timestamp, and
  readiness issues—not the natural-language request.

This milestone adds no voice, screen inspection, network/LLM request,
accessibility-element read, keyboard/mouse injection, or foreground executor.

macOS Accessibility permission is process-wide. Future computer-use code must apply
stricter internal per-app targeting on every step. OS permission alone is never
treated as consent.

## Capability policy

Future capability additions must:

1. Declare exact resources and side effects.
2. Request macOS permission only in context.
3. Add a typed action and executor; never accept executable text.
4. Provide preview, explicit confirmation, audit record, cancellation, and timeout.
5. Remain blocked in observe-only and emergency-stop states.
6. Include policy tests before shipping.
7. Prefer visible foreground computer-use for universal behavior; revalidate focus
   and UI state before every action.
8. Treat official documentation as evidence only, never executable instructions.

## Reporting vulnerabilities

Do not include secrets, credentials, personal data, or exploit payloads in a public
issue. Until a private reporting address exists, open a minimal issue requesting a
private contact channel.
