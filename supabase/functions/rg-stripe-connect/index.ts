// Rental Genie — connect a landlord's Stripe account (Edge Function, verify_jwt = true).
// Design: docs/design/stripe-online-rent.md, section 10.1. Each landlord gets their own full Stripe account with
// Stripe-managed risk (Stripe collects fees and covers losses), created with Accounts v2 (POST /v2/core/accounts):
// Stripe refuses v1 account creation for new platforms at our API version. Onboarding links are v2 account links.
// Rent is a direct charge on the landlord's account (v1 Checkout with Stripe-Account); money goes straight to them.
//
// POST { action: "onboard" | "status" | "dashboard" } with the landlord's JWT.
//   onboard   — creates the company's Stripe account if it has none (saved in companies.stripe_account_id
//               by the service role; signed-in users can't write it, rg_28), then returns a Stripe-hosted
//               onboarding link { url }. Re-running it continues an unfinished onboarding.
//   status    — reads the account from Stripe, syncs companies.stripe_* and returns the flags.
//   dashboard — { url } of the Stripe dashboard (full accounts sign in there with their own Stripe login).
// Only the company owner (companies.owner_user_id) can connect: the payouts go to their bank account.
//
// Secrets: STRIPE_SECRET_KEY. SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are injected.

import { createClient } from "npm:@supabase/supabase-js@2";
import { SITE, accountFlags, landlordAccountRequest, stripe, stripeV2, StripeError } from "../_shared/stripe.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

// The account's state: v2 retrieve (merchant capabilities + requirements); v1 retrieve as a fallback
async function readAccount(key: string, id: string) {
  try {
    return await stripeV2(key, "GET", "/core/accounts/" + encodeURIComponent(id),
      undefined, { query: "include[0]=configuration.merchant&include[1]=requirements" });
  } catch (e) {
    console.warn("rg-stripe-connect: v2 retrieve failed, trying v1", e instanceof StripeError ? e.message : String(e));
    return await stripe(key, "GET", "/accounts/" + encodeURIComponent(id));
  }
}

async function syncFlags(db: any, companyId: string, acct: any) {
  const flags = accountFlags(acct);
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
      const acct = await readAccount(key, company.stripe_account_id);
      const flags = await syncFlags(db, company.id, acct);
      return json(200, { connected: true, ...flags });
    }

    if (action === "onboard") {
      let acctId = company.stripe_account_id as string | null;
      if (!acctId) {
        // Stripe's onboarding asks the landlord for their business details (industry, website) itself
        const acct = await stripeV2(key, "POST", "/core/accounts", landlordAccountRequest(user.email, company.id),
          { idempotencyKey: "rg-acct-v2mc-" + company.id });
        acctId = acct.id;
        const { error } = await db.from("companies").update({ stripe_account_id: acctId }).eq("id", company.id);
        if (error) return json(500, { error: "Stripe account created but not saved; try again." });
      }
      // v2 account link; Stripe decides which configurations need onboarding (no `configurations`, removed in
      // 2026-09-30.endive)
      const link = await stripeV2(key, "POST", "/core/account_links", {
        account: acctId,
        use_case: {
          type: "account_onboarding",
          account_onboarding: {
            refresh_url: SITE + "/account.html?tab=workspace&stripe=refresh",
            return_url: SITE + "/account.html?tab=workspace&stripe=return",
          },
        },
      });
      return json(200, { url: link.url });
    }

    if (action === "dashboard") {
      if (!company.stripe_account_id) return json(400, { error: "Connect your Stripe account first." });
      // Full-dashboard accounts have no one-time login links (that's Express); the landlord signs in to Stripe.
      return json(200, { url: "https://dashboard.stripe.com/" });
    }

    return json(400, { error: "Unknown action." });
  } catch (e) {
    const msg = e instanceof StripeError ? e.message : String(e);
    console.error("rg-stripe-connect", action, msg);
    return json(502, { error: "Stripe couldn't complete that: " + msg.slice(0, 240) });
  }
});
