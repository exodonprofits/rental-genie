// Stripe webhook event handling with a fake database (invented data). Run: node --experimental-strip-types tests/stripe/webhook.test.ts
import { handleEvent } from "../../supabase/functions/rg-stripe-webhook/handle.ts";
let fails = 0;
const ok = (n: string, c: boolean, i?: unknown) => { console.log((c ? "PASS " : "FAIL ") + n + (c ? "" : " " + JSON.stringify(i))); if (!c) fails++; };
const OP = "11111111-2222-4333-8444-555555555555";
function fakeDeps(opts: { rpcError?: string } = {}) {
  const calls: any[] = [], synced: any[] = [];
  return { calls, synced, deps: {
    rpc: async (fn: string, args: any) => { calls.push([fn, args]); return opts.rpcError ? { error: { message: opts.rpcError } } : { data: "ok", error: null }; },
    idForIntent: async (pi: string) => (pi === "pi_known" ? OP : null),
    syncAccount: async (a: any) => { synced.push(a.id); },
    paidOn: (_c: number) => "2026-11-12",
  } };
}

let f = fakeDeps(); let r = await handleEvent({ type: "checkout.session.completed", created: 1, data: { object: { id: "cs_1", payment_status: "unpaid", payment_intent: "pi_known", metadata: { online_payment_id: OP } } } }, f.deps);
ok("checkout completed (ACH) -> processing, no rent", r.action === "processing" && f.calls[0][0] === "rg_online_payment_processing" && f.calls[0][1].p_intent === "pi_known" && f.calls[0][1].p_session === "cs_1", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "checkout.session.completed", created: 1, data: { object: { id: "cs_1", payment_status: "paid", client_reference_id: OP } } }, f.deps);
ok("checkout completed already paid -> succeeded", r.action === "succeeded" && f.calls[0][0] === "rg_online_payment_succeeded" && f.calls[0][1].p_paid_on === "2026-11-12", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "payment_intent.succeeded", created: 1, data: { object: { id: "pi_known", metadata: { online_payment_id: OP } } } }, f.deps);
ok("PI succeeded -> record rent", r.action === "succeeded" && f.calls[0][1].p_id === OP && f.calls[0][1].p_intent === "pi_known", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "payment_intent.succeeded", created: 1, data: { object: { id: "pi_known", metadata: {} } } }, f.deps);
ok("PI succeeded without metadata -> found by intent", r.action === "succeeded" && f.calls[0][1].p_id === OP, f.calls);

f = fakeDeps(); r = await handleEvent({ type: "checkout.session.async_payment_succeeded", created: 1, data: { object: { id: "cs_1", payment_intent: { id: "pi_x" }, metadata: { online_payment_id: OP } } } }, f.deps);
ok("async succeeded -> record rent (intent object form)", r.action === "succeeded" && f.calls[0][1].p_intent === "pi_x", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "payment_intent.payment_failed", created: 1, data: { object: { id: "pi_known", last_payment_error: { message: "Insufficient funds" }, metadata: { online_payment_id: OP } } } }, f.deps);
ok("PI failed -> failed with reason", r.action === "failed" && f.calls[0][0] === "rg_online_payment_failed" && f.calls[0][1].p_reason === "Insufficient funds", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "checkout.session.expired", created: 1, data: { object: { id: "cs_1", metadata: { online_payment_id: OP } } } }, f.deps);
ok("session expired -> expired", r.action === "expired" && f.calls[0][0] === "rg_online_payment_expired", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "charge.refunded", created: 1, data: { object: { payment_intent: "pi_known", amount: 150000, amount_refunded: 150000 } } }, f.deps);
ok("full refund -> reversed refunded", r.action === "refunded" && f.calls[0][1].p_status === "refunded" && f.calls[0][1].p_reason === "refunded", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "charge.refunded", created: 1, data: { object: { payment_intent: "pi_known", amount: 150000, amount_refunded: 50000 } } }, f.deps);
ok("partial refund -> reversed with note", /partly refunded \(\$500\.00\)/.test(f.calls[0][1].p_reason), f.calls);

f = fakeDeps(); r = await handleEvent({ type: "charge.dispute.created", created: 1, data: { object: { payment_intent: "pi_known", reason: "unrecognized" } } }, f.deps);
ok("dispute -> reversed disputed", r.action === "disputed" && f.calls[0][1].p_status === "disputed" && f.calls[0][1].p_reason === "unrecognized", f.calls);

f = fakeDeps(); r = await handleEvent({ type: "charge.dispute.created", created: 1, data: { object: { payment_intent: "pi_unknown" } } }, f.deps);
ok("dispute for unknown payment ignored", !r.handled && f.calls.length === 0, r);

f = fakeDeps(); r = await handleEvent({ type: "account.updated", created: 1, data: { object: { id: "acct_1", charges_enabled: true } } }, f.deps);
ok("account.updated -> sync", r.action === "account" && f.synced[0] === "acct_1", f.synced);

f = fakeDeps(); r = await handleEvent({ type: "customer.created", created: 1, data: { object: {} } }, f.deps);
ok("other events ignored", !r.handled && f.calls.length === 0, r);

f = fakeDeps(); r = await handleEvent({ type: "payment_intent.succeeded", created: 1, data: { object: { id: "pi_x", metadata: { online_payment_id: "not-a-uuid'; drop" } } } }, f.deps);
ok("bad metadata id not trusted", !r.handled && f.calls.length === 0, r);

f = fakeDeps({ rpcError: "deadlock" }); let threw = false;
try { await handleEvent({ type: "payment_intent.succeeded", created: 1, data: { object: { id: "pi_known", metadata: { online_payment_id: OP } } } }, f.deps); } catch { threw = true; }
ok("database error throws (-> 500, Stripe retries)", threw);

console.log(fails ? fails + " FAILED" : "all passed");
process.exit(fails ? 1 : 0);
