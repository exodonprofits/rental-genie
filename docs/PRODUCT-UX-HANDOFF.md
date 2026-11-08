# Rental Genie: product and UX implementation handoff

Updated: 2026-11-07. Audience: Claude Code and other developers.

## Objective

Help independent landlords run their portfolio through management by exception:
software handles routine follow-through; the owner sees decisions, unusual costs,
missed payments, deadlines, and urgent issues. Measure reduced owner effort rather
than the number of pages or AI features. Do not promise effortless ownership or
imply that emergency response, legal decisions, or physical work are automatic.

## Read first

- `README.md`, `CLAUDE.md`, and the current Git diff.
- `docs/pre-launch-audit/` is historical evidence from October 9. Several findings
  have since been addressed. Reproduce findings against current code; do not reuse
  its old launch score or live-verification claims as current facts.
- Static HTML/CSS/JS; no bundler or production build. Supabase handles data/auth.
- Rental Genie migrations belong in `supabase/rentalgenie-project/migrations/`.
  `supabase/migrations/` is the old shared project's history.
- Merging main can deploy. Do not deploy, merge, migrate a live database, send
  tenant communications, or process payments merely to validate a UI change.

## Work ownership and boundaries

Current implementation stream: mobile/desktop UX iterations, documented below.
Dashboard pilot: `dashboard.html`, scoped styles `#workspace-design`. Property,
rent, maintenance, expense, form, and tenant iterations now also have local edits.
Next recommended step is combined regression and integration review.

Claude Code can take a separate backend/automation workstream below. Before
editing, check the current diff and coordinate ownership of shared files. Keep
changes small, preserve existing work, and do not rewrite the dashboard while
another developer owns it. This document records proposed work; it does not claim
that payment, vendor, screening, signature, or AI integrations have been built.

Do not introduce a frontend service-role key. All privileged actions need
server-side authorization and company/property access checks. Use invented test
data and an isolated test backend for integration testing.

## Dashboard pilot delivered in this change

- Full-width desktop workspace, header, and footer with comfortable side padding;
  no fixed maximum page width (owner preference).
- Short workspace heading with direct Record rent action.
- Portfolio summary uses existing fetched outstanding-rent, open-maintenance,
  and expiring-lease data; no new financial calculation or query.
- Shortcuts to expense entry, repair entry, properties, and tenant messages.
- Setup checklist and attention list precede payment-inbox setup.
- Desktop attention cards use two columns; phone cards stack.
- Detailed reports remain available in a collapsed disclosure.
- Keyword page router is honestly labeled Find a tool, with an input label.
- Updated timestamp, refresh-failure feedback, and initial-load failure message.
- Visible focus treatment, skip link, reduced-motion support, and touch-sized
  attention actions. Existing six-item navigation stays consistent with other
  pages pending a coordinated navigation migration.

Existing rent calculations, auth bootstrapping, payment confirmation, and backend
workflows remain in place. The page still derives its data from the existing fetch
function. The timestamp means a fetch completed, not that every upstream service
or individual query is healthy. Existing swallowed query failures need separate
reliability work before stronger freshness claims are appropriate.

## Next UX work, in order

1. Review the dashboard pilot with the owner before applying its visual language
   across the app. Keep terminology and destinations consistent.
2. Property workspace: overview, tenant/lease, finances, repairs, documents, and
   activity in one context. Preserve property IDs through navigation.
3. Rent workspace: explicit outstanding/received states, clear date periods,
   readable mobile ledger cards, and a short payment-recording flow.
4. Maintenance workspace: status, urgency, next responsible person, appointment,
   quote, and next action together. Emergency instructions must be explicit.
5. Guided property/lease forms: short steps, validation near inputs, safe drafts,
   prefill from existing data, clear unsaved-change handling.
6. Coordinate app-wide navigation. A five-item mobile design (Home, Properties,
   Rent, Maintenance, More) is proposed, not yet implemented. Do not create a
   dashboard-only navigation scheme that conflicts with every destination page.
7. Tenant mobile flows: request repair, upload photos, view balance/documents,
   and communicate with the landlord with clear delivery states.

Use self-contained pages and shared patterns supported by the repository. Prefer
small reusable components when behavior repeats; do not introduce a framework
migration without a separate technical justification.

## Parallel backend/product workstreams

