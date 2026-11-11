# Online rent payments with Stripe: design

Status: **draft for review, nothing built.** Decisions marked **[decide]** need Jimmy's call before code.
Stripe's prices in section 8 are **from memory, not checked against stripe.com** (the design session couldn't
reach Stripe's site). Confirm them on stripe.com/pricing and stripe.com/connect/pricing before deciding 3.4.

## 1. What we're building

A tenant opens **Payments** in the tenant portal, sees what they owe (from `rg_my_rent_schedule`, as today),
taps **Pay online**, pays from their bank account, and the payment lands in the landlord's ledger by itself:
split oldest month first, exactly as a confirmed payment-inbox payment is. The money goes to the landlord's
own bank account through Stripe; Rental Genie never holds it.

Out of scope for version 1: autopay, cards, partial-month proration, security deposits, late fees charged
online, refunds started from Rental Genie (the landlord refunds in the Stripe dashboard; we record it).

## 2. The money flow

```
Tenant (Payments page) ─► rg-stripe-checkout (Edge Function, tenant's JWT)
                            │  amount = balance from rg_my_rent_schedule, never the page's number
                            ▼
                  Stripe Checkout (hosted page, bank account via Financial Connections)
                            │
                            ▼
   PaymentIntent: processing (~4 business days for ACH) ──► succeeded / payment_failed
                            │
         Stripe webhook ─► rg-stripe-webhook (Edge Function, signature checked, verify_jwt false)
                            │
                            ▼
   online_payments row (pending → succeeded) ─► rg_apply_payment() ─► rent_log rows (split by due date)
                            │
                            ▼
   notifications outbox: tenant receipt + landlord "rent received" (existing rg_17 scheme)

   Payout: Stripe → landlord's bank on Stripe's schedule (Rental Genie never holds funds)
```

## 3. Decisions

### 3.1 Connect account type: **Express** (recommended)
| | Standard | **Express** | Custom |
|---|---|---|---|
| Onboarding / identity checks | Stripe | Stripe-hosted | We build it |
| Landlord dashboard | Full Stripe dashboard | Light Express dashboard | We build it |
| Who sets our fees | Landlord pays Stripe directly | We do | We do |
| Our liability for losses | None | Ours (negative balances) | Ours |
| Work for us | Least | Low | High |

Express: Stripe does the identity checks and the bank-account onboarding on its own pages, the landlord gets
a small dashboard for payouts and refunds, and we control the fee the tenant or landlord sees. The cost is a
per-active-account monthly fee and that we're on the hook if a landlord's balance goes negative (an ACH
return after payout). Standard is the alternative if we never want that exposure: fewer moving parts, but the
landlord deals with Stripe's full dashboard and we can't set fees.

### 3.2 Charge type: **destination charges with `on_behalf_of`**
The charge is created on our platform account, `transfer_data.destination` = the landlord's account,
`on_behalf_of` = the landlord's account so the **landlord is the merchant of record** (their name on the
tenant's bank statement, their country/settlement rules). Our fee, if any, is `application_fee_amount`.
Stripe's processing fee is charged to the platform, so the application fee has to cover it if we don't want
to absorb it (see 3.4).

### 3.3 Payment method: **ACH Direct Debit only in version 1**
- Bank payments cost a fraction of cards for a $1,500 rent and are what tenants already do with Zelle.
- Cards later, if asked for. Card surcharges are regulated state by state, and debit cards can't be
  surcharged at all, so cards would mean the landlord absorbing ~3% or us building a compliant fee.
- Bank account linked instantly through Financial Connections (online bank login), with microdeposits as the
  fallback.

