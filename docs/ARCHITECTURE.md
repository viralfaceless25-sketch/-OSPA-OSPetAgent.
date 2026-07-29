# Permissioned computer-use architecture

Milestones 2–3 define universal foreground automation contracts, a user-triggered
Accessibility permission flow, and non-executable previews. They do not generate
keyboard or pointer events or inspect accessibility elements. Milestone 8 adds a
separate, explicitly approved, read-only and redacted Accessibility evidence path.

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

Command text ── local closed-intent composer ── exact AppIdentity
  │ supported typed recipe only
  ▼
PreviewValidatedPlan ── preview contract ── redacted PreviewAuditRecord

Exact app name ── standard app catalog ── ApplicationActionProposal
  │ action mode + separate confirmation
  ▼
ExecutionContract ── NativeApplicationExecutor ── redacted AuditEvent

Scope draft ── explicit 15-minute LocalSearchAuthorization
  │ application metadata + query-scoped approved personal metadata
  ▼
LocalSearchRanker ── exact candidate selection
  ├── SpotlightOpenPreview ── typed visible steps, never events
  └── LocalItemOpenPlan ── one-shot consent ── native fallback + audit

Command text with `and` ── ApplicationSequenceParser
  ├── exact first app clause ── existing one-step executable contract
  └── typed deferred goal ── ordered preview only; no authority

Exact AppIdentity + foreground PID ── one-shot inspection consent
  │ bounded AX roles/title-description/actions
  ▼
allowlist redactor ── AccessibilityUISnapshot ── non-executable evidence preview
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

## Foreground-context command composer

`ForegroundCommandComposer` is deliberately not an LLM. It normalizes local text
into tokens and matches a closed `SupportedForegroundIntent` enum:

- focus exact target application;
- illustrative Command-S preview;
- illustrative Command-F preview.

The composer returns either a typed recipe, an ambiguity reason, or an unsupported
reason. High-impact verbs are denied before matching. Similar words do not match by
substring. Multiple intents cannot share one consent.

The app binds a recipe only when the currently foreground bundle identifier equals
the identity the user previously captured. It then creates a 60-second, one-shot,
exact-scope preview plan. User text is discarded from the plan and audit; only
typed interactions and redacted effect descriptions cross the trust boundary.

Each rendered preview creates an in-memory `PreviewAuditRecord` containing contract
ID, plan ID, target bundle ID, timestamp, and readiness issues. It contains no
command text, screen data, or event payload. Emergency stop clears the active
preview while retaining audit history.

## Native application launch and switching

This is first real foreground executor. Scope remains one native app-lifecycle
operation:

1. `ApplicationCommandParser` accepts one explicit operation and display name.
2. `InstalledApplicationResolver` catalogs running apps plus standard system,
   local, and user Applications folders. It reads bundle name, bundle ID, and URL
   only, caches results, and requires one exact display-name match.
3. `ApplicationActionPlanner` produces one `.nativeAPI` capability and one typed
   launch/activate step. No Accessibility permission scope is requested.
4. Green executable preview shows exact target/effect and expires in 60 seconds.
5. Separate confirmation while action mode is enabled creates fresh 30-second
   one-shot consent and `ExecutionContract`.
6. `NativeApplicationExecutor` rechecks target, plan, stop, and expiry, then calls
   `NSWorkspace.openApplication` or `NSRunningApplication.activate`.
7. In-memory audit records started and redacted terminal outcome.

Switch refuses a stopped app. Open may launch or activate. Paths, documents, URLs,
fuzzy names, duplicate exact names, multi-actions, and arbitrary Launch Services
requests never enter the plan. The native executor contains no keyboard, pointer,
Accessibility-element, browser, media, or scripting API.

## Scoped Spotlight-style local search

`LocalSearchScopePolicy` separates requested scope from authorization. Applications
is always required; Desktop, Documents, and Downloads require visible opt-in.
Authorization is in-memory and expires after 15 minutes.

Application discovery uses three bounded metadata sources:

1. Running application bundle URLs.
2. Standard system, local, and user Application directories.
3. `NSMetadataQuery` filtered to local application bundles.

Only bundle path, display name, bundle identifier, package type, and running state
cross into the index. `APPL` and `AAPL` package types cover native/Chrome-style
apps and Safari web apps. No browser profile, history, shortcut database, or web
request is used.

Personal search does not build an ambient filename catalog.
`LocalMetadataSearchService` starts only after scope approval and a query with two
alphanumeric characters. It searches matching `kMDItemFSName` values inside the
approved root URLs, caps retained results at 200 before UI ranking, and returns
only name, path, item type, and source scope. Wildcards are escaped. Hidden paths,
package internals, and results outside exact standardized roots are rejected.
macOS privacy denial becomes a visible failure; scope is never broadened.