### A. Reliable notifications and automation (first backend priority)

Inspect `json/n8n-reminder-workflow.json`: the checked-in export has placeholder
credentials/addresses and queries a reminders table absent from the inspected
Rental Genie migration set. Inspect deployed configuration separately; repository
exports do not establish live deployment state.

Implement durable jobs/outbox records, unique event keys, retry/backoff, delivery
status, opt-out/preferences, timezone handling, and owner-visible failures.
Maintenance acknowledgment currently inserts messages and sends email without
visible idempotency protection, and returns HTTP 200 even on partial failure.
Resolve recipients from authoritative tenant/lease/property records rather than
accepting payload email solely on a tenant-ID match.

Acceptance: duplicate events produce one logical notification; temporary delivery
failure retries safely; permanent failure is visible; preferences are respected;
unauthorized company/property/recipient combinations are rejected. No live sends
without explicit authorization.

### B. Rent collection and reconciliation

Current app records rent; online collection is not built. Choose a provider and
settlement model before implementation. Add provider-hosted payment authorization,
autopay, verified webhooks, idempotency, settlements, returns, partial payments,
refunds, reconciliation, and receipts. Keep provider settlement separate from
expected rent and from an unconfirmed forwarded payment email.

Acceptance: duplicate/out-of-order events, failed payments, reversals, and partial
payments preserve correct balances and an auditable history. Use provider sandbox.

### C. Maintenance coordination

Connect request -> triage -> vendor assignment -> quote -> owner approval when
required -> appointment -> completion evidence -> invoice -> linked expense.
Vendor directory, response deadlines, owner spending policies, and emergency
escalation are required to reduce coordination work. Never imply that an automated
acknowledgment confirms dispatch.

Acceptance: every open job has an accountable next step; overdue responses escalate;
expenses cannot be duplicated by repeated completion events.

### D. Leasing, vacancy, and deposits

Connect listing, inquiry/showing, application, screening-provider integration,
owner decision, electronic signature, move-in inspection, deposit accounting,
renewal, move-out inspection, and disposition deadlines. Choose target jurisdiction
before implementing legal notices or deposit rules. Preserve owner review for
binding actions and tenant selection.

Acceptance: records carry forward without re-entry; deadlines have clear owners;
lease changes preserve effective dates and history; deposits remain liabilities
until a supported disposition is recorded.

### E. Financial integrity and portability

Add bank reconciliation, clear operating income versus cash-flow definitions,
correction history, month close, complete exports, and tested restore procedures.
Account export in `account.html` currently selects tables without pagination;
API row caps can truncate exports. Paginate with stable ordering and report counts
and completeness, including how documents are exported.

Acceptance: known fixture portfolios reconcile to expected ledger/report totals;
exports exceed API page size without omission or duplication; restore is exercised.

### F. AI assistance (after dependable workflows)

Start with authorized, record-backed answers and drafts. Cite relevant records,
show the date period, and explain unavailable data. Add bounded actions only after
the underlying workflow supports authorization, retries, audit history, and
owner-defined approval thresholds. Treat tenant text and uploaded documents as
untrusted input, not instructions.

## Validation

From repository root:

```sh
node tests/smoke/check-scripts.js
CHROMIUM_PATH=/usr/bin/chromium node tests/smoke/run.js dashboard
```

Full page rendering suite when broader pages change:

```sh
cd tests/smoke
npm ci
CHROMIUM_PATH=/usr/bin/chromium npm test
```

The browser suite stubs Supabase and external dependencies. It proves rendering,
not live permissions, accounting correctness, delivery, or provider integration.
Use SQL and integration tests against a separate test backend for those claims.

Dashboard UX acceptance: 320, 390, 768, and 1280px without horizontal overflow;
working keyboard focus and topic routing; loading, empty, refresh-error and
initial-error states; readable long names and large balances; usable mobile
navigation; details disclosure opens; desktop charts still render after opening.
Real iPhone Safari and Android Chrome checks remain required for keyboard,
photo-upload, safe-area, and home-screen behavior.

## Outcome measures

Track owner minutes per property/month, automatically reconciled payments,
maintenance follow-up interventions, missed deadlines, mobile task-completion time,
and detected/resolved automation failures. Establish a baseline before assigning
numeric improvement targets.

## Current verification record

