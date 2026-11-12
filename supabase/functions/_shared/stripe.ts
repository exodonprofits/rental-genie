// Rental Genie — Stripe helpers shared by rg-stripe-connect, rg-stripe-checkout and rg-stripe-webhook.
// Design: docs/design/stripe-online-rent.md. Pure functions plus one fetch wrapper; no Supabase here.
// Tested in tests/stripe/stripe.test.ts (node --experimental-strip-types).
//
// Stripe takes form-encoded bodies with bracketed keys (line_items[0][price_data][currency]=usd); `form()`
// flattens a nested object into that. Webhooks are signed with HMAC-SHA256 over "<t>.<raw body>"
// (header "Stripe-Signature: t=…,v1=…"); `verifyStripeSignature()` checks it with WebCrypto and rejects
// timestamps older than the tolerance (replays).

export const SITE = "https://rentalgenieai.com";

// ACH Direct Debit: 0.8%, capped at $5 (Stripe US pricing as recorded in the design doc; re-check before
// launch). The landlord absorbs it (design decision 1): the checkout sets it as the application fee, so the
// platform's Stripe fee is covered and the landlord receives the rest.
export const ACH_FEE_RATE = 0.008;
export const ACH_FEE_CAP_CENTS = 500;

export function achFeeCents(amountCents: number): number {
  if (!Number.isFinite(amountCents) || amountCents <= 0) return 0;
  return Math.min(Math.ceil(amountCents * ACH_FEE_RATE), ACH_FEE_CAP_CENTS);
}

export function toCents(amount: unknown): number | null {
  const n = typeof amount === "string" ? Number(amount.replace(/[$,\s]/g, "")) : Number(amount);
  if (!Number.isFinite(n)) return null;
  const c = Math.round(n * 100);
  return Math.abs(c - n * 100) < 0.5 ? c : null;
}

// What a tenant may pay for one lease, from rg_my_rent_schedule rows (as of today) for that lease:
// at least $1; at most everything owed plus one month ahead (design 3.6).
export type ScheduleRow = { lease_id: string; due_date: string; rent_amount: number | string; balance: number | string };
export function payBounds(rows: ScheduleRow[], leaseId: string) {
  const mine = rows.filter((r) => r.lease_id === leaseId);
  const balance = Math.round(mine.reduce((s, r) => s + Number(r.balance || 0), 0) * 100);
  const rent = Math.round(Number(mine[0]?.rent_amount || 0) * 100);
  return { balanceCents: balance, rentCents: rent, minCents: 100, maxCents: balance + rent, known: mine.length > 0 };
}

export function checkAmount(amountCents: number | null, b: ReturnType<typeof payBounds>): string | null {
  if (!b.known) return "No rent schedule was found for this lease.";
  if (amountCents === null) return "Enter an amount in dollars and cents.";
  if (amountCents < b.minCents) return "The smallest online payment is $1.00.";
  if (amountCents > b.maxCents) {
    return "That's more than you owe plus one month's rent ($" + (b.maxCents / 100).toFixed(2) + ").";
  }
  return null;
}

// { a: { b: [ { c: 1 } ] } } -> "a[b][0][c]=1"
export function form(obj: Record<string, unknown>, prefix = "", out = new URLSearchParams()): URLSearchParams {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue;
    const key = prefix ? prefix + "[" + k + "]" : k;
    if (Array.isArray(v)) {
      v.forEach((item, i) => {
        if (item !== null && typeof item === "object") form(item as Record<string, unknown>, key + "[" + i + "]", out);
        else out.append(key + "[" + i + "]", String(item));
      });
    } else if (typeof v === "object") {
      form(v as Record<string, unknown>, key, out);
    } else {
      out.append(key, String(v));
    }
  }
  return out;
}

function hex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Stripe-Signature: t=1700000000,v1=<hex hmac>[,v1=…][,v0=…]
export async function verifyStripeSignature(header: string | null, body: string, secret: string,
                                            nowSeconds = Math.floor(Date.now() / 1000), toleranceSeconds = 300): Promise<boolean> {
  if (!header || !secret) return false;
  const parts = header.split(",").map((p) => p.trim().split("="));
  const t = parts.find((p) => p[0] === "t")?.[1];
  const sigs = parts.filter((p) => p[0] === "v1").map((p) => p[1]).filter(Boolean);
  if (!t || !sigs.length || !/^\d+$/.test(t)) return false;
  if (Math.abs(nowSeconds - Number(t)) > toleranceSeconds) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(t + "." + body)));
  return sigs.some((s) => safeEqual(s, mac));
}

export class StripeError extends Error {
  status: number; code?: string;
  constructor(message: string, status: number, code?: string) { super(message); this.status = status; this.code = code; }
}

// One Stripe API call. `idempotencyKey` makes retries safe (same key -> same result, never a second object).
export async function stripe(secretKey: string, method: "GET" | "POST", path: string,
                             params?: Record<string, unknown>, opts: { idempotencyKey?: string; fetchImpl?: typeof fetch } = {}) {
  const f = opts.fetchImpl || fetch;
  const body = params ? form(params).toString() : undefined;
  const url = "https://api.stripe.com/v1" + path + (method === "GET" && body ? "?" + body : "");
  const headers: Record<string, string> = { Authorization: "Bearer " + secretKey };
  if (method === "POST") headers["Content-Type"] = "application/x-www-form-urlencoded";
  if (opts.idempotencyKey) headers["Idempotency-Key"] = opts.idempotencyKey;
  const res = await f(url, { method, headers, body: method === "POST" ? body : undefined, signal: AbortSignal.timeout(20000) });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new StripeError(json?.error?.message || "Stripe request failed (" + res.status + ")", res.status, json?.error?.code);
  return json;
}

// Today's date where the landlords are (rent due dates are Chicago calendar dates)
export function chicagoDate(d = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
