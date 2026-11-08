// Rental Genie — Maintenance Request Acknowledgment: email sender (Edge Function)
//
// Since rg_17 this function only delivers emails that are already queued in public.notifications.
// The decision and the recipient are made in the database, inside the insert that files the repair
// (rg_maint_ack_prepare, called by trigger_maintenance_acknowledgment):
//   - only a tenant on a current lease with that company (and property) is acknowledged;
//   - the recipient comes from the tenant and lease records, never from the request's tenant_email;
//   - the in-app message is written there, in the same transaction;
//   - each event is recorded once under a unique key ('maint_ack:<request id>'), so a repeated
//     trigger or retry can't send twice.
//
// Called with { notification_id } by the trigger right after the insert, and by the pg_cron retry
// sweep (rg_notification_sweep) for anything still queued, due for retry, or stuck. Each call:
//   1. claims the attempt with rg_notification_begin (returns nothing if it isn't due, or someone
//      else is already sending it);
//   2. sends through Resend with the event key as Idempotency-Key, so even an attempt whose result
//      was lost can't produce a second email;
//   3. records the outcome with rg_notification_finish: sent, retry (network, 429, 5xx: backoff
//      2 min, 10 min, 1 h, 6 h, at most 5 attempts) or failed (other 4xx, or email not configured).
//      Failed rows show on the landlord's dashboard.
// The HTTP status is honest: 200 sent or nothing to do, 503 retry scheduled, 502 failed.
//
// A legacy payload ({ record } from the pre-rg_17 trigger) is mapped to the queued email for that
// request by its event key; it never sends anything the database didn't queue.
//
// Auth: no user JWT (the database calls it), so verify_jwt = false and the x-webhook-secret header
// is checked against the Vault secret 'rg_maintenance_webhook_secret', read with the service role
// through public.rg_maintenance_webhook_secret(). Rotate it with vault.update_secret only.
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

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

type Outcome = { ok: boolean; permanent: boolean; error?: string; providerId?: string };

// One delivery attempt. Transient: network errors, 408, 409 (concurrent idempotent request), 429, 5xx.
async function sendEmail(n: { event_key: string; recipient: string; subject: string; body: string }): Promise<Outcome> {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("FROM_EMAIL");
  if (!key || !from) {
    return { ok: false, permanent: true, error: "Email isn't configured (RESEND_API_KEY or FROM_EMAIL missing)" };
  }
  let res: Response;
  try {
    res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "Idempotency-Key": n.event_key },
      body: JSON.stringify({ from, to: [n.recipient], subject: n.subject, text: n.body }),
      signal: AbortSignal.timeout(15000),
    });
  } catch (e) {
    return { ok: false, permanent: false, error: "Network error: " + String(e) };
  }
  const text = await res.text();
  if (res.ok) {
    let id: string | undefined;
    try { id = JSON.parse(text)?.id; } catch { /* keep undefined */ }
    return { ok: true, permanent: false, providerId: id };
  }
  const transient = [408, 409, 429].includes(res.status) || res.status >= 500;
  return { ok: false, permanent: !transient, error: `Resend ${res.status}: ${text.slice(0, 500)}` };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "Method not allowed" });

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  const providedSecret = req.headers.get("x-webhook-secret") || "";
  const { data: expectedSecret, error: secretErr } = await supabase.rpc("rg_maintenance_webhook_secret");
  if (secretErr || !expectedSecret) {
    console.error("Webhook secret unavailable", secretErr?.message);
    return json(500, { error: "Not configured" });
  }
  if (!timingSafeEqual(providedSecret, String(expectedSecret))) return json(401, { error: "Unauthorized" });

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return json(400, { error: "Invalid JSON body" });
  }

  let notificationId = Number(payload?.notification_id);
  if (!Number.isSafeInteger(notificationId) || notificationId <= 0) {
    const requestId = Number(payload?.record?.id);
    if (!Number.isSafeInteger(requestId) || requestId <= 0) return json(400, { error: "Missing notification_id" });
    const { data: row } = await supabase.from("notifications").select("id")
      .eq("event_key", "maint_ack:" + requestId).eq("channel", "email").maybeSingle();
    if (!row) return json(200, { skipped: true, reason: "Nothing queued for this request" });
    notificationId = row.id;
  }

  // Claim this attempt; nothing comes back if it isn't due or is already being sent
  const { data: claimed, error: claimErr } = await supabase.rpc("rg_notification_begin", { p_id: notificationId });
  if (claimErr) {
    console.error("rg_notification_begin failed", claimErr.message);
    return json(500, { error: "Could not claim notification" });
  }
  if (!claimed) return json(200, { notificationId, skipped: true, reason: "Not due, already sent, or in progress" });

  const outcome = await sendEmail(claimed);

  const { data: status, error: finishErr } = await supabase.rpc("rg_notification_finish", {
    p_id: notificationId,
    p_ok: outcome.ok,
    p_error: outcome.error ?? null,
    p_provider_id: outcome.providerId ?? null,
    p_permanent: outcome.permanent,
  });
  if (finishErr) {
    // The row stays 'sending'; the sweep re-claims it after 15 minutes and the Idempotency-Key
    // stops Resend from sending a second copy.
    console.error("rg_notification_finish failed", finishErr.message);
    return json(500, { notificationId, sent: outcome.ok, error: "Could not record the outcome" });
  }

  if (outcome.ok) return json(200, { notificationId, status });
  console.error("Acknowledgment email not sent", notificationId, status, outcome.error);
  return json(status === "retry" ? 503 : 502, { notificationId, status, error: outcome.error });
});