Before this change: 110 inline scripts parsed; 112 simulated browser checks passed
with no warnings. These are not live-service or security certification results.

Dashboard pilot: 110 inline scripts parsed; dashboard-filter smoke run completed
4 checks (dashboard plus the legacy portfolio-dashboard redirect), with no failures
or warnings. Additional Playwright checks at 320, 390, 768, and 1280px verified no
horizontal overflow, populated summary, collapsed details, report expansion/chart
visibility, refresh-failure feedback with an enabled retry, and topic navigation.
Screenshots were inspected with invented data. Captures are local artifacts under
`/workspace/artifacts/rental-genie-ux/` and are not committed.

Real-device, live Supabase, and full integration verification remain outstanding.
This pilot is a starting point, not an app-wide redesign completion claim.


## Properties and property workspace iteration

Implemented locally after the dashboard pilot:

- `property-management.html`: full-width desktop layout; responsive property
  cards; tenant/name/address search; occupancy and needs-attention filters;
  portfolio totals independent of the filtered results; resettable empty search.
- Cards consume the database `rg_rent_status` balance and non-archived open/in-progress
  maintenance counts. Their next action prioritizes outstanding rent, repairs,
  vacancy, then a missing lease record. This is a rule-based suggestion, not an
  automatic task execution or a promise that all obligations are covered.
- Property data remains usable if follow-up queries fail. Unavailable values are
  explicit; failures do not appear as zero balances or zero repairs.
- Property cards use DOM creation and textContent for database text; no dynamic
  HTML interpolation in the new renderer. Existing legacy insights remain in a
  collapsed Portfolio follow-ups disclosure, pending later cleanup.
- `property-overview.html`: full-width workspace and property-scoped navigation to
  lease/tenant, reports, repairs, documents, expenses; selected property/company
  context is preserved when switching destinations.
- The simple rent-minus-mortgage comparison is labeled explicitly and does not
  claim to represent NOI or complete cash flow. Accounting logic was not replaced.

Validation: 110 inline scripts parsed; 4 relevant smoke checks passed without
warnings. Additional simulated-data browser checks at 320/390/768/1920px cover
search by tenant, stable portfolio totals, reset filters, vacancy next step,
selected-property navigation, partial data failure, safe literal property-name
rendering, and a recoverable full load failure. Screenshot artifacts live outside
Git under `/workspace/artifacts/rental-genie-ux/`. Real-device and live backend
verification remain outstanding. No schema changes or deployment performed.

Next UX priority: rent workspace, followed by maintenance coordination screens.
Do not treat the cross-page navigation here as a completed single-page tab system:
it opens existing property-filtered destinations, whose redesign is still pending.

## Lease & Rent iteration

`lease-rent-center.html` now uses the full desktop width and the same workspace
visual direction. Selected-property context links back to the property workspace.
The Rent & payments and Lease & tenant tabs support arrow/Home/End keyboard
navigation with selected state and roving focus.

The ledger remains a table on desktop. Below 760px, its rows become labeled cards
while retaining table/row/cell semantics and accessible column headers. Existing
ledger actions remain connected to their original handlers. A new client-side
view filter shows outstanding (default), paid, upcoming, or all periods, with a
visible result count. It filters the existing database-derived schedule rows;
it does not recalculate rent or change payment records.

Portfolio follow-ups are collapsible when a property is selected, and open for
portfolio-level attention links. Payment actions are labeled Record payment, with
an explanation that the page records received money rather than collecting it.
Ledger late-fee figures remain informational and separate from the rent balance.
Important existing behavior: the payment form can suggest adding a late fee based
on lease terms and its inclusion/waiver controls. This UX iteration preserves that
behavior; it does not authorize fees or change accounting policy.

The recording dialog now has a dialog role, accessible title/close label, focus
containment, Escape handling, and return focus. Real phone keyboard/viewport and
screen-reader verification still need device testing.

Validation with invented data at 320/390/768/1920px: no horizontal page overflow,
full desktop width, all four ledger filters, unchanged displayed amounts across
filter changes, due-date and existing late-fee amount prefill, dialog focus wrapping
and return, keyboard tab switching, and property/company navigation context.
110 inline scripts parse; targeted smoke tests cover Lease & Rent and the legacy
add-payment redirect. No live writes, payment-provider calls, schema changes, or
deployment were performed. Screenshots: `/workspace/artifacts/rental-genie-ux/rent-*.png`.

