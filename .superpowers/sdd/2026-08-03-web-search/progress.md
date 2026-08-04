# Web Search Foundation — Progress Ledger

Date: 2026-08-03
Branch: `feat/web-search`
Status: implementation complete; unwired by design

## Delivered

- `Sources/AvatarCore/WebSearch.swift`
  - Validated single-line `WebSearchQuery`.
  - Sanitized inert `WebSearchResult` and bounded `WebSearchResultSet`.
  - Typed `WebSearchError` with plain-language copy.
  - Redacted `WebSearchAuditEvent` storing query length, never query text.
- `Sources/AvatarPlatform/SearchCredentialStore.swift`
  - Small injected credential protocol.
  - On-demand macOS Keychain generic-password reader.
- `Sources/AvatarPlatform/WebSearch.swift`
  - Injected `WebSearchService` and transport protocols.
  - Brave Search client for the documented HTTPS endpoint.
  - Ephemeral `URLSession` streaming transport with a hard byte cap.
  - Existing approved-host redirect delegate reused for provider-only redirects.
- `Tests/AvatarCoreTests/WebSearchTests.swift`
  - Exact query rejection cases, hostile result validation, collection cap,
    redacted audit, and structural safety.
- `Tests/AvatarPlatformTests/WebSearchTests.swift`
  - No-key zero-network path, on-demand credential reads, exact bounded request,
    distinct typed failures, streaming cap, redirect refusal, Keychain shape,
    and source-level authority isolation.

No `AvatarCompanion` file was edited.

## Exact Bounds

| Value | Bound | Reason |
| --- | ---: | --- |
| Query | 400 Unicode scalars | Matches the task and Brave's documented query ceiling while counting Unicode explicitly. |
| Title | 200 Unicode scalars | Ample for a search-result title without allowing display flooding. |
| Snippet | 1,000 Unicode scalars | Enough context for result selection while remaining bounded. |
| Result URL | 2,048 Unicode scalars | Conventional practical URL ceiling; oversized provenance is refused. |
| Result set | 10 results | Task maximum; both caller request and provider response are checked. |
| Provider response | 1,048,576 bytes | More than sufficient for ten JSON results while limiting memory pressure. |
| Timeout | 15 seconds | Matches the existing outbound page-read timeout. |

All bounds refuse rather than truncate. Query, title, snippet, and decoded URL
text reject the same Unicode general categories used by `BrainChatAnswer`:
control, format, line separator, and paragraph separator. Queries reject newline
and tab even though surrounding ordinary whitespace is trimmed.

## Keychain and Missing-Key Behavior

`KeychainSearchCredentialStore` reads one generic-password item on every search:

- service: `com.ospa.avatar-companion.web-search`
- account: `brave-api-key`

The key is held only in a local variable long enough to build one request. It is
not published, cached, persisted outside Keychain, logged, audited, or included
in an error. `errSecItemNotFound` returns `nil`; `BraveSearchClient` then throws
`WebSearchError.apiKeyNotConfigured`, whose user copy is "Web search isn't set up
yet." The transport call count remains exactly zero. Other Keychain read failures
map to a credential-access error without exposing status or credential content to
the user-facing message.

Key provisioning is deliberately absent because this slice is unwired and adds no
UI. A later explicit setup flow can write the generic-password item without
changing the on-demand read boundary.

## Network and Authority Safety

- The only request target is `https://api.search.brave.com/res/v1/web/search`.
- The request asks Brave for exactly the caller's validated result count.
- Response bytes stream through a cap; the byte beyond the cap is never stored.
- Cross-host or HTTPS-downgrade redirects are refused by the existing
  `ApprovedHostRedirectDelegate` before follow. Final response URL is checked again.
- Search results contain title, URL, and snippet data only.
- Added source types contain no command, plan, or consent authority reference.
- Search never invokes the page fetcher, creates research authorization, changes
  approved research hosts, or offers an action.

## TDD and Verification Evidence

- Baseline: `make test` passed with 302 tests in 34 suites.
- Core RED: focused build failed because all new search types were absent.
- Core GREEN: 12 tests in 3 suites passed.
- Platform RED: focused build failed because client, transport, and credential
  abstractions were absent.
- Platform GREEN: final `swift test --filter WebSearch` passed with 24 tests in
  5 suites.
- Mutation check: weakening the `maxResults` guard made the invalid-limit test
  fail with two credential reads and two transport calls; restoring the guard
  returned the test to green.
- Full verification: `make test` passed with 326 tests in 39 suites.
- Release build: `make app` completed and signed `build/AvatarCompanion.app`.
- Graphify incremental update rebuilt 2,040 nodes, 5,483 edges, and 80
  communities. It retained the pre-existing warning that
  `ospa-brain-workflow.json` produces no graph nodes and noted that community
  labels can be refreshed separately.

Test delta: +24 tests, +5 suites.

## Commits

- `e25bde8 feat(search): add validated core values`
- `95968cb feat(search): add Brave client and Keychain`

## Deliberately Not Done

- No UI or `AvatarModel` wiring.
- No router lane or prompt change.
- No automatic result fetching or host approval.
- No page-fetcher integration.
- No result caching or persistence.
- No Keychain write UI.
- No merge or pull request.

## Reviewer Fix Round 1

- Added 15-second request and resource timeouts to the ephemeral search session
  configuration. Focused RED: `swift test --filter
  sessionConfigurationHasAbsoluteTimeouts` failed to compile because the
  configuration seam did not exist. GREEN: 1 test in 1 suite passed.
- Added the exact Brave query item `result_filter=web`. Focused RED: `swift
  test --filter buildsBoundedRequest` failed because the item was absent.
  GREEN: 1 test in 1 suite passed.
- Made the Brave `web` response field optional. Both `web: null` and a missing
  `web` field now decode to an empty bounded result set. Focused RED: `swift
  test --filter acceptsAbsentWebResults` threw `badResponse` for both fixtures.
  GREEN: both parameterized cases passed.
- Final focused verification: `swift test --filter WebSearch` passed with 26
  tests in 5 suites.
- Final full verification: `make test` passed with 328 tests in 39 suites.
- Final release build: `make app` completed, linked, and signed
  `build/AvatarCompanion.app`.

Deferred reviewer Minor: the structural authority guards currently inspect only
the search struct body and two source files. A future extension or
credential-store authority reference could therefore evade those guards. This
test-hardening concern is recorded for later work and is not part of this focused
fix round.
