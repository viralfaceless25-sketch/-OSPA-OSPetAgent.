# Sub-A Real Foreground Execution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a real `CapabilityAdapter` that performs bounded visible foreground actions (Accessibility press, keyboard shortcut, app activation) inside OSPA's existing consent/preflight/audit gates.

**Architecture:** One `@MainActor` orchestrator adapter in `AvatarPlatform` conforming to the existing `CapabilityAdapter` protocol. It re-verifies preflight + consent + foreground at execute time, then dispatches each `PlannedStep.visibleInteraction` to an injected performer (Accessibility / keyboard / workspace). System performers wrap real AX/CGEvent; unit tests use fakes.

**Tech Stack:** Swift 6.2, Swift Testing, AppKit, ApplicationServices (AX), CoreGraphics (CGEvent).

## Global Constraints

- Accessibility permission only. No Input Monitoring, no screenshots, no network. (spec)
- No public API of `AvatarCore` changes shape. New code lives in `AvatarPlatform`. (spec)
- All AX/CGEvent work `@MainActor`; `@preconcurrency import ApplicationServices`. (spec)
- No coordinate clicks — Accessibility press only. CGEvent limited to `keyboardShortcut`. (spec)
- Closed vocabulary: only the 4 existing `VisibleInteraction` cases. (spec)
- Failure reasons in plain language (become user-facing later). (spec)

---

### Task 1: Adapter core + injected performer protocols (unit-tested with fakes)

**Files:**
- Create: `Sources/AvatarPlatform/RealForegroundInputAdapter.swift`
- Test: `Tests/AvatarPlatformTests/RealForegroundInputAdapterTests.swift`

**Interfaces produced:**
- `enum ForegroundInputResult: Equatable, Sendable { case performed; case failed(String) }`
- `@MainActor protocol ForegroundEnvironmentProbe: AnyObject { func currentContext(now: Date) -> ExecutionContext }`
- `@MainActor protocol AccessibilityActionPerformer: AnyObject { func press(role: String, label: String, inBundleIdentifier: String) -> ForegroundInputResult }`
- `@MainActor protocol KeyboardShortcutPerformer: AnyObject { func post(key: String, modifiers: Set<ModifierKey>, toBundleIdentifier: String) -> ForegroundInputResult }`
- `@MainActor protocol ForegroundActivationPerformer: AnyObject { func activate(bundleIdentifier: String) -> ForegroundInputResult }`
- `@MainActor final class RealForegroundInputAdapter: CapabilityAdapter` with `nonisolated let kind: AdapterKind = .foregroundComputerUse` and `func execute(_ contract: ExecutionContract) async -> ExecutionOutcome`.

**execute() algorithm:**
1. `ctx = probe.currentContext(now: now())`; `try ExecutionPreflight().validate(contract, context: ctx)` — catch `ExecutionPreflightError` → `.denied(reason)`.
2. `guard await ledger.consume(contract.validatedPlan.consent) else { return .denied("Consent already used.") }`.
3. `target = contract.validatedPlan.plan.app.bundleIdentifier`.
4. For each step (in order): rebuild live ctx; guard `now < expiresAt` (`.denied("Execution contract expired.")`), `!emergencyStopped` (`.denied("Emergency stop is active.")`), `frontmost == target` (`.denied("The app you wanted is no longer in front.")`). Dispatch on `step.visibleInteraction`:
   - `.accessibilityPress(role,label)` → `axPerformer.press(...)`
   - `.keyboardShortcut(key,modifiers)` → `keyPerformer.post(...)`
   - `.activateTargetApplication` / `.launchOrActivateApplication` → `activationPerformer.activate(bundleIdentifier: target)`
   - `nil` → `.failed("This step has nothing I can do.")`
   - any performer `.failed(m)` → return `.failed(m)`.
5. All steps ok → `.succeeded`.

**Tests (fakes for all four performers + probe):**
- routes accessibilityPress to axPerformer; keyboardShortcut to keyPerformer; activate cases to activationPerformer.
- denied on emergency stop / expired contract / foreground drift / missing accessibility (fake probe).
- one-shot consent replay → second execute returns `.denied("Consent already used.")` (shared `ConsentUseLedger`).
- first failing step short-circuits; later performers not called; step order preserved.
- happy path multi-step → `.succeeded`.

- [ ] Write failing tests → run (fail) → implement adapter+protocols → run (pass) → commit.

### Task 2: System performers (real AX / CGEvent / activation)

**Files:**
- Create: `Sources/AvatarPlatform/SystemForegroundInputPerformers.swift`

Implements the four protocols against the OS:
- `SystemForegroundEnvironmentProbe`: `NSWorkspace.shared.frontmostApplication?.bundleIdentifier`, `AXIsProcessTrusted()`, emergency-stop read via injected `@MainActor () -> Bool`, `now`.
- `SystemAccessibilityActionPerformer`: pid via `NSRunningApplication(bundleIdentifier:)`, `AXUIElementCreateApplication(pid)`, bounded BFS (reuse traversal pattern from `AccessibilityUIInspector`), match element whose role == role and (`kAXTitleAttribute` or `kAXDescriptionAttribute`) == label, verify `AXUIElementCopyActionNames` contains `kAXPressAction`, `AXUIElementPerformAction(el, kAXPressAction)`. `AXUIElementSetMessagingTimeout(app, 0.5)`. Not found / no press action → `.failed("Couldn't find that button on screen.")`.
- `SystemKeyboardShortcutPerformer`: map `key` → `CGKeyCode` (bounded dictionary: a–z, 0–9, space, return, common), `Set<ModifierKey>` → `CGEventFlags`, post keyDown+keyUp via `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, `.flags`, `.post(tap:.cgSessionEventTap)`. Unknown key → `.failed("I don't know that key.")`.
- `SystemForegroundActivationPerformer`: reuse `SystemNativeApplicationWorkspace.activateRunningApplication(bundleIdentifier:)`; map result.

Not unit-tested (needs live UI); verified in Task 3 manual demo. Deliverable: compiles, `make test` still green.

- [ ] Implement → `make test` (green) → commit.

### Task 3: App wiring + preview execution-enable + manual demo doc

**Files:**
- Modify: `Sources/AvatarCompanion/AvatarModel.swift` (install `RealForegroundInputAdapter`, run it for confirmed computer-use plans, append `AuditEvent`, set preview `executionEnabled` true when adapter installed + preflight clean)
- Modify: `README.md` (add "Try real execution" — Calculator digit-press walkthrough)

- [ ] Wire adapter into model; flip executionEnabled → build app → manual Calculator press demo → verify audit `.succeeded`, no label leak → commit.

## Self-Review

- Spec coverage: adapter (T1), AX/CGEvent (T2), wiring+demo (T3), permissions/packaging (constraints) — all mapped.
- Types consistent with `ExecutionContract.swift`, `ActionPlanning.swift`, `AppDiscovery.swift` (verified).
- No placeholders in Task 1 (fully specified); Tasks 2–3 give concrete APIs + files.