`LocalSearchRanker` performs exact, prefix, word-prefix, contains, then subsequence
name matching. It returns at most 12 candidates. A candidate cannot initialize an
executor. User selection first binds one standardized URL and produces a
`SpotlightOpenPreview`:

1. Press Command-Space.
2. Enter selected exact name.
3. Verify highlighted name, kind, and location.
4. Press Return.

This route remains non-executable. Without Accessibility input plus exact
Spotlight-result inspection, step 4 cannot be proven safe. The app does not capture
or replace macOS Command-Space.

`LocalItemOpenPlan` is a narrow native fallback for selected files and folders.
`LocalItemOpenValidator` requires current scope authorization, action mode,
unexpired plan and consent, empty macOS permission scope, and explicit
confirmation. `NativeLocalItemExecutor` rechecks path existence/type, asks Launch
Services for the registered handler, and opens that exact URL with recent items
disabled. Started/terminal audits omit the path and raw error detail.

## Bounded application sequences

`ApplicationSequenceParser` handles a deliberately narrow shape:

```text
<open-or-focus exact app> and <later app goal>
```

It delegates the first clause to `ApplicationCommandParser`. The second clause is
never executable. Continue/resume-playing wording becomes
`DeferredApplicationGoal.continuePlayback`; a closed verb set can produce
`.unsupported`; a bare second app name is rejected.

`ApplicationSequencePlanner` binds the exact `ResolvedApplication` before rendering
two `ApplicationSequenceStep` values:

1. `confirmableNow`: the existing single native launch/focus proposal.
2. `deferredUnsupported`: a preview explaining future visible interaction,
   exact UI-state verification, and fresh confirmation requirements.

Only step 1 has a capability profile, `ActionPlan`, preview consent, execution
contract, executor path, and audit lifecycle. Step 2 text is absent from all those
types. Confirming step 1 therefore cannot create ambient authority for playback or
any other follow-up. The model keeps step 2 visible after step 1 succeeds and
reports that it was not attempted or queued.

## Scoped Accessibility evidence

Read-only inspection is a separate contract from action planning:

1. User identifies one foreground `AppIdentity`.
2. User explicitly checks or requests macOS Accessibility permission.
3. **Prepare inspection scope** rechecks exact foreground bundle ID and creates a
   60-second `AccessibilityInspectionRequest`; no AX read occurs.
4. **Approve and inspect once** creates exact bundle-scoped, 30-second, one-shot
   consent.
5. `AccessibilityInspectionValidator` requires exact target, permission, approval,
   expiry, bounds, unused consent, and no emergency stop.
6. Model resolves current foreground PID. System source verifies that PID before
   and throughout its breadth-first traversal.
7. Source visits at most 60 elements to depth 4. Only supported interactive roles
   may read `AXTitle`/`AXDescription` and action names.
8. `AccessibilitySnapshotRedactor` drops unknown roles/actions, replaces unknown
   labels, retains at most 20 controls, and creates an expiring snapshot.
9. `AccessibilityInteractionPreview` renders sanitized evidence and hard-codes
   `executionEnabled = false`.

The source never requests `AXValue`, selected text, static/document text, or screen
pixels. No `AXUIElementPerformAction`, `CGEvent`, keyboard, mouse, browser, network,
login, or media path exists. Raw labels are transient between the AX call and
redactor; they are neither logged nor persisted. Focus drift or source failure
returns no partial snapshot. Audit records contain only IDs, exact target bundle
ID, timestamps, retained count, truncation, and coarse outcome.

Observe-only does not block this explicit read-only inspection; it still blocks
every execution route. Emergency stop blocks both preparation and inspection.
Empty snapshots are valid evidence that the app exposed no supported controls;
they never trigger broader inspection.

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
Accessibility trust, compose three local foreground intents, and render a scoped
illustrative plan. It can also launch or foreground one exactly named local app
after a separate confirmation. It can search approved local name metadata, bind one
exact result, preview the intended visible Command-Space route, and use a confirmed
native exact-item fallback. It can also split one exact app lifecycle action from a
later app goal, confirming only the first while retaining the second as unsupported
preview text. Finally, it can collect one explicitly approved, bounded, redacted
Accessibility metadata snapshot from the exact foreground app and render
non-executable interaction evidence. Network/LLM requests, voice, screen-pixel
inspection, content/value capture, clicks, typing, media, and generic action
generation remain disabled.
