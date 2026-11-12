// Stripe helper tests (invented data only). Run: node --experimental-strip-types tests/stripe/stripe.test.ts
import { achFeeCents, toCents, payBounds, checkAmount, form, verifyStripeSignature, stripe, chicagoDate } from "../../supabase/functions/_shared/stripe.ts";
import { createHmac } from "node:crypto";
let fails = 0;
const ok = (n: string, c: boolean, i?: unknown) => { console.log((c ? "PASS " : "FAIL ") + n + (c ? "" : " " + JSON.stringify(i))); if (!c) fails++; };

// Fees: 0.8% capped at $5
ok("fee $100", achFeeCents(10000) === 80, achFeeCents(10000));
ok("fee $1,500 capped", achFeeCents(150000) === 500, achFeeCents(150000));
ok("fee $1 rounds up", achFeeCents(100) === 1, achFeeCents(100));
ok("fee zero/neg", achFeeCents(0) === 0 && achFeeCents(-5) === 0);

// Amounts
ok("cents from number", toCents(1500) === 150000);
ok("cents from string", toCents("$1,234.56") === 123456);
ok("cents rejects 3 decimals", toCents("12.345") === null, toCents("12.345"));
ok("cents rejects junk", toCents("abc") === null);

// Bounds from schedule rows
const rows = [
  { lease_id: "L1", due_date: "2026-10-01", rent_amount: "1500", balance: "1000" },
  { lease_id: "L1", due_date: "2026-11-01", rent_amount: "1500", balance: "1500" },
  { lease_id: "L2", due_date: "2026-11-01", rent_amount: "900", balance: "900" }];
const b = payBounds(rows, "L1");
ok("balance L1", b.balanceCents === 250000 && b.rentCents === 150000 && b.maxCents === 400000, b);
ok("full balance ok", checkAmount(250000, b) === null);
ok("balance + 1 month ok", checkAmount(400000, b) === null);
ok("over limit refused", /more than you owe/.test(String(checkAmount(400001, b))));
ok("under $1 refused", /smallest/.test(String(checkAmount(99, b))));
ok("bad amount refused", /dollars and cents/.test(String(checkAmount(null, b))));
ok("unknown lease refused", /No rent schedule/.test(String(checkAmount(1000, payBounds(rows, "L9")))));
const paidUp = payBounds([{ lease_id: "L3", due_date: "2026-11-01", rent_amount: "2100", balance: "0" }], "L3");
ok("paid up: one month ahead allowed", checkAmount(210000, paidUp) === null && checkAmount(210001, paidUp) !== null);

// Form encoding
const f = form({ mode: "payment", line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: 150000, product_data: { name: "Rent — Oak St" } } }],
  payment_method_types: ["us_bank_account"], metadata: { online_payment_id: "abc" }, skip: undefined });
ok("form nested", f.get("line_items[0][price_data][unit_amount]") === "150000" && f.get("line_items[0][price_data][product_data][name]") === "Rent — Oak St", f.toString());
ok("form array of scalars", f.get("payment_method_types[0]") === "us_bank_account");
ok("form skips undefined", !f.has("skip"));

// Webhook signatures (Stripe scheme: hex HMAC-SHA256 of "<t>.<body>")
const secret = "whsec_test_secret";
const body = JSON.stringify({ id: "evt_1", type: "payment_intent.succeeded" });
const t = 1800000000;
const sig = createHmac("sha256", secret).update(t + "." + body).digest("hex");
ok("signature valid", await verifyStripeSignature("t=" + t + ",v1=" + sig, body, secret, t + 10));
ok("signature with extra v0/v1", await verifyStripeSignature("t=" + t + ",v1=deadbeef,v1=" + sig + ",v0=x", body, secret, t));
ok("signature wrong secret", !(await verifyStripeSignature("t=" + t + ",v1=" + sig, body, "whsec_other", t)));
ok("signature tampered body", !(await verifyStripeSignature("t=" + t + ",v1=" + sig, body + " ", secret, t)));
ok("signature too old (replay)", !(await verifyStripeSignature("t=" + t + ",v1=" + sig, body, secret, t + 301)));
ok("signature missing header", !(await verifyStripeSignature(null, body, secret, t)));
ok("signature garbage header", !(await verifyStripeSignature("nonsense", body, secret, t)));

// API wrapper with a fake fetch: method, auth, idempotency, form body, errors
let seen: any = null;
const fake = (async (url: string, init: any) => { seen = { url, init }; return new Response(JSON.stringify(url.includes("fail") ? { error: { message: "No such account", code: "resource_missing" } } : { id: "acct_1" }), { status: url.includes("fail") ? 404 : 200 }); }) as any;
const r = await stripe("sk_test_x", "POST", "/accounts", { type: "express", capabilities: { transfers: { requested: true } } }, { idempotencyKey: "acct-1", fetchImpl: fake });
ok("api result", r.id === "acct_1");
ok("api headers", seen.init.headers.Authorization === "Bearer sk_test_x" && seen.init.headers["Idempotency-Key"] === "acct-1" && seen.init.headers["Content-Type"] === "application/x-www-form-urlencoded");
ok("api body", seen.init.body.includes("capabilities%5Btransfers%5D%5Brequested%5D=true"), seen.init.body);
let err: any = null;
try { await stripe("sk_test_x", "GET", "/accounts/fail", undefined, { fetchImpl: fake }); } catch (e) { err = e; }
ok("api error surfaces Stripe message", err && err.status === 404 && err.message === "No such account" && err.code === "resource_missing", err && err.message);

ok("chicago date", chicagoDate(new Date("2026-11-12T03:00:00Z")) === "2026-11-11", chicagoDate(new Date("2026-11-12T03:00:00Z")));

console.log(fails ? fails + " FAILED" : "all passed");
process.exit(fails ? 1 : 0);