### 3.4 Who pays the fees **[decide]**
Options for an ACH payment (Stripe's fee per payment is capped, see section 8):
1. **Landlord absorbs it** (taken from the payout). Simplest; tenant pays exactly the rent.
2. **Rental Genie absorbs it** as part of a paid plan. Ties into plan limits (option D).
3. **Tenant pays a flat convenience fee** shown before paying. Some states restrict fees on rent; needs a
   check per state before turning on. Not recommended for version 1.

Recommendation: **1** for the pilot, revisit with D.

### 3.5 Hosted Checkout, not an embedded form
Stripe Checkout (a Stripe-hosted page we redirect to and back from):
- No card or bank data touches our pages (smallest PCI scope), no Stripe.js to load and keep current.
- Works from the iOS home-screen app as an external page; returns to `tenant-payments.html?paid=<session>`.
- Version 2 can move to the embedded Payment Element if the redirect feels clunky.

### 3.6 What amount can be paid
Computed in the Edge Function from `rg_my_rent_schedule` as of today, never taken from the page:
- default: the current balance (everything due and unpaid);
- the tenant may pay **less** (partial) or **up to one month ahead** (balance + one month's rent);
- minimum $1; nothing if no lease is active for that company and property.

## 4. Database (one migration, `rg_28`)

- `companies`: `stripe_account_id text unique`, `stripe_charges_enabled boolean default false`,
  `stripe_payouts_enabled boolean default false`, `stripe_onboarded_at timestamptz`.
  Kept in sync by the `account.updated` webhook; the page never writes them.
- `online_payments`: one row per Checkout Session / PaymentIntent.
  `id, company_id, property_id, lease_id, tenant_id, tenant_email, amount, fee_amount, status
  (created | processing | succeeded | failed | refunded | disputed), stripe_checkout_session_id unique,
  stripe_payment_intent_id unique, failure_reason, rent_log_ids uuid[], created_at, updated_at`.
  RLS: landlord company access; tenant reads their own (`rg_tenant_can_file`-style lease check). Writes:
  service role only (the Edge Functions).
- `rent_log.source = 'stripe'` and a new `rent_log.online_payment_id` (FK) for traceability, like
  `incoming_payment_id`.
- **`rg_apply_payment(company, property, lease, amount, date, method, note, source, link_id)`**: the
  oldest-month-first split and prepayment logic, moved out of `rg_confirm_incoming_payment` into one shared
  function so the payment inbox and Stripe can't disagree. `rg_confirm_incoming_payment` then calls it.
  Service role and the confirm function only.
- Notification kinds: `payment_received` (landlord), `payment_receipt` (tenant), `payment_failed` (both).
  Owner switch `onlinePayments`, missing = on.

## 5. Edge Functions

| Function | Auth | Does |
|---|---|---|
| `rg-stripe-connect` | landlord JWT | Creates the Express account if missing, returns an Account Link (onboarding or update) |
| `rg-stripe-checkout` | tenant JWT | Validates lease + amount, creates the Checkout Session, inserts `online_payments` (created) |
| `rg-stripe-webhook` | `verify_jwt false`, Stripe signature | Handles the events below; idempotent on the event and PaymentIntent ids |

Webhook events:
- `checkout.session.completed` → `processing` (ACH not yet settled; shows as **Pending** to both sides).
- `payment_intent.succeeded` → `succeeded`, `rg_apply_payment`, notifications. This is the only point
  where rent is recorded.
- `payment_intent.payment_failed` → `failed` with the reason; notify both.
- `charge.dispute.created` / `charge.refunded` (ACH return or landlord refund after success) → archive the
  linked `rent_log` rows (`archive_rent_log`, kept for history), status `disputed` / `refunded`, notify the
  landlord. The balance reappears on its own because the schedule reads non-archived rows.
- `account.updated` → sync `companies.stripe_*` flags.

Secrets: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` (and the Connect webhook secret) in Supabase Edge
Function secrets. Test-mode keys until the pilot ends.

## 6. Pages

- **account.html → "Get paid online"**: Connect / continue onboarding / status (charges and payouts
  enabled), link to the Express dashboard.
- **lease-form.html**: a "Accept online payments" switch per lease (`pay_accepts_online`), on by default once
  the company is onboarded. Shown to the tenant only when on and `stripe_charges_enabled`.
- **tenant-payments.html**: **Pay online** button next to the balance → amount choice (balance / other) →
  Checkout. Pending payments listed with "Processing (bank payments take about 4 business days)".
  Failed ones show the reason and a retry button.
- **tenant-portal.html**: the "Pay rent" quick action goes to the payments page.
- **Landlord ledger (lease-rent-center, reports)**: rows with `source = 'stripe'` get an "Online" badge;
  pending online payments listed separately, never counted as paid.
- **dashboard.html**: "Online payments: N pending" card while any are processing.
- Marketing and terms copy updated only when it ships (the pre-launch audit flagged the old claims).

## 7. What can go wrong, and what happens

| Event | Result |
|---|---|
| Tenant closes Checkout | Session expires; `online_payments` stays `created`, swept to `expired` after 24 h |
| Insufficient funds (failure before success) | `failed`, nothing recorded, both notified, tenant can retry |
| ACH return / dispute after success | linked rent rows archived, balance comes back, landlord notified; Stripe pulls the money back from the landlord's balance. With Express a negative balance is ours to cover (section 3.1) |
| Webhook delivered twice / out of order | Idempotent on PaymentIntent id; rent recorded once, only on `succeeded` |
| Lease ended between Checkout and success | Still recorded against that lease's property (money was owed or prepaid); landlord can archive and refund |
| Landlord's account restricted by Stripe | `stripe_charges_enabled` false → Pay online hidden; existing pending payments still settle |
| Tenant pays the same balance twice | Second Checkout blocked while one is `processing` for that lease |

## 8. Prices *(from memory, unverified: check stripe.com/pricing and /connect/pricing)*

| Item | Stripe's usual US price | On a $1,500 rent |
|---|---|---|
| ACH Direct Debit payment | 0.8%, capped at $5 | $5.00 |
| ACH failed payment / return | about $4 | — |
| ACH dispute | about $15 | — |
| Card payment (online, domestic) | 2.9% + 30¢ | $43.80 |
| Connect, platform handles pricing: active account | about $2 per landlord per month with payouts | $2.00 |
| Connect, platform handles pricing: payout | about 0.25% + 25¢ per payout | $4.00 |

So one ACH rent payment on Express costs roughly **$11** all in ($5 + $2 + $4) if the landlord gets one
payout that month, versus **$50** by card. With Standard accounts (Stripe handles pricing) the account and
payout fees don't apply to us, and the landlord pays Stripe's processing fee directly.

Timing (also unverified): ACH Direct Debit payments sit in `processing` for about 4 business days before
`succeeded`; consumers can return an unauthorized debit for up to about 60 days, which arrives as a dispute.

## 9. Rollout

1. **Test mode** end to end with Stripe's test bank accounts: onboarding, pay, success, failure, return.
   Rolled-back database tests for `rg_apply_payment` matching the inbox's current results.
2. **Pilot**: live keys, Jimmy's own company only (feature flag on the company), one real rent payment.
3. **Open to landlords** once the pilot has a full cycle (payment → payout → statement) with no surprises.

Estimated work: migration + 3 Edge Functions + 4 page changes ≈ 3–4 sessions, plus the pilot month.

## 10. Questions for Jimmy **[decide]**

1. Fees: landlord absorbs the ACH fee (recommended), Rental Genie absorbs, or tenant fee?
2. Express (we carry negative-balance risk, simpler for landlords) or Standard (no risk, more Stripe for
   landlords)?
3. Pilot on your own properties first, before any other landlord? (Recommended.)
4. Do you already have a Stripe account for Exodon Profits LLC to be the platform, or should it be a new
   one for Rental Genie / GenieSphere?
5. Cards: leave out of version 1 (recommended)?
