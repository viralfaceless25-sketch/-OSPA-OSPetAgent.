# Permissioned computer-use architecture

Milestone 2 defines universal foreground automation contracts. It does not generate
keyboard or pointer events and does not request Accessibility permission.

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
research scope, show exact limits, and record explicit approval. Network fetch and
Accessibility action generation intentionally remain disabled.
