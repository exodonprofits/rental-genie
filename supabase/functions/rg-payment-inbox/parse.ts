// Rental Genie payment inbox: email parser (pure functions, no I/O; tested with Node).
//
// Input: a received email as returned by Resend's "Retrieve received email" API
// (GET /emails/receiving/{id}): from, to, cc, bcc, received_for, subject, text, html, headers,
// message_id, authentication { spf, dkim, dmarc }.
// Ported from the n8n "Parse alert" node (json/rental-genie-payment-inbox.n8n.json), which read
// Postmark payloads.
//
// Output, one of:
//   { route: "payment", ... }  a rule-parsed incoming payment, ready for rg_ingest_payment_email
//   { route: "ai", ... }       unknown format that looks like money: ask the AI to extract it
//   { route: "verify", ... }   Gmail's forwarding-confirmation email: store its link
//   { route: "skip", reason }  not a payment (marketing, outgoing money, no inbox address)

export type ReceivedEmail = {
  from?: string | null;
  to?: string[] | null;
  cc?: string[] | null;
  bcc?: string[] | null;
  received_for?: string[] | null;
  subject?: string | null;
  text?: string | null;
  html?: string | null;
  headers?: Record<string, string> | null;
  message_id?: string | null;
  authentication?: { spf?: string; dkim?: string; dmarc?: string } | null;
};

export type Payment = {
  route: "payment";
  token: string;
  messageId: string | null;
  source: string;
  method: string;
  payer: string;
  amount: number;
  date: string | null;
  memo: string | null;
  txn: string | null;
  subject: string;
  body: string;
  verified: boolean;
};

export type Parsed =
  | Payment
  | { route: "ai"; token: string; messageId: string | null; from: string; subject: string; text: string }
  | { route: "verify"; token: string; verifyUrl: string }
  | { route: "skip"; reason: string };

// A company's address is rent-<token>@<receiving domain>. The token is companies.payment_inbox_token.
const TOKEN_RE = /(?:^|[<\s,])rent-([a-z0-9]{6,32})@/i;

export function htmlToText(html: string | null | undefined): string {
  return String(html || "")
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|tr|td|th|h\d)>/gi, "\n")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&#36;/g, "$")
    .replace(/[ \t]+/g, " ");
}

export function toISODate(s: string | null | undefined): string | null {
  if (!s) return null;
  const d = new Date(String(s).replace(/\./g, "") + " 12:00");
  if (isNaN(d.getTime())) return null;
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
}

export function money(s: string | null | undefined): number | null {
  if (s == null) return null;
  const n = Number(String(s).replace(/[,\s$]/g, ""));
  return isFinite(n) && n > 0 ? n : null;
}

// The bare address from "Name <addr@x>" or "addr@x", lower-cased.
export function address(s: string | null | undefined): string {
  const v = String(s || "").trim();
  const m = v.match(/<([^>]+)>/);
  return (m ? m[1] : v).trim().toLowerCase();
}

function domainOf(addr: string): string {
  const at = addr.lastIndexOf("@");
  return at >= 0 ? addr.slice(at + 1) : "";
}

// The sender is genuine only when DKIM passed for the From domain. Resend computes this on its own
// mail server ("gray" when unsigned or signed by another domain), so a sender can't forge it.
export function senderVerified(email: ReceivedEmail, domain: string): boolean {
  const from = domainOf(address(email.from));
  const fromMatches = from === domain || from.endsWith("." + domain);
  return fromMatches && email.authentication?.dkim === "pass";
}

export function inboxToken(email: ReceivedEmail): string | null {
  const candidates = [
    ...(email.received_for || []), ...(email.to || []), ...(email.cc || []), ...(email.bcc || []),
  ];
  const h = email.headers || {};
  for (const k of Object.keys(h)) {
    const lk = k.toLowerCase();
    if (lk === "to" || lk === "delivered-to" || lk === "x-original-to" || lk === "cc") candidates.push(String(h[k]));
  }
  for (const c of candidates) {
    const m = (" " + String(c)).match(TOKEN_RE);
    if (m) return m[1].toLowerCase();
  }
  return null;
}

// Cheap pre-check before paying for an AI call: does the email mention a dollar amount at all?
export function mentionsMoney(text: string): boolean {
  return /\$\s?\d/.test(text) || /\bUSD\s?\d/i.test(text) || /\d[\d,]*\.\d{2}\s?(USD|dollars)\b/i.test(text);
}

