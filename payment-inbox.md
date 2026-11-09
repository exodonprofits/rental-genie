# Payment inbox setup

Forwarded Zelle and Venmo alerts become pending payments a landlord confirms with one tap. Nothing
is written to the rent ledger without that confirmation.

```
bank / Venmo alert → Gmail filter → rent-<token>@inbox.rentalgenieai.com → Resend (receiving)
→ webhook email.received → rg-payment-inbox Edge Function → rg_ingest_payment_email → dashboard confirm card
```

Each company's address is `rent-<companies.payment_inbox_token>@inbox.rentalgenieai.com`. The token is
generated automatically for new companies; the dashboard's **Rent inbox setup** panel shows the address.

This replaces the earlier Postmark + n8n design (`json/rental-genie-payment-inbox.n8n.json`, kept for
reference only, never connected). The parser in `supabase/functions/rg-payment-inbox/parse.ts` is a port
of that workflow's "Parse alert" node.

---

## 1. Resend: receive on the subdomain (one time)

1. **Domains → rentalgenieai.com → Receiving**: turn receiving on for the subdomain
   `inbox.rentalgenieai.com` (add it as a domain if Resend asks; sending stays on the root domain).
2. Add the **MX** record Resend shows (host `inbox`, the value Resend gives, e.g.
   `receive.forge.rmta.net`) at the DNS host (Bluehost). Use the subdomain so the root domain's mail is
   untouched. Click **I've added the record** and wait for it to verify.
3. **Webhooks → Add webhook**: URL
   `https://xqmnaeujwumlcoyhgzuk.supabase.co/functions/v1/rg-payment-inbox`, event `email.received`.
   Copy the webhook's **signing secret** (`whsec_…`).

## 2. Supabase: secrets (one time)

Edge Functions → Secrets:

- `RESEND_INBOUND_WEBHOOK_SECRET` — the `whsec_…` signing secret from step 1.3.
- `RESEND_API_KEY` — already set for outgoing email. It must be a **Full access** key: the function
  fetches each received email's body through the API, which a "Sending access" key can't do (the
  function logs a 401/403 from Resend if so).
- `ANTHROPIC_API_KEY` — already set (shared with rg-snap); used only for alerts from banks the rules
  don't know.

The function is deployed with `verify_jwt = false`: Resend has no Supabase login, and the webhook
signature is checked instead (requests without a valid, fresh signature get 401).

## 3. Each landlord: Gmail

1. **Settings → Forwarding and POP/IMAP → Add a forwarding address**, and paste the address from the
   dashboard.
2. Gmail emails a confirmation link to that address. It travels through the pipeline and appears as a
   **Confirm Gmail forwarding** button in the dashboard's Rent inbox setup panel. That button appearing
   means the whole chain works.
3. Create a filter so only payment alerts are forwarded:

   ```
   from:(no.reply.alerts@chase.com OR venmo@venmo.com) subject:("received money" OR "paid you")
   ```

   Choose **Forward it to** the company address.

## 4. Bank alerts

Most banks send no alert for incoming Zelle payments by default, or only above a threshold. Turn on an
alert for every payment received, or nothing arrives.

---

## How parsing works

- **Chase Zelle** ("You received money with Zelle®") and **Venmo** ("Name paid you $X") are read by
  rules: payer, amount, date, memo, transaction number.
- **Gmail's forwarding confirmation** stores its link (only a `mail.google.com` /
  `mail-settings.google.com` link) for the dashboard button.
- **Anything else that mentions a dollar amount**, sent to a real company address, goes to Claude
  (Haiku) for extraction. Those payments are always labelled "Unverified sender". Mail without an
  amount, or to an unknown address, is skipped without an AI call.

## How matching works

Each payment is scored against every lease on:

- **Payer name** — a remembered alias scores highest, then an exact tenant-name match, then a partial
  match. Confirming a payment stores the alias, so the same payer matches automatically next time.
- **Amount** — equal to the rent, equal to the outstanding balance, a whole number of months, or a
  partial payment.
- **Memo** — mentions of rent or the property name.

A payment with no name link and an amount that fits no lease is marked `ignored`, which keeps unrelated
payments (a salon or personal Venmo on the same bank account) out of the queue. Ignored rows keep no
payer name and no email body.

On confirmation the amount is applied to unpaid months oldest-first, so a payment covering arrears
splits across them. Anything left over is a prepayment, applied in rent-sized pieces to the following
due dates.

---

## Safety

- **Webhook signature.** Every request must carry a valid Svix signature from the Resend webhook,
  no older than 5 minutes.
- **Sender checks.** A Chase or Venmo alert is "verified" only when Resend's own mail server reports
  DKIM `pass` for the From domain (`authentication.dkim`, computed on receipt, not taken from headers).
  Anything else is still queued but labelled "Unverified sender".
- **Duplicates.** The original Message-ID is stored per company, so re-forwarding an email (or a
  webhook retry) changes nothing.
- **Never automatic.** Version 1 only queues payments; a landlord confirms every one.
- **Scope.** Only mail matching the Gmail filter is forwarded; the rest of the inbox is never seen.

---

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Nothing arrives | Resend **Emails → Receiving**: did the email arrive? Then **Webhooks**: delivery status and response. |
| Webhook returns 401 | `RESEND_INBOUND_WEBHOOK_SECRET` doesn't match the webhook's signing secret. |
| Webhook returns 500, logs "Fetching received email failed 401/403" | `RESEND_API_KEY` is a sending-only key; replace it with a Full access key. |
| 200 with `skipped` | The reason says why: no inbox token, unknown inbox, no amount, not an incoming payment. |
| 200 with `result.status = ignored` | The payment didn't look like rent (no name link, amount fits no lease). |
| Payment lands on the wrong property | Change the property in the confirm card. The corrected payer alias is remembered. |
| Gmail verification button never appears | Check `companies.payment_inbox_verify_url`. Empty means Gmail's email never reached the function. |
