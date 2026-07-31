# Sub-A: Real Foreground Execution — Design

## Context

OSPA's whole point is to be "a techy friend in a box" for non-technical people — someone
who can actually *do* things on the computer for a scared or confused user. Today OSPA can
plan and preview foreground actions but cannot perform them: the computer-use surface is a
dry-run renderer (`PreviewOnlyForegroundAdapter`) that hardcodes `executionEnabled: false`
and has no `execute` method. The only real side effect that exists is the `copy time` demo
and confirmed native app launch/switch (`NativeApplicationExecutor`).

This sub-project gives OSPA hands: a real `CapabilityAdapter` that performs a bounded set of
visible foreground actions — pressing a real UI button and pressing a keyboard shortcut —
strictly inside the existing consent/preflight/audit gates. It is the foundation every later
piece (LLM brain in Sub-B, friendly UI in Sub-C) builds on. Capture/network/full execution
were *gated off* during preview, not forbidden; this turns execution on, deliberately and
narrowly.

Scope of this spec is **Sub-A only** (real execution of native-app control). The
non-technical-user UI overhaul is **Sub-C**, a separate spec, and the LLM brain is **Sub-B**.

## Goal / success criteria

- A new `RealForegroundInputAdapter` conforms to the existing `CapabilityAdapter` protocol
  and, given a valid `ExecutionContract`, actually performs the plan's steps on the frontmost
  app, returning a truthful `ExecutionOutcome`.
- Demo: with observe-only off and Accessibility granted, OSPA opens a target app (e.g.
  Calculator), then presses a real on-screen button via Accessibility — visibly, auditable,
  no screen coordinates — and records an `AuditEvent`.
- Every existing safety invariant still holds; no public API of `AvatarCore` changes shape.
- New logic is unit-tested; the AX/CGEvent boundary is mocked so `AvatarCore`/policy tests
  stay deterministic.

## Non-goals

- No vision, no screenshots, no coordinate clicks, no network, no LLM. (Those are later subs.)
- No new action vocabulary beyond the two already-typed `VisibleInteraction` cases.
- No change to how plans are validated or consented.

## Architecture

One new type in **AvatarPlatform** (never in AvatarCore):

```
RealForegroundInputAdapter: CapabilityAdapter
  kind = .foregroundComputerUse
  execute(_ contract) async -> ExecutionOutcome
```

It reuses the existing seam unchanged: `ExecutionContract → execute → ExecutionOutcome`, and
the caller keeps wrapping the outcome into an `AuditEvent` appended to `InMemoryAuditLog`. The
adapter is the missing concrete `CapabilityAdapter` — `PreviewOnlyForegroundAdapter` stays as
the dry-run renderer for the preview screen.

Dependencies are injected as small protocols so the adapter is testable without touching real
AX/CGEvent:

- `ForegroundEnvironmentProbe` — live `ExecutionContext` source (frontmost bundle id,
  `AXIsProcessTrusted()`, emergency-stop flag, `now`). System impl wraps `NSWorkspace` +
  `ApplicationServices`.
- `AccessibilityActionPerformer` — resolve an element by (role, label) in the frontmost app's
  live AX tree, verify it advertises `kAXPressAction` via `AXUIElementCopyActionNames`, and
  `AXUIElementPerformAction`. System impl reuses the traversal already in
  `SystemAccessibilityTreeSnapshotSource` (but matches the *real* AXTitle/AXDescription — no
  redaction, since this is a targeted press, not a stored snapshot).
- `KeyboardShortcutPerformer` — post a `CGEvent` keyboard chord (virtual keycode + modifier
  flags), keyDown/keyUp, to the frontmost app. Only path that uses CGEvent.
- `NativeApplicationExecutor` (existing) — for the two app-activation cases.
- `ConsentUseLedger` (existing actor) — burn one-shot consent.

All AX/CGEvent work is `@MainActor` (following `NativeApplicationExecutor` and
`AccessibilityUIInspector`), using `@preconcurrency import ApplicationServices`. The adapter is
`Sendable`; `execute` hops to `@MainActor` for the actual acts and returns a `Sendable`
outcome.

## Data flow (unchanged pipeline, new terminal executor)

```
ParsedApplicationCommand → ActionPlan (steps carry VisibleInteraction)
  → PlanValidator.validate → ValidatedPlan → ExecutionContract
  → RealForegroundInputAdapter.execute → ExecutionOutcome → AuditEvent
```

## execute() algorithm — re-verify at the last instant

Do not trust that the caller ran preflight. Mirror `NativeApplicationExecutor`'s belt-and-
suspenders:

1. Build a fresh `ExecutionContext` from `ForegroundEnvironmentProbe`.
2. `ExecutionPreflight.validate(contract, context)` — on throw, return `.denied(reason)`.
3. `await ConsentUseLedger.consume(contract.validatedPlan.consent)` — if `false`, return
   `.denied("consent already used")`.
4. For each `PlannedStep` in order:
   - Re-check `now < contract.expiresAt` and frontmost bundle id still equals the target
     (continuous foreground check, like the inspector's per-node re-check). Drift → `.denied`.
   - Dispatch on `step.visibleInteraction`:
     - `.accessibilityPress(role, label)` → `AccessibilityActionPerformer.press(role, label)`.
     - `.keyboardShortcut(key, modifiers)` → `KeyboardShortcutPerformer.post(key, modifiers)`.
     - `.activateTargetApplication` / `.launchOrActivateApplication` → delegate to
       `NativeApplicationExecutor`.
     - `nil` → `.failed("step has no executable interaction")`.
   - A failing step stops the run and returns its `.failed`/`.denied`.
5. All steps succeeded → `.succeeded`.

The preview screen flips `executionEnabled` to `true` only when this adapter is installed and
step 2 preflight is clean; otherwise it keeps showing the dry-run.

## Error handling

- Preflight throw → `.denied` with the mapped reason (emergency stop / expired / not
  foreground / permission missing).
- AX element not found, or found but does not advertise `kAXPressAction` → `.failed` with a
  plain-language reason (this becomes user-facing later, so no jargon: "Couldn't find that
  button on screen").
- `AXError`/`CGEvent` post failure → `.failed`.
- Consent already burned / replayed contract → `.denied`.

## Permissions / packaging

- Accessibility only. **No Input Monitoring** — the adapter *posts* (AX + CGEvent post), never
  *taps*. Requesting Input Monitoring would over-scope TCC.
- Ship non-sandboxed + notarized (already required for AX client APIs).

## Testing

- `AvatarCoreTests` / `AvatarPlatformTests` (Swift Testing, matching existing style):
  - Dispatch mapping: each `VisibleInteraction` case routes to the right performer (mocked).
  - Preflight re-check: denied on emergency stop, expiry, foreground drift, missing
    permission — via a fake `ForegroundEnvironmentProbe`.
  - Consent ledger: a replayed one-shot contract returns `.denied`; step order preserved;
    first failing step short-circuits.
  - No performer is invoked when preflight fails (observe-only path can't even build a
    contract, but assert emergency-stop/expiry gates independently).
- Manual end-to-end (documented in README "Try real execution"):
  1. Launch app, expand avatar, turn off observe-only, grant Accessibility.
  2. Identify Calculator foreground; build a one-shot press plan for a digit button.
  3. Confirm preview (now execution-enabled); observe the real button press; verify the
     audit record shows `.succeeded` with the target bundle id, no label leakage.

## Rollout

Feature branch `feat/sub-a-real-execution`. TDD: write failing tests per component, implement,
green, then wire the adapter into the app + preview screen and add the manual demo doc.
