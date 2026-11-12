// Rental Genie — Stripe webhook receiver (Edge Function, verify_jwt = false: Stripe has no Supabase JWT;
// the Stripe-Signature header is the authentication). Design: docs/design/stripe-online-rent.md, section 5.
//
// Register two endpoints in the Stripe dashboard, both at
//   https://xqmnaeujwumlcoyhgzuk.supabase.co/functions/v1/rg-stripe-webhook
//   1. "Your account": checkout.session.completed, checkout.session.async_payment_succeeded,
//      checkout.session.async_payment_failed, checkout.session.expired, payment_intent.succeeded,
//      payment_intent.processing, payment_intent.payment_failed, charge.refunded, charge.dispute.created
//      -> signing secret in STRIPE_WEBHOOK_SECRET
//   2. "Connected accounts": account.updated -> signing secret in STRIPE_CONNECT_WEBHOOK_SECRET
// A request is accepted if its signature matches either secret and is under 5 minutes old.
//
// Responses: 200 handled or ignored; 400 bad signature or body; 500 on a database error so Stripe retries
// (every step is idempotent, see handle.ts).

import { createClient } from "npm:@supabase/supabase-js@2";
import { chicagoDate, verifyStripeSignature } from "../_shared/stripe.ts";
import { handleEvent } from "./handle.ts";

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });
  const raw = await req.text();
  const sig = req.headers.get("Stripe-Signature");
  const secrets = [Deno.env.get("STRIPE_WEBHOOK_SECRET"), Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET")].filter(Boolean) as string[];
  if (!secrets.length) {
    console.error("rg-stripe-webhook: no webhook secret configured");
    return json(500, { error: "Not configured" });
  }
  let valid = false;
  for (const s of secrets) if (await verifyStripeSignature(sig, raw, s)) { valid = true; break; }
  if (!valid) return json(400, { error: "Invalid signature" });

  let event: any;
  try { event = JSON.parse(raw); } catch { return json(400, { error: "Invalid JSON" }); }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  try {
    const result = await handleEvent(event, {
      rpc: async (fn, args) => await db.rpc(fn, args),
      idForIntent: async (pi) => {
        const { data } = await db.from("online_payments").select("id").eq("stripe_payment_intent_id", pi).maybeSingle();
        return data?.id || null;
      },
      syncAccount: async (acct) => {
        const { data: cur } = await db.from("companies").select("id, stripe_onboarded_at").eq("stripe_account_id", acct.id).maybeSingle();
        if (!cur) return;
        const patch: Record<string, unknown> = {
          stripe_charges_enabled: !!acct.charges_enabled,
          stripe_payouts_enabled: !!acct.payouts_enabled,
          stripe_details_submitted: !!acct.details_submitted,
        };
        if (acct.charges_enabled && !cur.stripe_onboarded_at) patch.stripe_onboarded_at = new Date().toISOString();
        const { error } = await db.from("companies").update(patch).eq("id", cur.id);
        if (error) throw new Error("account sync: " + error.message);
      },
      paidOn: (created) => chicagoDate(new Date((created || Math.floor(Date.now() / 1000)) * 1000)),
    });
    if (!result.handled) console.log("rg-stripe-webhook", event.type, event.id, result.detail);
    return json(200, { received: true, ...result });
  } catch (e) {
    console.error("rg-stripe-webhook", event?.type, event?.id, String(e));
    return json(500, { error: "Could not record the event" });
  }
});