Next UX priority: Maintenance, especially clear job status, assignment, scheduling,
quote review, and next responsible person. Backend automation remains a separate
workstream; visual controls must not imply it already exists.

## Maintenance iteration

`maintenance-requests.html` now has a full-width desktop repair worklist and
mobile cards below 900px. Visible work plans show recorded vendor, appointment,
estimate, and a rule-based next step. Unresolved emergencies sort before routine
work; resolved/archived records sort after unresolved records. These suggestions
are not automated dispatch, verified vendor acceptance, or guaranteed response.

Added current-view summary counts, Unassigned and Unscheduled quick views, vendor
search, reset filters, refresh, explicit unavailable counts, and safe error text.
The existing seven-day filter is labeled Unresolved 7+ days; it is not a legal
response-time rule or a promise that appointments are overdue. Active company
context remains in filter URLs. A request sequence guard prevents stale fetch
responses replacing newer results. Reimbursements remain accessible in a
collapsible section. Existing start/complete/invoice/archive/restore handlers and
save payloads remain in place.

The edit form is now labeled Plan & update repair, its fields have explicit
labels, and it supports initial focus, Tab wrapping, Escape, and focus restoration
when canceled. It edits existing records; no vendor notification is sent by merely
entering a vendor name or appointment.

Validation with invented data at 320/390/768/1920px: no horizontal page overflow,
full desktop width, work-plan values, emergency guidance, unassigned/unscheduled
filters, vendor search, filter reset, empty counts, load failure with unknown
counts, safe error rendering, modal prefill, and keyboard focus handling.
110 inline scripts parse. Targeted smoke checks cover Maintenance and its legacy
history redirect. No live data changes, tenant messages, migrations, or deployment.
Screenshots: `/workspace/artifacts/rental-genie-ux/maintenance-*.png`.

Backend follow-up found during inspection: `saveEdit()` currently assigns a
completion timestamp for Completed/Closed, while the edit status selector submits
Resolved. The separate Complete action handles Resolved. Unify timestamp behavior
in a dedicated workflow fix with persistence tests; this UX pass does not claim to
resolve it. Also verify completion/invoice idempotency before automating those
operations, as described in the earlier product workstream.

Next UX priority: Expenses, connecting receipt capture, property context, repair
links, and clear recorded-versus-planned amounts. Then simplify guided property
and lease entry forms.

## Expenses and receipt entry iteration

`expense-tracking.html` now has full-width desktop layout and labeled mobile
expense cards. The default Recorded view excludes rows flagged `is_planned`;
Planned and combined views are explicit. These flags are existing database data,
not payment-provider settlement verification. All summary tiles reflect the
filtered records. Vendor/property/category/note search and attached/missing receipt
filters make records easier to locate. Vendor, record type, and linked repair
navigation are visible. Edit and Archive actions have text labels. Existing
archive/undo behavior and receipt signed-link handling are retained.

The query includes existing vendor, is_planned, and maintenance_request_id fields.
Numeric amounts are normalized before summation. Loading/error totals are unknown
rather than zero; empty results show zero. A sequence guard avoids stale fetches
replacing newer filters, and filter URLs preserve active company context.

`add-expense.html` uses the same full-width design, clearer review-before-save
copy, accessible receipt URL label and extraction status, and keyboard-focusable
file inputs with visible wrapper focus. Receipt extraction, private storage, repair
linking, mortgage splits, and save behavior are unchanged. Real camera/file picker,
AI extraction, upload delivery, and persistence remain integration/device checks;
simulated browser checks do not establish that those live services work.

Validation: 110 inline scripts parse. Four targeted smoke checks cover expense
tracking and entry on phone/desktop. Additional checks at 320/390/768/1920px cover
layout, recorded versus planned totals, missing receipt filtering, vendor search,
empty totals, entry drawer opening/closing, and keyboard file-input focus. A
simulated load failure checks unknown totals and visible retry guidance.
Screenshots: `/workspace/artifacts/rental-genie-ux/expenses-*.png` and
`expense-entry-*.png`. No live uploads, writes, migrations, or deployment.

Next UX priority: guided property and lease entry, reducing data entry while
preserving validation and existing save behavior. Real-device review and broader
regression/integration verification remain release prerequisites.

