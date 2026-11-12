// Rental Genie — connect a landlord's Stripe account (Edge Function, verify_jwt = true).
// Design: docs/design/stripe-online-rent.md (Stripe Connect Express; money goes straight to the landlord).
//
// POST { action: "onboard" | "status" | "dashboard" } with the landlord's JWT.
//   onboard   — creates the company's Express account if it has none (saved in companies.stripe_account_id
//               by the service role; signed-in users can't write it, rg_28), then returns a Stripe-hosted
//               onboarding link { url }. Re-running it continues an unfinished onboarding.
//   status    — reads the account from Stripe, syncs companies.stripe_* and returns the flags.
//   dashboard — returns a one-time link to the landlord's Stripe Express dashboard { url }.
// Only the company owner (companies.owner_user_id) can connect: the payouts go to their bank account.
//
// Secrets: STRIPE_SECRET_KEY. SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are injected.

import { createClient } from "npm:@supabase/supabase-js@2";
import { SITE, stripe, StripeError } from "../_shared/stripe.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

async function syncFlags(db: any, companyId: string, acct: any) {
  const flags = {
    stripe_charges_enabled: !!acct.charges_enabled,
    stripe_payouts_enabled: !!acct.payouts_enabled,
    stripe_details_submitted: !!acct.details_submitted,
  };
  const { data: cur } = await db.from("companies").select("stripe_onboarded_at").eq("id", companyId).maybeSingle();
  const patch: Record<string, unknown> = { ...flags };
  if (flags.stripe_charges_enabled && !cur?.stripe_onboarded_at) patch.stripe_onboarded_at = new Date().toISOString();
  const { error } = await db.from("companies").update(patch).eq("id", companyId);
  if (error) throw new Error("Could not save the Stripe status: " + error.message);
  return flags;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const auth = req.headers.get("Authorization") || "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const userDb = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: u } = await userDb.auth.getUser();
  const user = u?.user;
  if (!user) return json(401, { error: "Please sign in again." });

  let body: any = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const action = String(body.action || "status");

  const db = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: company, error: cErr } = await db.from("companies")
    .select("id, name, owner_user_id, stripe_account_id, stripe_charges_enabled, stripe_payouts_enabled, stripe_details_submitted")
    .eq("owner_user_id", user.id).is("archived_at", null).order("created_at", { ascending: true }).limit(1).maybeSingle();
  if (cErr) return json(500, { error: "Could not load your company." });
  if (!company) return json(403, { error: "Only the account owner can set up online payments." });

  const key = Deno.env.get("STRIPE_SECRET_KEY");
  if (!key) return json(503, { error: "Online payments aren't switched on yet." });

  try {
    if (action === "status") {
      if (!company.stripe_account_id) return json(200, { connected: false });
      const acct = await stripe(key, "GET", "/accounts/" + encodeURIComponent(company.stripe_account_id));
      const flags = await syncFlags(db, company.id, acct);
      return json(200, { connected: true, ...flags });
    }

    if (action === "onboard") {
      let acctId = company.stripe_account_id as string | null;
      if (!acctId) {
        const acct = await stripe(key, "POST", "/accounts", {
          type: "express",
          country: "US",
          email: user.email,
          capabilities: { transfers: { requested: true }, us_bank_account_ach_payments: { requested: true } },
          business_profile: {
            mcc: "6513", // real estate agents and managers: rentals
            product_description: "Residential rent collected through Rental Genie",
            url: SITE,
          },
          metadata: { company_id: company.id },
        }, { idempotencyKey: "rg-acct-" + company.id });
        acctId = acct.id;
        const { error } = await db.from("companies").update({ stripe_account_id: acctId }).eq("id", company.id);
        if (error) return json(500, { error: "Stripe account created but not saved; try again." });
      }
      const link = await stripe(key, "POST", "/account_links", {
        account: acctId,
        type: "account_onboarding",
        refresh_url: SITE + "/account.html?tab=workspace&stripe=refresh",
        return_url: SITE + "/account.html?tab=workspace&stripe=return",
      });
      return json(200, { url: link.url });
    }

    if (action === "dashboard") {
      if (!company.stripe_account_id) return json(400, { error: "Connect your Stripe account first." });
      const link = await stripe(key, "POST", "/accounts/" + encodeURIComponent(company.stripe_account_id) + "/login_links");
      return json(200, { url: link.url });
    }

    return json(400, { error: "Unknown action." });
  } catch (e) {
    const msg = e instanceof StripeError ? e.message : String(e);
    console.error("rg-stripe-connect", action, msg);
    return json(502, { error: "Stripe: " + msg });
  }
});
