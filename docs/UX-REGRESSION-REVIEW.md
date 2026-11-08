# UX regression and consistency review

Date: 2026-11-07. Scope: local mobile/desktop UX changes documented in
[PRODUCT-UX-HANDOFF.md](PRODUCT-UX-HANDOFF.md). No deployment performed.

## Result

The redesigned screens pass the repository's complete simulated-data rendering
suite and the new workspace interaction checks. They are ready for owner design
review and integration testing, not certified for production release.

| Check | Outcome |
| --- | --- |
| Existing page smoke suite, 390px and 1280px | 112 checks passed; 0 failures; 0 warnings |
| Workspace interactions: 14 screens at 320/390/768/1920/2560px | 70 combinations passed |
| Simulated service failures on 7 workspaces | 7 passed |
| Inline JavaScript syntax | 110 blocks passed |
| Shared guidance/navigation and new regression runner syntax | Passed |
| Git whitespace/diff check | Passed |

Workspace checks ran in targeted groups: 25 screen/width combinations and 45
remaining combinations. An initial test incorrectly expected a portfolio-wide
expense total while its URL selected Oak Street; the assertion was corrected to
expect that property's $240 total, then all affected remaining targets passed.
This was a test expectation error, not a passing assertion substituted for an
unexplained product failure. Seven failure cases ran separately.

## Consistency fixes in this review

- Tenant Home and Repairs now use the same contextual navigation as Payments,
  Documents, and Messages; current-page state and property context are retained.
- Tenant footer containers respect the full-width desktop preference.
- Property workspace has a semantic level-one page heading.
- Saved `tests/smoke/workspaces.js` so future developers can reproduce interaction
  and unavailable-data checks rather than relying on temporary scripts.

## What the checks exercise

- Full-width desktop workspace, no horizontal page overflow, and usable layouts
  at phone/tablet/wide desktop sizes.
- Property and tenant search/filter behavior, reset, and stable portfolio totals.
- Record/planned expense separation and property-scoped totals.
- Rent-period filtering without changing recorded amounts; keyboard tab switching.
- Repair planning prefill and Escape/return focus without saving.
- Form section navigation, review summaries, and literal text rendering.
- Tenant navigation, document types, message expansion, and payment search.
- Failures for property follow-up data, repairs, expenses, tenant rent schedule,
  documents, and message history. Unavailable data is not represented as zero.

The runner intercepts external requests and supplies invented Supabase fixtures.
Its fixture stub deliberately models queries loosely and does not establish
SQL schema compatibility, RLS isolation, settlement, notification delivery,
accounting correctness, or production integration behavior.

## Reproduce

From `/workspace/rental-genie`:

```sh
node tests/smoke/check-scripts.js
node --check shared/js/form-guide.js
node --check shared/js/tenant-resources.js
node --check tests/smoke/workspaces.js
CHROMIUM_PATH=/usr/bin/chromium node tests/smoke/run.js
CHROMIUM_PATH=/usr/bin/chromium node tests/smoke/workspaces.js
git diff --check
```

The workspace runner defaults to all 70 layout/interaction cases plus seven
failure cases. Page-name substrings narrow its targets; `--failures-only` runs
only the seven failure scenarios. No matching target is a failure, not a
zero-test success. It serves its own temporary local HTTP server, blocks live
external services, and closes its browser/server after execution.

## Release checks still outstanding

1. Owner review of the complete journey, language, spacing, and real portfolio
   sizes; screenshot artifacts are under `/workspace/artifacts/rental-genie-ux/`.
2. Actual iPhone Safari and Android Chrome: keyboard, camera/file picker, upload,
   screen rotation, safe areas, and home-screen mode. Desktop Chromium tests do
   not establish those results.
3. Accessibility with assistive technology and automated tooling: screen readers,
   form error announcements, contrast, text zoom, and modal behavior across browsers.
4. Isolated-backend end-to-end create/edit/renew, record payment, archive/restore,
   receipt upload/extraction, signed-file access, repair completion, and messages.
5. Financial and cross-company/tenant authorization tests. The rendering suite
   does not test money correctness or tenant isolation.
6. Address the existing maintenance edit completion-timestamp mismatch recorded
   in the handoff, and validate invoice/completion idempotency before automation.
7. Complete legal/business details and verify live notification settings and
   deployment prerequisites recorded in the product handoff.

All implementation remains local and uncommitted. Review the full diff before
merging: the repository can deploy from main. No live records, tenant messages,
payments, uploads, migrations, merges, or deployments were performed in this review.
