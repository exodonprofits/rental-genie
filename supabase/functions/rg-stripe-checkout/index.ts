// Rental Genie — start an online rent payment (Edge Function, verify_jwt = true).
// Design: docs/design/stripe-online-rent.md, sections 3.2–3.6.
//
// POST { lease_id, amount } with the tenant's JWT -> { url } of a Stripe-hosted Checkout page (bank
// account via Financial Connections). Rent is NOT recorded here: rg-stripe-webhook records it when the
// bank payment succeeds (about 4 business days for ACH).
//
// Checks, all server-side (the page's numbers are never trusted):
//   - the lease is the signed-in tenant's and can be paid online now (rg_my_online_pay_options, tenant JWT);
//   - the amount is between $1 and what's owed plus one month's rent (rg_my_rent_schedule as of today);
//   - no other payment for this lease is still processing (stops paying the same balance twice).
// Then an online_payments row (service role) and a Checkout Session: a destination charge to the landlord's
// connected account with on_behalf_of (the landlord is the merchant of record) and the ACH fee as the
// application fee (the landlord absorbs it, design decision 1).
//
// Secrets: STRIPE_SECRET_KEY. SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are injected.

import { createClient } from "npm:@supabase/supabase-js@2";
import { SITE, achFeeCents, checkAmount, chicagoDate, payBounds, stripe, StripeError, toCents } from "../_shared/stripe.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const userDb = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") || "" } },
  });
  const { data: u } = await userDb.auth.getUser();
  const user = u?.user;
  if (!user) return json(401, { error: "Please sign in again." });

  let body: any = {};
  try { body = await req.json(); } catch { /* handled below */ }
  const leaseId = String(body.lease_id || "");
  if (!/^[0-9a-f-]{36}$/i.test(leaseId)) return json(400, { error: "Missing lease." });
  const amountCents = toCents(body.amount);

  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) return json(503, { error: "Online payments aren't switched on yet." });

  // 1. The tenant's own lease, payable online (checked with the tenant's JWT)
  const { data: opts, error: oErr } = await userDb.rpc("rg_my_online_pay_options");
  if (oErr) return json(500, { error: "Could not check your lease." });
  const opt = (opts || []).find((o: any) => o.lease_id === leaseId);
  if (!opt) return json(403, { error: "That lease isn't on your account." });
  if (!opt.can_pay_online) return json(403, { error: "Your landlord doesn't take online payments for this lease." });

  // 2. Amount within what's owed (+ one month ahead), from the database's rent schedule
  const today = chicagoDate();
  const { data: sched, error: sErr } = await userDb.rpc("rg_my_rent_schedule", { p_as_of: today });
  if (sErr) return json(500, { error: "Could not load your rent balance." });
  const bounds = payBounds(sched || [], leaseId);
  const problem = checkAmount(amountCents, bounds);
  if (problem) return json(400, { error: problem });

  const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // 3. One processing payment per lease at a time
  const { data: open } = await db.from("online_payments").select("id, status, created_at")
    .eq("lease_id", leaseId).in("status", ["processing"]).limit(1);
  if (open && open.length) {
    return json(409, { error: "A payment for this lease is still processing. Bank payments take about 4 business days." });
  }

  const { data: company } = await db.from("companies").select("id, stripe_account_id, stripe_charges_enabled")
    .eq("id", opt.company_id).maybeSingle();
  if (!company?.stripe_account_id || !company.stripe_charges_enabled) {
    return json(403, { error: "Your landlord's online payments aren't ready yet." });
  }
  const { data: lease } = await db.from("leases").select("id, tenant_id, tenant_email").eq("id", leaseId).maybeSingle();

  const fee = achFeeCents(amountCents!);
  const { data: row, error: iErr } = await db.from("online_payments").insert({
    company_id: opt.company_id,
    property_id: opt.property_id,
    lease_id: leaseId,
    tenant_id: lease?.tenant_id || null,
    tenant_email: (lease?.tenant_email || user.email || "").trim() || null,
    amount: amountCents! / 100,
    fee_amount: fee / 100,
    stripe_account_id: company.stripe_account_id,
    status: "created",
  }).select("id").single();
  if (iErr || !row) return json(500, { error: "Could not start the payment." });

  try {
    const session = await stripe(key, "POST", "/checkout/sessions", {
      mode: "payment",
      payment_method_types: ["us_bank_account"],
      payment_method_options: { us_bank_account: { verification_method: "automatic" } },
      customer_email: user.email,
      client_reference_id: row.id,
      line_items: [{
        quantity: 1,
        price_data: {
          currency: "usd",
          unit_amount: amountCents,
          product_data: { name: "Rent — " + (opt.property_name || "your rental") },
        },
      }],
      payment_intent_data: {
        on_behalf_of: company.stripe_account_id,
        transfer_data: { destination: company.stripe_account_id },
        application_fee_amount: fee,
        description: "Rent — " + (opt.property_name || "rental"),
        metadata: { online_payment_id: row.id, lease_id: leaseId },
      },
      metadata: { online_payment_id: row.id, lease_id: leaseId },
      success_url: SITE + "/tenant-payments.html?paid={CHECKOUT_SESSION_ID}",
      cancel_url: SITE + "/tenant-payments.html?canceled=1",
    }, { idempotencyKey: "rg-cs-" + row.id });

    await db.from("online_payments").update({ stripe_checkout_session_id: session.id, updated_at: new Date().toISOString() }).eq("id", row.id);
    return json(200, { url: session.url, online_payment_id: row.id });
  } catch (e) {
    const msg = e instanceof StripeError ? e.message : String(e);
    console.error("rg-stripe-checkout", row.id, msg);
    await db.from("online_payments").update({ status: "failed", failure_reason: "Could not start: " + msg.slice(0, 300), updated_at: new Date().toISOString() }).eq("id", row.id);
    return json(502, { error: "Couldn't open the payment page. Please try again in a few minutes." });
  }
});
