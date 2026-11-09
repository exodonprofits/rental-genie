// Payment inbox parser tests (invented emails only). Run: node --experimental-strip-types tests/payment-inbox/parse.test.ts
import { parseEmail, fromAi, senderVerified, inboxToken } from "../../supabase/functions/rg-payment-inbox/parse.ts";
let fails = 0;
const ok = (n: string, c: boolean, i?: unknown) => { console.log((c ? "PASS " : "FAIL ") + n + (c ? "" : " " + JSON.stringify(i))); if (!c) fails++; };
const ADDR = "rent-43c62359c6@inbox.rentalgenieai.com";
const base = { to: ["jtran112675@gmail.com"], received_for: [ADDR], message_id: "<abc@chase.com>", authentication: { spf: "fail", dkim: "pass", dmarc: "pass" } };

// Chase Zelle (Gmail-forwarded: To is still the landlord's Gmail; our address is in received_for)
const chase = { ...base, from: "Chase <no.reply.alerts@chase.com>", subject: "You received money with Zelle®",
  text: "Alex Bovey sent you money\n| Amount | $1,450.00 |\n| Sent on | Nov 3, 2026 |\n| Memo | Nov rent South Elgin |\n| Transaction number | ABC123XYZ |" };
const r1: any = parseEmail(chase);
ok("chase parsed", r1.route === "payment" && r1.payer === "Alex Bovey" && r1.amount === 1450 && r1.date === "2026-11-03" && r1.txn === "ABC123XYZ" && r1.method === "Zelle", r1);
ok("chase memo", r1.memo === "Nov rent South Elgin", r1.memo);
ok("chase token from received_for", r1.token === "43c62359c6", r1.token);
ok("chase verified (dkim pass + chase.com)", r1.verified === true);
ok("chase unverified when dkim gray", (parseEmail({ ...chase, authentication: { dkim: "gray" } }) as any).verified === false);
ok("spoofed domain not verified", senderVerified({ from: "x@chase.com.evil.io", authentication: { dkim: "pass" } }, "chase.com") === false);
ok("subdomain verified", senderVerified({ from: "a@alerts.chase.com", authentication: { dkim: "pass" } }, "chase.com") === true);

// Chase HTML only
const r1h: any = parseEmail({ ...chase, text: "", html: "<table><tr><td>Alex Bovey sent you money</td></tr><tr><td>Amount</td><td>$1,450.00</td></tr><tr><td>Sent on</td><td>Nov 3, 2026</td></tr></table>" });
ok("chase html parsed", r1h.route === "payment" && r1h.amount === 1450 && r1h.payer === "Alex Bovey", r1h);

// Venmo
const venmo = { ...base, from: "Venmo <venmo@venmo.com>", subject: "Jane Doe paid you $2,100.00",
  text: "Jane Doe paid you $2,100.00 November rent Bartlett See transaction Date Nov 1, 2026 Transaction ID 4012345678901234567" };
const r2: any = parseEmail(venmo);
ok("venmo parsed", r2.route === "payment" && r2.payer === "Jane Doe" && r2.amount === 2100 && r2.date === "2026-11-01" && r2.txn === "4012345678901234567", r2);
ok("venmo memo", r2.memo === "November rent Bartlett", r2.memo);
ok("venmo outgoing skipped", parseEmail({ ...venmo, subject: "You paid Jane Doe $20.00" }).route === "skip");
ok("venmo marketing skipped", parseEmail({ ...venmo, from: "Venmo <news@email.venmo.com>", subject: "New: 3% cash back" }).route === "skip");

// Gmail forwarding confirmation
const g: any = parseEmail({ ...base, to: [ADDR], received_for: [], from: "Gmail Team <forwarding-noreply@google.com>", subject: "(#123) Gmail Forwarding Confirmation",
  text: "To allow forwarding click the link below: https://mail-settings.google.com/mail/vf-%5BANGjdJ%5D-abc123 If you click..." });
ok("gmail verify link", g.route === "verify" && g.verifyUrl.startsWith("https://mail-settings.google.com/mail/vf-") && g.token === "43c62359c6", g);
ok("gmail non-google link ignored", parseEmail({ ...base, from: "forwarding-noreply@google.com", subject: "x", text: "click https://evil.example/mail/vf" }).route === "skip");

// Unknown bank -> AI only when money is mentioned
const boa = { ...base, from: "Bank of America <onlinebanking@ealerts.bankofamerica.com>", subject: "You received a Zelle payment", text: "Bob Smith sent you $1,800.00 on November 2, 2026." };
const r3: any = parseEmail(boa);
ok("other bank -> ai", r3.route === "ai" && r3.token === "43c62359c6", r3);
ok("no amount -> skip", parseEmail({ ...boa, subject: "Your statement is ready", text: "Log in to view your statement." }).route === "skip");
ok("no token -> skip", parseEmail({ ...chase, to: ["someone@else.com"], received_for: [] }).route === "skip");
ok("token from header", inboxToken({ headers: { "X-Original-To": ADDR } }) === "43c62359c6");
ok("token not from lookalike", inboxToken({ to: ["notrent-43c62359c6@inbox.rentalgenieai.com"] }) === null);

// AI result shaping
const ai = fromAi({ token: "t1", messageId: "<m>", subject: "s", text: "body" }, { is_incoming_payment: true, payer: " Bob Smith ", amount: 1800, date: "2026-11-02", method: "Zelle", memo: null, transaction_ref: null });
ok("ai payment shaped, unverified", !!ai && ai.payer === "Bob Smith" && ai.amount === 1800 && ai.verified === false && ai.source === "ai", ai);
ok("ai not incoming -> null", fromAi({ token: "t", messageId: null, subject: "", text: "" }, { is_incoming_payment: false }) === null);
ok("ai bad amount -> null", fromAi({ token: "t", messageId: null, subject: "", text: "" }, { is_incoming_payment: true, payer: "X", amount: -5 }) === null);
ok("ai bad date dropped", fromAi({ token: "t", messageId: null, subject: "", text: "" }, { is_incoming_payment: true, payer: "X", amount: 5, date: "Nov 2" })!.date === null);
process.exit(fails ? 1 : 0);