## Property and lease entry guidance

`add-property.html` and `lease-form.html` now load shared, dependency-free guidance
from `shared/js/form-guide.js` and `shared/css/form-guide.css`. Both use full-width
desktop layouts, responsive mobile fields, numbered section shortcuts, visible
keyboard focus, and a key-field review summary immediately before save actions.
Property financial details retain their existing optional disclosure and can be
opened through the section navigation. The lease upload input is keyboard-focusable.

This is non-blocking navigation, not a new multi-step save process. Existing
validation, mode handling (create/edit/renew), save buttons, payload construction,
and persistence behavior remain unchanged. Navigation preserves entered values;
it does not save a draft. The page explicitly explains that unsaved changes stay
on the page only. No tenant/property information is copied into local draft storage.

Review summaries use textContent and refresh on input/change and on review access,
including after programmatic hydration. They cover key fields, not all terms or
financial details, and do not certify completeness or legal validity. Existing
advanced sections and all original inputs remain available.

Validation: 110 inline scripts and the shared JS parse; 4 targeted smoke checks
pass without warnings. Additional browser checks at 320/390/768/1920px cover full
width/layout, section navigation, focus, summary values, literal HTML-like text,
programmatic prefilling, and value retention when navigating. Screenshots:
`/workspace/artifacts/rental-genie-ux/add-property-*.png` and `lease-form-*.png`.
No live saves, uploads, migrations, or deployments were performed. Real-device
keyboard/upload behavior and end-to-end create/edit/renew verification remain
release checks.

Next recommended UX work: review the combined redesign as one journey, then
address tenant-facing pages and app-wide navigation consistency. Before release,
run the complete rendering suite and integration tests in an isolated backend;
review known workflow defects and live-service gaps recorded above.

## Tenant home and repair workflow iteration

`tenant-portal.html` and `tenant-repair-requests.html` share
`shared/css/tenant-workspace.css`, with full-width desktop layouts, responsive
cards, clear focus, and mobile request-table labels. Home now shows outstanding
rent from the existing tenant-scoped schedule and brings actions ahead of detailed
lease information. It provides payment-history/instruction, repair, lease,
document and contact links; no collection or new messaging service is implied.

A failed `rg_my_rent_schedule` request now propagates to the existing error flow
instead of becoming an empty schedule. The balance displays Unavailable and refresh
guidance. No rent calculation or authorization scope was replaced. The repair
snapshot excludes archived rows, distinguishes unavailable from no open requests,
and remains capped at five records (not a total-portfolio count).

Tenant repairs have explicit unresolved/resolved views, result counts, clearer
empty search wording, table/card semantics, accessible urgency pressed states,
input labels, and emergency guidance. Submission/photo/reimbursement handlers and
existing tenant scoping remain unchanged. Tenant requests are not vendor dispatch.
The current backend does not expose a tenant-safe vendor scheduling contract here;
this pass does not display landlord internal notes or promise appointment tracking.

Validation with invented data at 320/390/768/1920px: outstanding balance, full-width
layout, home-to-repair navigation, unresolved/resolved filtering, empty search,
and urgency state. Simulated schedule failure confirms unavailable balance and
visible refresh guidance. 110 inline scripts parse and four relevant rendering
smoke checks pass without warnings. Screenshots:
`/workspace/artifacts/rental-genie-ux/tenant-home-*.png` and `tenant-repairs-*.png`.
No live sends, uploads, payments, data writes, schema changes or deployment.

Next: tenant payment history, documents and messages consistency, then a complete
cross-page regression and real-device review before release.

## Tenant payment history, documents, and messages iteration

Updated `tenant-payments.html`, `tenant-documents.html`, and `tenant-contact.html`.
Important: `tenant-messages.html` is the LANDLORD inbox, not the tenant composer;
it was not redesigned in this iteration. Shared resource navigation lives in
`shared/js/tenant-resources.js` and preserves the property URL parameter.
All three pages use the existing tenant workspace stylesheet and full-width
layouts. Resource navigation marks the current page and links Home, Payments,
Documents, Messages (contact), and Repairs.

