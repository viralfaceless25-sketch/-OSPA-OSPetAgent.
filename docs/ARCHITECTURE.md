# Permissioned computer-use architecture

Milestones 2–3 define universal foreground automation contracts, a user-triggered
Accessibility permission flow, and non-executable previews. They do not generate
keyboard or pointer events or inspect accessibility elements.

## Trust pipeline

```text
frontmost NSRunningApplication
  │ name + bundle ID only
  ▼
AppIdentity
  │ user enters official HTTPS documentation URL
  ▼
ResearchRequest ── exact host, document cap, 15-minute approval
  │ future fetch; raw text stays untrusted
  ▼
ResearchArtifact ── source URL + digest, never executable instructions
  │ explicit human claim review
  ▼
ReviewedClaim
  │ evidence-linked capability definition
  ▼
CapabilityProfile
  │ typed steps + exact foreground target + effect previews
  ▼
ActionPlan
  │ scoped, expiring, usually one-shot consent
  ▼
ValidatedPlan
  │ focus + permission + stop + expiry preflight
  ▼
ExecutionContract ── CapabilityAdapter ── AuditEvent

PreviewValidatedPlan ── ComputerUsePreviewContract
  │ typed descriptions only
  ▼
PreviewOnlyForegroundAdapter ── readiness report, execution always false
```

Every arrow is a code boundary. Web content cannot call tools, modify policy,
create consent, or become an action. A reviewed claim can support a typed
capability, but adapter code—not researched prose—defines executable behavior.

## Universal foreground computer-use

Primary adapter kind is `foregroundComputerUse`: visible keyboard, mouse, window,
and accessibility-element actions while the target app remains foreground.

macOS grants Accessibility permission at process level, not per target app.
Avatar Companion therefore applies a narrower internal policy:

- consent names one action plan and exact target bundle identifier;
- every visible automation capability declares an app-targeted policy scope;
- execution preflight rejects focus drift or missing OS permission;
- meaningful actions require preview confirmation;
- consent expires and defaults to one use;
- emergency stop blocks planning and execution preflight;
- adapter execution must append lifecycle events without secret parameters.

Per-app APIs, URL schemes, or documented scripts may become optional adapters when
useful. They are not required for universal interaction and cannot bypass the same
planning, consent, review, and audit gates.

## Accessibility permission flow

Permission has two explicit UI operations:

- **Check** calls `AXIsProcessTrusted()` without showing UI.
- **Request from macOS** calls `AXIsProcessTrustedWithOptions` with the prompt
  option. This call exists only in the button handler.

macOS owns the consent dialog and setting. Avatar Companion cannot grant itself
permission. A grant changes only reported readiness; it does not register an
executor, disable observe-only, or authorize any plan.

## Preview-only adapter

`VisibleInteraction` is a typed description enum. Current cases describe target
activation, a bounded keyboard shortcut, or a named accessibility press. No case
contains arbitrary code, raw events, unbounded text, or coordinates.

`PlanValidator.validateForPreview` validates exact app target, known capability,
exact permission scopes, expiring one-shot consent, risk, and explicit preview
confirmation. It returns `PreviewValidatedPlan`, which cannot initialize an
`ExecutionContract`.

`PreviewOnlyForegroundAdapter` renders:

- exact target app and bundle-scoped permission;
- ordered visible steps and effects;
- focus, permission, stop, and expiry readiness issues;
- an unconditional disabled execution state.

It deliberately does not conform to `CapabilityAdapter` and has no `execute`
method. This type separation prevents permission or preview state from becoming
ambient execution authority.

## Research boundary

Research uses a two-stage approval model:

1. User reviews exact HTTPS host, document limit, purpose, and short expiry.
2. After retrieval, user reviews extracted claims before profile publication.

Redirects must be revalidated against the same exact-host allowlist. Subdomains are
not implied. Credentials, wildcard hosts, non-HTTPS URLs, and query/fragment data
are rejected at proposal time. Future fetcher must impose response-size, MIME-type,
redirect, timeout, and private-network limits.

Research documents are data, never authority. Text that asks the agent to ignore
policy, call tools, reveal secrets, or approve itself remains inert.

## Adapter contract

Future adapter implementations conform to `CapabilityAdapter` and receive only an
expiring `ExecutionContract`. Before every step they must:

1. check emergency-stop/cancellation state;
2. confirm target bundle identifier is still foreground;
3. validate required macOS permission remains granted;
4. execute only typed step fields;
5. stop on unexpected dialogs, focus changes, or UI mismatch;
6. emit redacted audit outcome.

No generic “run this script,” raw keystroke string, arbitrary coordinate sequence,
or researched instruction text belongs in an execution contract.

## Current vertical slice

The avatar can identify the foreground app, stage an official documentation
research scope, show exact limits, record explicit approval, check/request macOS
Accessibility trust, and render a scoped illustrative plan. Network fetch,
accessibility-element inspection, and action generation remain disabled.
