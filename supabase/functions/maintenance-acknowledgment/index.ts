// Rental Genie — Maintenance Request Acknowledgment (Edge Function)
//
// Called by the trigger_maintenance_acknowledgment() database trigger (pg_net) on every INSERT to
// maintenance_requests, whichever page created the row.
//
// For a request filed by a tenant on a lease with that company it:
//   1. writes an in-app acknowledgment to tenant_messages (sender = 'landlord');
//   2. sends an email via Resend.
// Skipped: requests without a tenant_email, requests logged by a member of the company (the
// landlord), and emails that aren't the tenant on a non-archived lease of that company. Without
// those checks anyone could create a company and use this function to mail any address from the
// Rental Genie sender (pre-launch audit 2.7). The email doesn't quote the request text; the
// in-app message does.
//
// Auth: there is no user JWT (the database calls it), so it is deployed with verify_jwt = false and
// checks the x-webhook-secret header against the Vault secret 'rg_maintenance_webhook_secret',
// read with the service role through public.rg_maintenance_webhook_secret(). The trigger sends
// the same Vault value, so rotating it in Vault is the only step; there is no copy in Edge
// Function secrets.
//
// Secrets: RESEND_API_KEY, FROM_EMAIL (verified Resend sender). SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are injected by the platform.

import { createClient } from "npm:@supabase/supabase-js@2";

function timingSafeEqual(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const providedSecret = req.headers.get("x-webhook-secret") || "";
  const { data: expectedSecret, error: secretErr } = await supabase.rpc("rg_maintenance_webhook_secret");
  if (secretErr || !expectedSecret) {
    console.error("Webhook secret unavailable", secretErr?.message);
    return new Response(JSON.stringify({ error: "Not configured" }), { status: 500 });
  }
  if (!timingSafeEqual(providedSecret, String(expectedSecret))) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400 });
  }

  const record = payload?.record;
  if (!record) {
    return new Response(JSON.stringify({ error: "Missing record in webhook payload" }), { status: 400 });
  }

  const {
    id: requestId,
    property_name,
    tenant_email,
    tenant_id,
    company_id,
    user_id,
    issue_description,
    urgency_level,
  } = record;

  const skip = (reason: string) =>
    new Response(JSON.stringify({ skipped: true, reason }), { status: 200, headers: { "Content-Type": "application/json" } });

  if (!tenant_email) return skip("No tenant_email on record");
  if (!company_id) return skip("No company_id on record");

  // Logged by the landlord (or anyone in the company): no acknowledgment
  if (user_id) {
    const [{ data: member }, { data: owner }] = await Promise.all([
      supabase.from("company_members").select("user_id").eq("company_id", company_id).eq("user_id", user_id).maybeSingle(),
      supabase.from("companies").select("id").eq("id", company_id).eq("owner_user_id", user_id).maybeSingle(),
    ]);
    if (member || owner) return skip("Logged by the landlord");
  }

  // Only the tenant on a non-archived lease of this company (matched by email, or by tenant_id)
  const emailPattern = String(tenant_email).replace(/[\\%_]/g, (c) => "\\" + c);
  const { data: byEmail } = await supabase.from("leases").select("id").eq("company_id", company_id)
    .is("archived_at", null).ilike("tenant_email", emailPattern).limit(1);
  let onLease = !!(byEmail && byEmail.length);
  if (!onLease && tenant_id) {
    const { data: byTenant } = await supabase.from("leases").select("id").eq("company_id", company_id)
      .is("archived_at", null).eq("tenant_id", tenant_id).limit(1);
    onLease = !!(byTenant && byTenant.length);
  }
  if (!onLease) return skip("tenant_email is not on a lease with this company");

  const subject = "We received your maintenance request";
  const urgent = ["high", "emergency"].includes(String(urgency_level || "").toLowerCase());
  const intro =
    `Hi,\n\nWe've received your maintenance request` + (property_name ? ` for ${property_name}` : "");
  const outro =
    `\n\nWe're on it and will follow up shortly with next steps.` +
    (urgent ? " Given the urgency, we're prioritizing this." : "") +
    `\n\n— Your landlord`;
  // In-app message quotes the request; the email doesn't (see header)
  const bodyText = intro + (issue_description ? `:\n\n"${issue_description}"` : ".") + outro;
  const emailText = intro + "." + outro;

  const results: { inAppOk: boolean; emailOk: boolean; errors: string[] } = {
    inAppOk: false,
    emailOk: false,
    errors: [],
  };

  const { error: msgError } = await supabase.from("tenant_messages").insert([
    {
      company_id: company_id ?? null,
      property_name: property_name ?? null,
      tenant_email,
      tenant_id: tenant_id ?? null,
      subject,
      message: bodyText,
      sender: "landlord",
    },
  ]);
  if (msgError) results.errors.push("tenant_messages insert: " + msgError.message);
  else results.inAppOk = true;

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const fromEmail = Deno.env.get("FROM_EMAIL") || "Rental Genie <onboarding@resend.dev>";
  if (!resendKey) {
    results.errors.push("RESEND_API_KEY not set — email skipped");
  } else {
    try {
      const emailRes = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: fromEmail, to: [tenant_email], subject, text: emailText }),
      });
      if (!emailRes.ok) results.errors.push("Resend error: " + (await emailRes.text()));
      else results.emailOk = true;
    } catch (e) {
      results.errors.push("Resend fetch failed: " + String(e));
    }
  }

  return new Response(JSON.stringify({ requestId, ...results }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