Payments retain existing desktop rows and mobile cards. Copy distinguishes
recorded history and external payment instructions from collection. A schedule
failure leaves history available but marks rent figures unavailable, instead of
using an empty schedule as evidence that nothing is owed. Payment-history failures
show unavailable history/amounts rather than zero-result search wording. Existing
payment calculations and tenant-scoped loading strategies remain in place.

Documents have a type filter, live result count, explicit search label, and
semantic labeled mobile cards. Existing signed-link handling and tenant access
queries are unchanged. Shared files are not uploaded or made public by these UI
changes. Failed loads show unknown counts and refresh guidance.

The tenant message composer now describes portal delivery accurately. Removed
unverified 1–2 business day response promises and unsupported email/SMS delivery
claims. Message history remains limited to 20 recent records and is labeled that
way. Search and a full-message disclosure expose long messages without truncation;
expanded message text uses textContent. Subject/message labels and status feedback
are accessible. Empty submission still uses existing validation; no message was
sent during testing. Emergency guidance directs urgent issues to appropriate
services/direct contact rather than implying immediate portal monitoring.

Validation: 110 inline scripts and shared navigation parse; six targeted smoke
checks pass without warnings. Additional browser checks across 320/390/768/1920px
cover full width/no overflow, property navigation context, payment search,
document type/search filters, message search/full text safety, and blank-submit
validation. Simulated schedule failure verifies history remains usable with an
unavailable rent status. Screenshot artifacts:
`/workspace/artifacts/rental-genie-ux/tenant-payments-*.png`,
`tenant-documents-*.png`, and `tenant-contact-*.png`.
No live sends, payments, uploads, writes, migrations, or deployment were performed.

Next recommended step: combined cross-page regression and design consistency
review, followed by real-device and isolated-backend integration tests. The
current changes are local and uncommitted; review the full Git diff before
merging, because merging main can deploy.

## Combined regression review completed

See [UX-REGRESSION-REVIEW.md](UX-REGRESSION-REVIEW.md) for scope, evidence,
reproduction commands and release limitations. Complete existing smoke suite:
112 passed, zero failures/warnings. Workspace interaction combinations: 70 passed
across five widths, plus seven service-failure cases. The reusable runner is
`tests/smoke/workspaces.js`; no extra dependency or manifest change is needed.
Tenant Home/Repairs navigation and full-width footer consistency were corrected.
This validates local simulated workflows, not live-service readiness. Next steps
are owner design review, real-device accessibility checks and isolated-backend
integration testing. Changes remain local and uncommitted; nothing was deployed.

## Integration into the repository (Claude Code, 2026-11-08)

