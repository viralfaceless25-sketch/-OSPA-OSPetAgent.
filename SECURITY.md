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

## Milestone 5 native application execution

Only exact-name app launch and switch commands are executable.

- Parser accepts one `open`, `launch`, `start`, `switch to`, `focus`, or `activate`
  command plus one application display name.
- Paths, `.app` suffixes, control characters, and multi-actions are rejected.
- Resolver reads bundle metadata only from running apps and standard local, system,
  and user Applications folders; it does not read user documents.
- Display-name matching is exact after case/diacritic normalization. Duplicate
  exact names are rejected.
- `switch` requires an already-running target. `open` launches or activates.
- Preview is clearly marked executable, names exact bundle ID/effect/mechanism, and
  expires after 60 seconds.
- Confirmation requires action mode and creates fresh 30-second, one-shot consent.
- Consent has no permissions because native app activation requires no
  Accessibility grant.
- Executor accepts only a validated `ExecutionContract` whose target and plan match
  the resolved application.
- Execution calls native `NSWorkspace.openApplication` or
  `NSRunningApplication.activate`; it never emits keyboard or pointer events.
- Audit records started and terminal outcomes with contract/plan IDs. Native error
  detail is redacted from audit.
- Emergency stop clears every pending native action immediately. A single launch
  request already handed to macOS cannot be recalled, but no follow-on step exists.

No clicks, typing, accessibility-element reads, screen capture, media playback,
browser/site interaction, network research, voice, or generic command execution
is enabled.

macOS Accessibility permission is process-wide. Future computer-use code must apply
stricter internal per-app targeting on every step. OS permission alone is never
treated as consent.

## Milestone 6 scoped local search

- Search begins with a visible scope review and explicit 15-minute authorization.
- Applications is required. Desktop, Documents, and Downloads remain off until the
  user selects each scope.
- Application discovery merges running apps, standard Application folders, and a
  local Spotlight application-bundle metadata query.
- Native `APPL` and Safari web-app `AAPL` bundles are allowed. Other bundle package
  types are rejected.
- Personal locations are searched only after a query with at least two
  alphanumeric characters. Wildcard metacharacters are escaped.
- Personal search requests filename matches from macOS metadata. It stores only the
  result name, exact path, item type, and approved source scope in memory.
- Search excludes hidden paths and common package internals. It does not read file
  contents, browser data, credentials, arbitrary roots, or network results.
- Results are ranked locally by normalized name only. Query text cannot become an
  action.
- Selecting one candidate binds exact URL, type, and scope. Selection itself has no
  side effect.
- The visible Command-Space route is a typed, non-executable preview. Keyboard
  injection and Spotlight-result inspection remain absent.
- Native exact-item opening is only a fallback. It requires action mode, a
  60-second preview, separate confirmation, a 30-second one-shot consent contract,
  exact scope revalidation, existence/type preflight, and redacted audit.
- A missing local result never becomes a guessed website, URL, browser search, or
  broader filesystem scan.
- Emergency stop clears search authorization, candidates, and pending opens.

macOS owns Full Disk Access, Files and Folders, and Accessibility permissions.
Avatar Companion neither bypasses denials nor silently widens scope when metadata
is unavailable.

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
