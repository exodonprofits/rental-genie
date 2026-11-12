// Stripe event -> database step. Kept separate from index.ts so tests/stripe/webhook.test.ts can drive it
// with a fake database. Every step is an rg_29 function that locks the online_payments row, so a repeated
// or out-of-order event changes nothing the second time; rent is recorded only on success.

export type Deps = {
  rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data?: unknown; error?: { message: string } | null }>;
  // online_payments.id for a PaymentIntent (charge events don't carry our metadata)
  idForIntent: (intentId: string) => Promise<string | null>;
  syncAccount: (acct: any) => Promise<void>;
  paidOn: (eventCreatedSeconds: number) => string; // YYYY-MM-DD, America/Chicago
};

export type Result = { handled: boolean; action?: string; detail?: unknown };

const idFrom = (o: any): string | null => {
  const v = o?.metadata?.online_payment_id || o?.client_reference_id || null;
  return typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v) ? v : null;
};
const intentOf = (o: any): string | null => (typeof o?.payment_intent === "string" ? o.payment_intent : o?.payment_intent?.id) || null;

async function call(deps: Deps, fn: string, args: Record<string, unknown>) {
  const { data, error } = await deps.rpc(fn, args);
  if (error) throw new Error(fn + ": " + error.message); // -> 500, Stripe retries
  return data;
}

export async function handleEvent(event: any, deps: Deps): Promise<Result> {
  const o = event?.data?.object || {};
  switch (event?.type) {
    case "checkout.session.completed": {
      const id = idFrom(o); if (!id) return { handled: false, detail: "no online_payment_id" };
      // Card-like instant success would be payment_status 'paid'; ACH is 'unpaid' until it clears.
      if (o.payment_status === "paid") {
        return { handled: true, action: "succeeded", detail: await call(deps, "rg_online_payment_succeeded", { p_id: id, p_intent: intentOf(o), p_paid_on: deps.paidOn(event.created) }) };
      }
      return { handled: true, action: "processing", detail: await call(deps, "rg_online_payment_processing", { p_id: id, p_intent: intentOf(o), p_session: o.id || null }) };
    }
    case "checkout.session.async_payment_succeeded": {
      const id = idFrom(o); if (!id) return { handled: false, detail: "no online_payment_id" };
      return { handled: true, action: "succeeded", detail: await call(deps, "rg_online_payment_succeeded", { p_id: id, p_intent: intentOf(o), p_paid_on: deps.paidOn(event.created) }) };
    }
    case "payment_intent.succeeded": {
      const id = idFrom(o) || (o.id ? await deps.idForIntent(o.id) : null); if (!id) return { handled: false, detail: "unknown payment" };
      return { handled: true, action: "succeeded", detail: await call(deps, "rg_online_payment_succeeded", { p_id: id, p_intent: o.id || null, p_paid_on: deps.paidOn(event.created) }) };
    }
    case "payment_intent.processing": {
      const id = idFrom(o) || (o.id ? await deps.idForIntent(o.id) : null); if (!id) return { handled: false, detail: "unknown payment" };
      return { handled: true, action: "processing", detail: await call(deps, "rg_online_payment_processing", { p_id: id, p_intent: o.id || null, p_session: null }) };
    }
    case "checkout.session.async_payment_failed":
    case "payment_intent.payment_failed": {
      const id = idFrom(o) || (event.type.startsWith("payment_intent") && o.id ? await deps.idForIntent(o.id) : null);
      if (!id) return { handled: false, detail: "unknown payment" };
      const reason = o.last_payment_error?.message || o.last_payment_error?.decline_code || null;
      return { handled: true, action: "failed", detail: await call(deps, "rg_online_payment_failed", { p_id: id, p_reason: reason }) };
    }
    case "checkout.session.expired": {
      const id = idFrom(o); if (!id) return { handled: false, detail: "no online_payment_id" };
      return { handled: true, action: "expired", detail: await call(deps, "rg_online_payment_expired", { p_id: id }) };
    }
    case "charge.refunded": {
      const pi = intentOf(o); const id = pi ? await deps.idForIntent(pi) : null; if (!id) return { handled: false, detail: "unknown payment" };
      const partial = Number(o.amount_refunded || 0) < Number(o.amount || 0);
      const reason = partial ? "partly refunded ($" + (Number(o.amount_refunded || 0) / 100).toFixed(2) + "); record the part you kept again" : "refunded";
      return { handled: true, action: "refunded", detail: await call(deps, "rg_online_payment_reversed", { p_id: id, p_status: "refunded", p_reason: reason }) };
    }
    case "charge.dispute.created": {
      const pi = intentOf(o); const id = pi ? await deps.idForIntent(pi) : null; if (!id) return { handled: false, detail: "unknown payment" };
      return { handled: true, action: "disputed", detail: await call(deps, "rg_online_payment_reversed", { p_id: id, p_status: "disputed", p_reason: o.reason || "disputed" }) };
    }
    case "account.updated": {
      if (!o.id) return { handled: false };
      await deps.syncAccount(o);
      return { handled: true, action: "account" };
    }
    default:
      return { handled: false, detail: "ignored " + event?.type };
  }
}