export function parseEmail(email: ReceivedEmail): Parsed {
  const from = address(email.from);
  const subject = String(email.subject || "");
  let text = String(email.text || "");
  if (text.replace(/[\s|]/g, "").length < 20) text = htmlToText(email.html);
  const flat = text.replace(/\s+/g, " ").trim();
  const token = inboxToken(email);
  const messageId = email.message_id || null;

  if (!token) return { route: "skip", reason: "no inbox token" };

  // Gmail asks the new forwarding address to confirm it. Only a Google link is ever stored.
  if (from === "forwarding-noreply@google.com") {
    const link = flat.match(/https:\/\/mail(?:-settings)?\.google\.com\/mail\/[^\s)"'<>]+/i);
    return link ? { route: "verify", token, verifyUrl: link[0] } : { route: "skip", reason: "verification email without link" };
  }

  // Chase: "You received money with Zelle®"
  if (domainOf(from).endsWith("chase.com") && /received money with zelle/i.test(subject)) {
    const payer = (flat.match(/\|?\s*([A-Za-z0-9 .,'&-]{2,80}?)\s+sent you money/i) || [])[1];
    const amount = money((flat.match(/Amount[\s|:]*\$\s*([\d,]+(?:\.\d{2})?)/i) || [])[1]);
    const date = toISODate((flat.match(/Sent on[\s|:]*([A-Za-z]{3,9}\.? \d{1,2}, \d{4})/i) || [])[1]);
    const txn = (flat.match(/Transaction number[\s|:#]*([A-Za-z0-9]+)/i) || [])[1] || null;
    const memoM = text.match(/Memo[ \t|:]*([^|\n\r]+)/i);
    const memo = memoM ? memoM[1].trim() : null;
    if (payer && amount) {
      return {
        route: "payment", token, messageId, source: "chase_zelle", method: "Zelle",
        payer: payer.trim(), amount, date, memo, txn,
        subject, body: flat.slice(0, 4000), verified: senderVerified(email, "chase.com"),
      };
    }
  }

  // Venmo: "Name paid you $X" (only venmo@venmo.com; email.venmo.com is marketing)
  if (from === "venmo@venmo.com") {
    const vs = subject.match(/^(.+?) paid you \$([\d,]+(?:\.\d{2})?)/i);
    const amount = vs ? money(vs[2]) : null;
    if (!vs || !amount) return { route: "skip", reason: "venmo email that is not an incoming payment" };
    const date = toISODate((flat.match(/Date[\s|#:]*([A-Za-z]{3,9}\.? \d{1,2}, \d{4})/i) || [])[1]);
    const txn = (flat.match(/Transaction ID[\s|#:]*(\d+)/i) || [])[1] || null;
    const memoM = flat.match(/paid you \$\s*[\d,]+\s*\.?\s*\d{0,2}\s+((?:(?!paid you).)*?)\s+See transaction/i);
    return {
      route: "payment", token, messageId, source: "venmo", method: "Venmo",
      payer: vs[1].trim(), amount, date, memo: memoM ? memoM[1].trim() : null, txn,
      subject, body: flat.slice(0, 4000), verified: senderVerified(email, "venmo.com"),
    };
  }
  if (domainOf(from).endsWith("venmo.com")) return { route: "skip", reason: "venmo marketing" };

  // Anything else that mentions money: let the AI decide whether it is an incoming payment.
  if (!mentionsMoney(subject + " " + flat)) return { route: "skip", reason: "no amount mentioned" };
  return { route: "ai", token, messageId, from, subject, text: flat.slice(0, 6000) };
}

// Shape the AI's JSON answer like a rule-parsed payment. AI-read payments are never "verified".
export function fromAi(
  src: { token: string; messageId: string | null; subject: string; text: string },
  data: any,
): Payment | null {
  if (!data || data.is_incoming_payment !== true) return null;
  const amount = Number(data.amount);
  const payer = typeof data.payer === "string" ? data.payer.trim() : "";
  if (!isFinite(amount) || amount <= 0 || !payer) return null;
  const date = typeof data.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(data.date) ? data.date : null;
  return {
    route: "payment", token: src.token, messageId: src.messageId, source: "ai",
    method: typeof data.method === "string" && data.method ? data.method : "Other",
    payer, amount, date,
    memo: typeof data.memo === "string" && data.memo ? data.memo : null,
    txn: typeof data.transaction_ref === "string" && data.transaction_ref ? data.transaction_ref : null,
    subject: src.subject, body: src.text.slice(0, 4000), verified: false,
  };
}