The Codex commit `71fdc89` never reached GitHub (no write access from that workspace). The owner
exported it with `git format-patch` and it was applied unchanged, author and message preserved, on top
of `main` at `2af45f0`. Its hash differs (`160b937`) only because the base is newer: since the
redesign branched, `main` gained Snap-it for repair invoices (PR #37: `expenses.maintenance_request_id`,
the repair Invoice button, invoiced chips) and invoiced repair costs in Reports (PR #38). The patch
applied cleanly with three-way merge and those features are intact in the redesigned pages.

Review before applying: no secrets, no new external hosts or scripts, no `target="_blank"`; every new
`innerHTML` is either fixed text or escaped through the page's `safe()` helper.

Verification on the integrated tree (invented data, stubbed Supabase; not live-service evidence):

| Check | Result |
| --- | --- |
| Inline scripts (`check-scripts.js`) plus `form-guide.js`, `tenant-resources.js`, `workspaces.js` | 110 blocks and 3 files parse |
| Page suite (`run.js`), 390 and 1280px | 112 passed, 0 warnings |
| Workspace suite (`workspaces.js`), 320 to 2560px plus failure cases | 77 passed |
| Snap-it end to end on the redesigned repairs and expense pages | Invoice button, invoiced chip, presets, repair hint sent to `rg-snap`, linked insert with `maintenance_request_id`, repair marked Resolved, return to repairs; Complete pop-up "Snap the invoice instead"; no errors or overflow at 390px |
| Reports maintenance costs | Invoiced totals, `est.` fallback and CSV columns unchanged at 1280 and 390px |
| Screenshots inspected | Dashboard, Properties, Maintenance, Tenant home at 390 and 1920px |

Changes made during integration:

- `tests/smoke/fixtures.js`: properties gain `occupancy_status` (the live column the redesigned
  Properties page reads; the fixture only had the older `status`). Both suites still pass.
- `.github/workflows/smoke-tests.yml`: CI now also runs `workspaces.js`, so pull requests and every
  deploy (which calls this workflow first) run the interaction and unavailable-data checks.

### Status of the priorities in the Codex handoff

1. **Push and deploy the redesign.** Done. Merged as PR #39 (`60c84d3`); "Deploy to Bluehost" run 28
   passed (smoke and workspace suites, then upload) at 05:28 UTC on 2026-11-08. Live check at 05:56:
   `rg-version.txt` serves `60c84d3edc8b71ab91473e56d548bf15123e6762`, `shared/js/form-guide.js`
   returns 200, and `dashboard.html` contains `workspace-design`.
2. **Real-device, accessibility, isolated-backend testing.** Automated accessibility done (see
   "Accessibility pass" below). Still open: real iPhone Safari and Android Chrome (owner's devices),
   screen-reader and keyboard-only passes, and isolated-backend integration, which needs a Supabase
   development branch (billed; owner's approval before creating one).
3. **Maintenance completion timestamp.** Fixed in `maintenance-requests.html`: one rule,
   `completionPatch()`, used by both the Complete button and the edit form. Moving to
   Resolved/Completed/Closed stamps `completed_at` once (re-saving a finished repair keeps the
   original time); reopening clears it. Tested in the browser (all four paths) and in a rolled-back
   database transaction as the landlord role. Existing data: 2 of the 6 resolved repairs have no
   `completed_at`; they were left empty rather than backfilled, because no reliable completion date
   exists for them.
4. **Reliable notifications** (workstream A). Needs a design pass with the owner before building:
   new outbox/delivery tables, unique event keys, retry worker, preferences and failure alerts.
5. **Maintenance coordination, rent reconciliation, lease lifecycle** (workstreams B to D). Not
   started. Rent collection needs a payment-provider decision first.

No production migrations, tenant communications, uploads or payments were made for this integration.

### Account data export (workstream E)

`account.html` "Download my data" now covers 23 tables (adds tenants, receipts, applications and
application messages), counts each table first and pages through it 500 rows at a time in a stable
order, so the API's per-request row cap can't silently truncate it. The file has a `summary` per
table (rows, expected, complete, error) and a top-level `complete` flag, and the page names any table
that failed or came back short instead of reporting success. Uploaded files (receipts, leases) are
listed by path, not included. Tested with the smoke stub (now honours `order()`/`range()`, a row cap
via `fixture.maxRows` and per-table failures via `fixture.errors`): 1,234 rows under a 100-row cap,
one failing table, and a normal account.

### Accessibility pass (2026-11-08)

`tests/smoke/a11y.js` runs axe-core (WCAG 2.1 A/AA rules) on 20 landlord, tenant and public pages at
390 and 1280px with the stubbed client, and now runs in CI after the workspace suite. First run: 54
critical/serious violations (219 low-contrast elements, 16 unnamed selects, plus missing labels,
a focusable hidden panel, broken table roles and a broken link). After the fixes: 0 at every impact
level (`node a11y.js --all`). Changes:

- Contrast, sitewide: muted grey `#64748b` → `#556275` (5.6:1 on the page background); footer text on
  navy from 28–50% white to 62% (about 7:1). Per page: link blue `#1d6fd1` on login and listings,
  green save button `#15803d` (add-expense), dashboard row action `#0369a1`, KPI captions on
  Properties, red figures `#dc2626` (reports) and `#c53030` (home page), green `#047857`.
- Names and labels: property selector and management toggle (property-overview), the six utility
  selects (add-property), every filter and application field on listings (`label for`).
- `lease-rent-center.html`: the footer was cut off mid-tag (`<a href="pr`) since the first commit;
  restored the Privacy link, the closing tags and the copyright row, and the year now fills after the
  footer is parsed.
- expense-tracking: the closed side panel is `inert`, so keyboard focus can't land in hidden fields.
- Home page: the "property statement" no longer claims table roles it doesn't have; listings footer
  links are underlined.
- The audit runs with reduced motion, because the home page's question demo animates continuously and
  a scan mid-fade reports half-transparent text.

Automated rules catch roughly a third of accessibility problems; this is not a substitute for a
screen reader, keyboard-only use, 200% text zoom or a real phone.
