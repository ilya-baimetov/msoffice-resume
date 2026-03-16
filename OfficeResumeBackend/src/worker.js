import { hardCodedFreePassEmails } from "./free-pass-emails.js";

const JSON_HEADERS = { "content-type": "application/json" };
const HTML_HEADERS = { "content-type": "text/html; charset=utf-8" };
const SESSION_TTL_SECONDS = 90 * 24 * 60 * 60;
const MAGIC_LINK_TTL_SECONDS = 15 * 60;
const BILLING_ENTRY_TTL_SECONDS = 15 * 60;
const TRIAL_LENGTH_MILLIS = 14 * 24 * 60 * 60 * 1000;
const MIN_STRIPE_TRIAL_MILLIS = 48 * 60 * 60 * 1000;
const ONE_DAY_MILLIS = 24 * 60 * 60 * 1000;

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS,
  });
}

function htmlResponse(body, status = 200) {
  return new Response(body, {
    status,
    headers: HTML_HEADERS,
  });
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function parseBearerToken(request) {
  const header = request.headers.get("authorization") ?? "";
  if (!header.toLowerCase().startsWith("bearer ")) {
    return null;
  }
  return header.slice(7).trim();
}

function randomToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return hex(bytes.buffer);
}

function hex(buffer) {
  const bytes = new Uint8Array(buffer);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(left, right) {
  if (left.length !== right.length) {
    return false;
  }

  let result = 0;
  for (let index = 0; index < left.length; index += 1) {
    result |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }

  return result === 0;
}

function normalize(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function csvSet(value) {
  if (!value) {
    return new Set();
  }

  return new Set(
    String(value)
      .split(",")
      .map((part) => normalize(part))
      .filter(Boolean),
  );
}

function isEnabled(value) {
  return ["1", "true", "yes", "on"].includes(String(value ?? "").trim().toLowerCase());
}

async function parseRequestBody(request) {
  const contentType = (request.headers.get("content-type") ?? "").toLowerCase();

  if (contentType.includes("application/json")) {
    return request.json().catch(() => ({}));
  }

  if (contentType.includes("application/x-www-form-urlencoded")) {
    const text = await request.text();
    const params = new URLSearchParams(text);
    return Object.fromEntries(params.entries());
  }

  return {};
}

function parseStripeSignature(headerValue) {
  const components = String(headerValue ?? "")
    .split(",")
    .map((part) => part.trim())
    .filter(Boolean);

  const parsed = { timestamp: null, signatures: [] };
  for (const component of components) {
    const [key, value] = component.split("=", 2);
    if (key === "t" && value) {
      parsed.timestamp = Number.parseInt(value, 10);
    } else if (key === "v1" && value) {
      parsed.signatures.push(value);
    }
  }

  return parsed;
}

async function stripeSignature(secret, timestamp, payload) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const body = `${timestamp}.${payload}`;
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(body));
  return hex(signature);
}

async function verifyStripeWebhook(request, payload, options) {
  const secret = options.stripeWebhookSecret;
  if (!secret) {
    return true;
  }

  const toleranceSeconds = options.webhookToleranceSeconds ?? 300;
  const nowMillis = options.nowMillis();
  const signatureHeader = request.headers.get("stripe-signature");
  const parsed = parseStripeSignature(signatureHeader);

  if (!Number.isFinite(parsed.timestamp) || parsed.signatures.length === 0) {
    return false;
  }

  const timestampMillis = parsed.timestamp * 1000;
  if (Math.abs(nowMillis - timestampMillis) > toleranceSeconds * 1000) {
    return false;
  }

  const expected = await stripeSignature(secret, parsed.timestamp, payload);
  return parsed.signatures.some((candidate) => timingSafeEqual(candidate, expected));
}

function inferPlanFromStripeObject(object) {
  const intervalCandidate =
    object.interval ??
    object.items?.data?.[0]?.price?.recurring?.interval ??
    object.plan?.interval;

  return intervalCandidate === "year" ? "yearly" : "monthly";
}

function extractCustomerEmail(object) {
  return normalize(
    object.customer_email ??
      object.customer_details?.email ??
      object.metadata?.email ??
      object.customer?.email,
  );
}

function extractCustomerID(object) {
  if (typeof object.customer === "string" && object.customer.trim()) {
    return object.customer.trim();
  }
  if (typeof object.customer_id === "string" && object.customer_id.trim()) {
    return object.customer_id.trim();
  }
  return null;
}

function isPaidSubscription(subscription) {
  if (!subscription) {
    return false;
  }
  return subscription.status === "active" || subscription.status === "trialing";
}

function inactiveEntitlement(nowMillis) {
  return {
    isActive: false,
    plan: "none",
    validUntil: null,
    trialEndsAt: null,
    lastValidatedAt: new Date(nowMillis).toISOString(),
  };
}

function activeTrialEntitlement(trialStartMillis, nowMillis) {
  const trialEndsMillis = trialStartMillis + TRIAL_LENGTH_MILLIS;
  const trialEndsAt = new Date(trialEndsMillis).toISOString();
  if (nowMillis >= trialEndsMillis) {
    return {
      isActive: false,
      plan: "none",
      validUntil: trialEndsAt,
      trialEndsAt,
      lastValidatedAt: new Date(nowMillis).toISOString(),
    };
  }

  return {
    isActive: true,
    plan: "trial",
    validUntil: trialEndsAt,
    trialEndsAt,
    lastValidatedAt: new Date(nowMillis).toISOString(),
  };
}

function activeFreePassEntitlement(nowMillis) {
  const validUntil = new Date(nowMillis + 10 * 365 * 24 * 60 * 60 * 1000).toISOString();
  return {
    isActive: true,
    plan: "yearly",
    validUntil,
    trialEndsAt: null,
    freePass: true,
    lastValidatedAt: new Date(nowMillis).toISOString(),
  };
}

function subscriptionToEntitlement(subscription, nowMillis) {
  if (!subscription) {
    return inactiveEntitlement(nowMillis);
  }

  return {
    isActive: isPaidSubscription(subscription),
    plan: subscription.plan,
    validUntil: subscription.validUntil,
    trialEndsAt: subscription.trialEndsAt ?? null,
    lastValidatedAt: new Date(nowMillis).toISOString(),
  };
}

function callbackBaseURL(options) {
  const scheme = String(options.callbackScheme ?? "officeresume-direct").trim() || "officeresume-direct";
  const host = String(options.callbackHost ?? "auth").trim() || "auth";
  const path = String(options.callbackPath ?? "/complete").trim() || "/complete";
  return new URL(`${scheme}://${host}${path.startsWith("/") ? path : `/${path}`}`);
}

function callbackURLForSession(email, sessionToken, options) {
  const url = callbackBaseURL(options);
  url.searchParams.set("sessionToken", sessionToken);
  url.searchParams.set("email", email);
  return url.toString();
}

function callbackURLForBillingRefresh(options) {
  const url = callbackBaseURL(options);
  url.searchParams.set("action", "billingRefresh");
  return url.toString();
}

async function sendMagicLinkEmail({ email, verifyURL, options }) {
  if (typeof options.emailSender === "function") {
    await options.emailSender({ email, verifyURL });
    return;
  }

  const apiKey = String(options.resendApiKey ?? "").trim();
  const fromEmail = String(options.resendFromEmail ?? "").trim();
  if (!apiKey || !fromEmail) {
    throw new Error("Resend is not configured");
  }

  const response = await options.fetchImpl("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail,
      to: [email],
      subject: "Sign in to Office Resume",
      html: `<p>Open Office Resume by clicking this secure link:</p><p><a href="${verifyURL}">Sign in to Office Resume</a></p>`,
    }),
  });

  if (!response.ok) {
    throw new Error(`Resend request failed with status ${response.status}`);
  }
}

async function createStripeBillingPortalURL({ customerID, options }) {
  if (typeof options.billingPortalFactory === "function") {
    return options.billingPortalFactory(customerID);
  }

  const stripeSecretKey = String(options.stripeSecretKey ?? "").trim();
  const returnURL = String(options.stripeBillingReturnURL ?? "").trim();
  if (!stripeSecretKey || !returnURL) {
    return null;
  }

  const body = new URLSearchParams();
  body.set("customer", customerID);
  body.set("return_url", returnURL);

  const response = await options.fetchImpl("https://api.stripe.com/v1/billing_portal/sessions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${stripeSecretKey}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });

  if (!response.ok) {
    throw new Error(`Stripe billing portal request failed with status ${response.status}`);
  }

  const payload = await response.json();
  return typeof payload.url === "string" ? payload.url : null;
}

function computeStripeTrialConfig(trialStartMillis, nowMillis) {
  if (!Number.isFinite(trialStartMillis)) {
    return null;
  }

  const remainingMillis = trialStartMillis + TRIAL_LENGTH_MILLIS - nowMillis;
  if (remainingMillis <= 0) {
    return null;
  }

  if (remainingMillis >= MIN_STRIPE_TRIAL_MILLIS) {
    return { trialEnd: Math.ceil((nowMillis + remainingMillis) / 1000) };
  }

  return {
    trialPeriodDays: Math.max(1, Math.ceil(remainingMillis / ONE_DAY_MILLIS)),
  };
}

function hasCheckoutConfiguration(options) {
  if (typeof options.checkoutSessionFactory === "function") {
    return true;
  }

  const secret = String(options.stripeSecretKey ?? "").trim();
  const monthly = String(options.stripePriceMonthly ?? "").trim();
  const yearly = String(options.stripePriceYearly ?? "").trim();
  return Boolean(secret && monthly && yearly);
}

async function createStripeCheckoutSessionURL({ email, plan, trialConfig, successURL, cancelURL, options }) {
  if (typeof options.checkoutSessionFactory === "function") {
    return options.checkoutSessionFactory({ email, plan, trialConfig, successURL, cancelURL });
  }

  const stripeSecretKey = String(options.stripeSecretKey ?? "").trim();
  const priceID = plan === "yearly"
    ? String(options.stripePriceYearly ?? "").trim()
    : String(options.stripePriceMonthly ?? "").trim();

  if (!stripeSecretKey || !priceID) {
    return null;
  }

  const body = new URLSearchParams();
  body.set("mode", "subscription");
  body.set("success_url", successURL);
  body.set("cancel_url", cancelURL);
  body.set("customer_email", email);
  body.set("client_reference_id", email);
  body.set("line_items[0][price]", priceID);
  body.set("line_items[0][quantity]", "1");
  body.set("subscription_data[metadata][email]", email);
  body.set("subscription_data[metadata][plan]", plan);

  if (trialConfig?.trialEnd) {
    body.set("subscription_data[trial_end]", String(trialConfig.trialEnd));
  } else if (trialConfig?.trialPeriodDays) {
    body.set("subscription_data[trial_period_days]", String(trialConfig.trialPeriodDays));
  }

  const response = await options.fetchImpl("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      authorization: `Bearer ${stripeSecretKey}`,
      "content-type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });

  if (!response.ok) {
    throw new Error(`Stripe checkout session request failed with status ${response.status}`);
  }

  const payload = await response.json();
  return typeof payload.url === "string" ? payload.url : null;
}

function renderPricingPage({ entryToken, cancelled = false }) {
  const escapedEntry = escapeHTML(entryToken);
  const notice = cancelled
    ? '<p class="notice">Checkout was canceled. You can choose a plan again below.</p>'
    : "";

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Office Resume Pricing</title>
    <style>
      :root { color-scheme: light; }
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 32px 20px; background: #f6f3ec; color: #1d1d1f; }
      main { max-width: 680px; margin: 0 auto; background: white; border-radius: 18px; padding: 28px; box-shadow: 0 12px 40px rgba(0,0,0,0.08); }
      h1 { margin: 0 0 8px; font-size: 32px; }
      p { line-height: 1.5; }
      .notice { background: #fff7d6; border: 1px solid #e7d184; padding: 12px 14px; border-radius: 12px; }
      .plans { display: grid; gap: 14px; margin-top: 24px; }
      form { border: 1px solid #d7d2c7; border-radius: 16px; padding: 18px; display: grid; gap: 10px; }
      button { appearance: none; border: 0; border-radius: 999px; background: #0b6f4f; color: white; padding: 12px 18px; font-size: 16px; cursor: pointer; }
      .price { font-size: 28px; font-weight: 700; }
      .caption { color: #5b5b5f; font-size: 14px; }
    </style>
  </head>
  <body>
    <main>
      <h1>Choose a plan</h1>
      <p>Office Resume uses verified email sign-in first, then Stripe Checkout for the paid Direct plan.</p>
      <p class="caption">Any remaining Direct trial time will be converted into Stripe-supported trial settings so billing starts after the unused trial window.</p>
      ${notice}
      <section class="plans">
        <form method="POST" action="/billing/checkout">
          <input type="hidden" name="entry" value="${escapedEntry}" />
          <input type="hidden" name="plan" value="monthly" />
          <div class="price">$5<span class="caption">/month</span></div>
          <div class="caption">Monthly subscription for Office Resume Direct.</div>
          <button type="submit">Continue with Monthly</button>
        </form>
        <form method="POST" action="/billing/checkout">
          <input type="hidden" name="entry" value="${escapedEntry}" />
          <input type="hidden" name="plan" value="yearly" />
          <div class="price">$50<span class="caption">/year</span></div>
          <div class="caption">Yearly subscription for Office Resume Direct.</div>
          <button type="submit">Continue with Yearly</button>
        </form>
      </section>
    </main>
  </body>
</html>`;
}

function renderFailurePage({ title, message, status = 400 }) {
  return htmlResponse(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHTML(title)}</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 32px 20px; background: #f6f3ec; color: #1d1d1f; }
      main { max-width: 620px; margin: 0 auto; background: white; border-radius: 18px; padding: 28px; box-shadow: 0 12px 40px rgba(0,0,0,0.08); }
      h1 { margin-top: 0; }
      p { line-height: 1.5; }
    </style>
  </head>
  <body>
    <main>
      <h1>${escapeHTML(title)}</h1>
      <p>${escapeHTML(message)}</p>
    </main>
  </body>
</html>`, status);
}

function renderCheckoutSuccessPage({ callbackURL }) {
  const escapedURL = escapeHTML(callbackURL);
  return htmlResponse(`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Office Resume Subscription Updated</title>
    <meta http-equiv="refresh" content="0;url=${escapedURL}" />
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 32px 20px; background: #f6f3ec; color: #1d1d1f; }
      main { max-width: 620px; margin: 0 auto; background: white; border-radius: 18px; padding: 28px; box-shadow: 0 12px 40px rgba(0,0,0,0.08); }
      a { color: #0b6f4f; }
    </style>
    <script>window.location.replace(${JSON.stringify(callbackURL)});</script>
  </head>
  <body>
    <main>
      <h1>Subscription updated</h1>
      <p>Return to Office Resume to refresh your account status.</p>
      <p><a href="${escapedURL}">Open Office Resume</a></p>
    </main>
  </body>
</html>`);
}

function billingEntryRecordTTL(record, now) {
  const remainingSeconds = Math.ceil((Number(record.expiresAt) - now) / 1000);
  return Math.max(60, remainingSeconds);
}

export class InMemoryEntitlementStore {
  constructor(now = Date.now) {
    this.now = now;
    this.magicLinks = new Map();
    this.sessions = new Map();
    this.subscriptions = new Map();
    this.trials = new Map();
    this.billingEntries = new Map();
  }

  async createMagicLink(email) {
    const normalized = normalize(email);
    const token = randomToken();
    const expiresAt = this.now() + MAGIC_LINK_TTL_SECONDS * 1000;
    this.magicLinks.set(token, { email: normalized, expiresAt });
    return token;
  }

  async consumeMagicLink(token) {
    const record = this.magicLinks.get(token);
    if (!record) {
      return null;
    }
    this.magicLinks.delete(token);
    if (record.expiresAt < this.now()) {
      return null;
    }
    return normalize(record.email);
  }

  async createSession(email) {
    const normalized = normalize(email);
    const token = randomToken();
    this.sessions.set(token, { email: normalized, createdAt: this.now() });
    return token;
  }

  async sessionByToken(token) {
    const record = this.sessions.get(token) ?? null;
    if (!record) {
      return null;
    }
    if (record.createdAt + SESSION_TTL_SECONDS * 1000 < this.now()) {
      this.sessions.delete(token);
      return null;
    }
    return record;
  }

  async upsertSubscription(email, subscription) {
    this.subscriptions.set(normalize(email), {
      status: subscription.status ?? "inactive",
      plan: subscription.plan ?? "monthly",
      validUntil: subscription.validUntil ?? null,
      trialEndsAt: subscription.trialEndsAt ?? null,
      customerID: subscription.customerID ?? null,
    });
  }

  async subscriptionByEmail(email) {
    return this.subscriptions.get(normalize(email)) ?? null;
  }

  async ensureTrialStart(email) {
    const normalized = normalize(email);
    if (!this.trials.has(normalized)) {
      this.trials.set(normalized, this.now());
    }
    return this.trials.get(normalized);
  }

  async trialStartByEmail(email) {
    return this.trials.get(normalize(email)) ?? null;
  }

  async createBillingEntry(email) {
    const normalized = normalize(email);
    const token = randomToken();
    const expiresAt = this.now() + BILLING_ENTRY_TTL_SECONDS * 1000;
    this.billingEntries.set(token, { email: normalized, expiresAt, usedAt: null });
    return token;
  }

  async billingEntryByToken(token, { allowUsed = false } = {}) {
    const record = this.billingEntries.get(token) ?? null;
    if (!record) {
      return null;
    }
    if (record.expiresAt < this.now()) {
      this.billingEntries.delete(token);
      return null;
    }
    if (record.usedAt && !allowUsed) {
      return null;
    }
    return {
      email: normalize(record.email),
      expiresAt: Number(record.expiresAt),
      usedAt: record.usedAt ? Number(record.usedAt) : null,
    };
  }

  async markBillingEntryUsed(token) {
    const record = await this.billingEntryByToken(token, { allowUsed: true });
    if (!record) {
      return false;
    }
    this.billingEntries.set(token, { ...record, usedAt: this.now() });
    return true;
  }
}

export class D1KVEntitlementStore {
  constructor({ d1 = null, kv = null, now = Date.now } = {}) {
    this.d1 = d1;
    this.kv = kv;
    this.now = now;
    this.schemaReady = false;
    this.schemaAttempted = false;
  }

  async ensureSchema() {
    if (!this.d1 || this.schemaReady || this.schemaAttempted) {
      return;
    }

    this.schemaAttempted = true;
    await this.d1.exec(`
      CREATE TABLE IF NOT EXISTS magic_links (
        token TEXT PRIMARY KEY,
        email TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        token TEXT PRIMARY KEY,
        email TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS subscriptions (
        email TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        plan TEXT NOT NULL,
        valid_until TEXT,
        trial_ends_at TEXT,
        customer_id TEXT
      );
      CREATE TABLE IF NOT EXISTS trials (
        email TEXT PRIMARY KEY,
        started_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS billing_entries (
        token TEXT PRIMARY KEY,
        email TEXT NOT NULL,
        expires_at INTEGER NOT NULL,
        used_at INTEGER
      );
    `);
    this.schemaReady = true;
  }

  async createMagicLink(email) {
    const normalized = normalize(email);
    const token = randomToken();
    const expiresAt = this.now() + MAGIC_LINK_TTL_SECONDS * 1000;
    const record = { email: normalized, expiresAt };

    if (this.kv) {
      await this.kv.put(`magic:${token}`, JSON.stringify(record), { expirationTtl: MAGIC_LINK_TTL_SECONDS });
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare("INSERT OR REPLACE INTO magic_links(token, email, expires_at) VALUES (?1, ?2, ?3)")
        .bind(token, normalized, expiresAt)
        .run();
    }

    return token;
  }

  async consumeMagicLink(token) {
    if (this.kv) {
      const raw = await this.kv.get(`magic:${token}`);
      if (!raw) {
        return null;
      }
      await this.kv.delete(`magic:${token}`);
      const record = JSON.parse(raw);
      if (record.expiresAt < this.now()) {
        return null;
      }
      return normalize(record.email);
    }

    if (this.d1) {
      await this.ensureSchema();
      const result = await this.d1
        .prepare("SELECT email, expires_at FROM magic_links WHERE token = ?1")
        .bind(token)
        .first();
      await this.d1.prepare("DELETE FROM magic_links WHERE token = ?1").bind(token).run();
      if (!result) {
        return null;
      }
      if (result.expires_at < this.now()) {
        return null;
      }
      return normalize(result.email);
    }

    return null;
  }

  async createSession(email) {
    const normalized = normalize(email);
    const token = randomToken();
    const createdAt = this.now();
    const record = { email: normalized, createdAt };

    if (this.kv) {
      await this.kv.put(`session:${token}`, JSON.stringify(record), { expirationTtl: SESSION_TTL_SECONDS });
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare("INSERT OR REPLACE INTO sessions(token, email, created_at) VALUES (?1, ?2, ?3)")
        .bind(token, normalized, createdAt)
        .run();
    }

    return token;
  }

  async sessionByToken(token) {
    if (this.kv) {
      const raw = await this.kv.get(`session:${token}`);
      if (!raw) {
        return null;
      }
      const record = JSON.parse(raw);
      if (record.createdAt + SESSION_TTL_SECONDS * 1000 < this.now()) {
        await this.kv.delete(`session:${token}`);
        return null;
      }
      return { email: normalize(record.email), createdAt: Number(record.createdAt) };
    }

    if (this.d1) {
      await this.ensureSchema();
      const row = await this.d1
        .prepare("SELECT email, created_at FROM sessions WHERE token = ?1")
        .bind(token)
        .first();
      if (!row) {
        return null;
      }
      const createdAt = Number(row.created_at ?? this.now());
      if (createdAt + SESSION_TTL_SECONDS * 1000 < this.now()) {
        await this.d1.prepare("DELETE FROM sessions WHERE token = ?1").bind(token).run();
        return null;
      }
      return {
        email: normalize(row.email),
        createdAt,
      };
    }

    return null;
  }

  async upsertSubscription(email, subscription) {
    const normalized = normalize(email);
    const payload = {
      status: subscription.status ?? "inactive",
      plan: subscription.plan ?? "monthly",
      validUntil: subscription.validUntil ?? null,
      trialEndsAt: subscription.trialEndsAt ?? null,
      customerID: subscription.customerID ?? null,
    };

    if (this.kv) {
      await this.kv.put(`sub:${normalized}`, JSON.stringify(payload));
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare(
          `
          INSERT INTO subscriptions(email, status, plan, valid_until, trial_ends_at, customer_id)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          ON CONFLICT(email) DO UPDATE SET
            status = excluded.status,
            plan = excluded.plan,
            valid_until = excluded.valid_until,
            trial_ends_at = excluded.trial_ends_at,
            customer_id = excluded.customer_id
          `,
        )
        .bind(normalized, payload.status, payload.plan, payload.validUntil, payload.trialEndsAt, payload.customerID)
        .run();
    }
  }

  async subscriptionByEmail(email) {
    const normalized = normalize(email);
    if (this.kv) {
      const raw = await this.kv.get(`sub:${normalized}`);
      if (!raw) {
        return null;
      }
      return JSON.parse(raw);
    }

    if (this.d1) {
      await this.ensureSchema();
      const row = await this.d1
        .prepare("SELECT status, plan, valid_until, trial_ends_at, customer_id FROM subscriptions WHERE email = ?1")
        .bind(normalized)
        .first();
      if (!row) {
        return null;
      }
      return {
        status: row.status,
        plan: row.plan,
        validUntil: row.valid_until ?? null,
        trialEndsAt: row.trial_ends_at ?? null,
        customerID: row.customer_id ?? null,
      };
    }

    return null;
  }

  async ensureTrialStart(email) {
    const normalized = normalize(email);
    if (this.kv) {
      const existing = await this.kv.get(`trial:${normalized}`);
      if (existing) {
        const parsed = JSON.parse(existing);
        return Number(parsed.startedAt);
      }

      const startedAt = this.now();
      await this.kv.put(`trial:${normalized}`, JSON.stringify({ startedAt }));
      if (this.d1) {
        await this.ensureSchema();
        await this.d1
          .prepare("INSERT OR IGNORE INTO trials(email, started_at) VALUES (?1, ?2)")
          .bind(normalized, startedAt)
          .run();
      }
      return startedAt;
    }

    if (this.d1) {
      await this.ensureSchema();
      const existing = await this.d1
        .prepare("SELECT started_at FROM trials WHERE email = ?1")
        .bind(normalized)
        .first();
      if (existing) {
        return Number(existing.started_at);
      }
      const startedAt = this.now();
      await this.d1
        .prepare("INSERT OR IGNORE INTO trials(email, started_at) VALUES (?1, ?2)")
        .bind(normalized, startedAt)
        .run();
      return startedAt;
    }

    return this.now();
  }

  async trialStartByEmail(email) {
    const normalized = normalize(email);
    if (this.kv) {
      const raw = await this.kv.get(`trial:${normalized}`);
      if (raw) {
        return Number(JSON.parse(raw).startedAt);
      }
    }

    if (this.d1) {
      await this.ensureSchema();
      const row = await this.d1
        .prepare("SELECT started_at FROM trials WHERE email = ?1")
        .bind(normalized)
        .first();
      if (row) {
        return Number(row.started_at);
      }
    }

    return null;
  }

  async createBillingEntry(email) {
    const normalized = normalize(email);
    const token = randomToken();
    const expiresAt = this.now() + BILLING_ENTRY_TTL_SECONDS * 1000;
    const record = { email: normalized, expiresAt, usedAt: null };

    if (this.kv) {
      await this.kv.put(`billing:${token}`, JSON.stringify(record), { expirationTtl: BILLING_ENTRY_TTL_SECONDS });
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare("INSERT OR REPLACE INTO billing_entries(token, email, expires_at, used_at) VALUES (?1, ?2, ?3, NULL)")
        .bind(token, normalized, expiresAt)
        .run();
    }

    return token;
  }

  async billingEntryByToken(token, { allowUsed = false } = {}) {
    if (this.kv) {
      const raw = await this.kv.get(`billing:${token}`);
      if (!raw) {
        return null;
      }
      const record = JSON.parse(raw);
      if (Number(record.expiresAt) < this.now()) {
        await this.kv.delete(`billing:${token}`);
        return null;
      }
      if (record.usedAt && !allowUsed) {
        return null;
      }
      return {
        email: normalize(record.email),
        expiresAt: Number(record.expiresAt),
        usedAt: record.usedAt ? Number(record.usedAt) : null,
      };
    }

    if (this.d1) {
      await this.ensureSchema();
      const row = await this.d1
        .prepare("SELECT email, expires_at, used_at FROM billing_entries WHERE token = ?1")
        .bind(token)
        .first();
      if (!row) {
        return null;
      }
      const expiresAt = Number(row.expires_at);
      if (expiresAt < this.now()) {
        await this.d1.prepare("DELETE FROM billing_entries WHERE token = ?1").bind(token).run();
        return null;
      }
      const usedAt = row.used_at == null ? null : Number(row.used_at);
      if (usedAt && !allowUsed) {
        return null;
      }
      return {
        email: normalize(row.email),
        expiresAt,
        usedAt,
      };
    }

    return null;
  }

  async markBillingEntryUsed(token) {
    const record = await this.billingEntryByToken(token, { allowUsed: true });
    if (!record) {
      return false;
    }

    const usedAt = this.now();

    if (this.kv) {
      await this.kv.put(`billing:${token}`, JSON.stringify({ ...record, usedAt }), {
        expirationTtl: billingEntryRecordTTL(record, this.now()),
      });
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare("UPDATE billing_entries SET used_at = ?2 WHERE token = ?1")
        .bind(token, usedAt)
        .run();
    }

    return true;
  }
}

function createStoreFromEnvironment(env, options) {
  const d1 = options.d1 ?? env?.ENTITLEMENTS_DB ?? env?.DB ?? null;
  const kv = options.kv ?? env?.ENTITLEMENTS_KV ?? env?.KV ?? null;
  if (d1 || kv) {
    return new D1KVEntitlementStore({ d1, kv, now: options.now ?? Date.now });
  }
  return new InMemoryEntitlementStore(options.now ?? Date.now);
}

export function createApp(store = null, options = {}) {
  const nowMillis = options.now ?? Date.now;
  const fetchImpl = options.fetchImpl ?? fetch;
  const stripeWebhookSecret = String(
    options.stripeWebhookSecret ?? options.env?.STRIPE_WEBHOOK_SECRET ?? "",
  ).trim();
  const parsedToleranceSeconds = Number.parseInt(
    options.webhookToleranceSeconds ?? options.env?.STRIPE_WEBHOOK_TOLERANCE_SECONDS ?? "300",
    10,
  );
  const webhookToleranceSeconds = Number.isFinite(parsedToleranceSeconds)
    ? parsedToleranceSeconds
    : 300;
  const enableDebugMagicLinkTokens = isEnabled(
    options.enableDebugMagicLinkTokens ?? options.env?.ENABLE_DEBUG_MAGIC_LINK_TOKEN,
  );

  const freePassEmails = new Set([
    ...hardCodedFreePassEmails.map((email) => normalize(email)).filter(Boolean),
    ...csvSet(options.freePassEmails ?? ""),
    ...csvSet(options.env?.FREE_PASS_EMAILS ?? ""),
  ]);

  const resolvedOptions = {
    nowMillis,
    fetchImpl,
    stripeWebhookSecret,
    webhookToleranceSeconds,
    enableDebugMagicLinkTokens,
    resendApiKey: options.resendApiKey ?? options.env?.RESEND_API_KEY ?? "",
    resendFromEmail: options.resendFromEmail ?? options.env?.RESEND_FROM_EMAIL ?? "",
    callbackScheme: options.callbackScheme ?? options.env?.DIRECT_APP_CALLBACK_SCHEME ?? "officeresume-direct",
    callbackHost: options.callbackHost ?? options.env?.DIRECT_VERIFY_REDIRECT_HOST ?? "auth",
    callbackPath: options.callbackPath ?? options.env?.DIRECT_VERIFY_REDIRECT_PATH ?? "/complete",
    stripeSecretKey: options.stripeSecretKey ?? options.env?.STRIPE_SECRET_KEY ?? "",
    stripeBillingReturnURL: options.stripeBillingReturnURL ?? options.env?.STRIPE_BILLING_RETURN_URL ?? "",
    stripePriceMonthly: options.stripePriceMonthly ?? options.env?.STRIPE_PRICE_MONTHLY ?? "",
    stripePriceYearly: options.stripePriceYearly ?? options.env?.STRIPE_PRICE_YEARLY ?? "",
    emailSender: options.emailSender,
    billingPortalFactory: options.billingPortalFactory,
    checkoutSessionFactory: options.checkoutSessionFactory,
  };

  let resolvedStore = store;

  async function ensureSession(request) {
    const sessionToken = parseBearerToken(request);
    if (!sessionToken) {
      return { error: jsonResponse({ error: "missing bearer token" }, 401) };
    }

    const session = await resolvedStore.sessionByToken(sessionToken);
    if (!session) {
      return { error: jsonResponse({ error: "invalid session" }, 401) };
    }

    return { session };
  }

  return async function fetchHandler(request, env = {}) {
    if (!resolvedStore) {
      resolvedStore = createStoreFromEnvironment(env, options);
    }

    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "POST" && path === "/auth/request-link") {
      const body = await parseRequestBody(request);
      const email = normalize(body.email);
      if (!email) {
        return jsonResponse({ error: "email is required" }, 400);
      }

      const token = await resolvedStore.createMagicLink(email);
      const verifyURL = new URL("/auth/verify", url.origin);
      verifyURL.searchParams.set("token", token);

      if (resolvedOptions.enableDebugMagicLinkTokens) {
        return jsonResponse({ ok: true, debugToken: token }, 202);
      }

      try {
        await sendMagicLinkEmail({
          email,
          verifyURL: verifyURL.toString(),
          options: { ...resolvedOptions, fetchImpl },
        });
      } catch (error) {
        return jsonResponse({ error: error.message || "failed to send email" }, 500);
      }

      return jsonResponse({ ok: true }, 202);
    }

    if (request.method === "POST" && path === "/auth/verify") {
      const body = await parseRequestBody(request);
      const token = typeof body.token === "string" ? body.token.trim() : "";
      if (!token) {
        return jsonResponse({ error: "token is required" }, 400);
      }

      const email = await resolvedStore.consumeMagicLink(token);
      if (!email) {
        return jsonResponse({ error: "invalid token" }, 401);
      }

      const sessionToken = await resolvedStore.createSession(email);
      await resolvedStore.ensureTrialStart(email);
      return jsonResponse({ ok: true, sessionToken, email }, 200);
    }

    if (request.method === "GET" && path === "/auth/verify") {
      const token = (url.searchParams.get("token") ?? "").trim();
      if (!token) {
        return jsonResponse({ error: "token is required" }, 400);
      }

      const email = await resolvedStore.consumeMagicLink(token);
      if (!email) {
        return jsonResponse({ error: "invalid token" }, 401);
      }

      const sessionToken = await resolvedStore.createSession(email);
      await resolvedStore.ensureTrialStart(email);
      const redirectURL = callbackURLForSession(email, sessionToken, resolvedOptions);
      return Response.redirect(redirectURL, 302);
    }

    if (request.method === "GET" && path === "/entitlements/current") {
      const authResult = await ensureSession(request);
      if (authResult.error) {
        return authResult.error;
      }

      const email = normalize(authResult.session.email);
      if (freePassEmails.has(email)) {
        return jsonResponse(activeFreePassEntitlement(nowMillis()), 200);
      }

      const subscription = await resolvedStore.subscriptionByEmail(email);
      if (subscription) {
        return jsonResponse(subscriptionToEntitlement(subscription, nowMillis()), 200);
      }

      const trialStart = await resolvedStore.ensureTrialStart(email);
      return jsonResponse(activeTrialEntitlement(trialStart, nowMillis()), 200);
    }

    if (request.method === "GET" && path === "/billing/entry") {
      const authResult = await ensureSession(request);
      if (authResult.error) {
        return authResult.error;
      }

      const email = normalize(authResult.session.email);
      if (freePassEmails.has(email)) {
        return new Response(null, { status: 204 });
      }

      const subscription = await resolvedStore.subscriptionByEmail(email);
      if (isPaidSubscription(subscription)) {
        if (subscription?.customerID) {
          try {
            const portalURL = await createStripeBillingPortalURL({
              customerID: subscription.customerID,
              options: { ...resolvedOptions, fetchImpl },
            });
            if (portalURL) {
              return jsonResponse({ kind: "manageSubscription", title: "Manage Subscription", url: portalURL }, 200);
            }
          } catch (error) {
            return jsonResponse({ error: error.message || "billing portal unavailable" }, 500);
          }
        }
        return new Response(null, { status: 204 });
      }

      if (!hasCheckoutConfiguration(resolvedOptions)) {
        return new Response(null, { status: 204 });
      }

      const entryToken = await resolvedStore.createBillingEntry(email);
      const pricingURL = new URL("/billing/pricing", url.origin);
      pricingURL.searchParams.set("entry", entryToken);
      return jsonResponse({ kind: "subscribe", title: "Choose Plan…", url: pricingURL.toString() }, 200);
    }

    if (request.method === "GET" && path === "/billing/pricing") {
      const entryToken = (url.searchParams.get("entry") ?? "").trim();
      if (!entryToken) {
        return renderFailurePage({
          title: "Pricing link unavailable",
          message: "Return to Office Resume and choose a plan again.",
          status: 400,
        });
      }

      const entryRecord = await resolvedStore.billingEntryByToken(entryToken);
      if (!entryRecord) {
        return renderFailurePage({
          title: "Pricing link expired",
          message: "Return to Office Resume and choose a plan again.",
          status: 401,
        });
      }

      const cancelled = (url.searchParams.get("cancelled") ?? "") === "1";
      return htmlResponse(renderPricingPage({ entryToken, cancelled }), 200);
    }

    if (request.method === "POST" && path === "/billing/checkout") {
      const body = await parseRequestBody(request);
      const entryToken = String(body.entry ?? "").trim();
      const plan = normalize(body.plan);
      if (!entryToken || !["monthly", "yearly"].includes(plan)) {
        return renderFailurePage({
          title: "Checkout unavailable",
          message: "Return to Office Resume and choose a plan again.",
          status: 400,
        });
      }

      const entryRecord = await resolvedStore.billingEntryByToken(entryToken);
      if (!entryRecord) {
        return renderFailurePage({
          title: "Checkout link expired",
          message: "Return to Office Resume and choose a plan again.",
          status: 401,
        });
      }

      const email = normalize(entryRecord.email);
      if (freePassEmails.has(email)) {
        return renderFailurePage({
          title: "Subscription not required",
          message: "This account already has free-pass access.",
          status: 409,
        });
      }

      const subscription = await resolvedStore.subscriptionByEmail(email);
      if (isPaidSubscription(subscription)) {
        return renderFailurePage({
          title: "Subscription already active",
          message: "Return to Office Resume and use Manage Subscription instead.",
          status: 409,
        });
      }

      const trialStart = await resolvedStore.ensureTrialStart(email);
      const trialConfig = computeStripeTrialConfig(trialStart, nowMillis());
      const successURL = new URL("/billing/checkout/success", url.origin);
      const cancelURL = new URL("/billing/checkout/cancel", url.origin);
      cancelURL.searchParams.set("entry", entryToken);

      let checkoutURL;
      try {
        checkoutURL = await createStripeCheckoutSessionURL({
          email,
          plan,
          trialConfig,
          successURL: successURL.toString(),
          cancelURL: cancelURL.toString(),
          options: { ...resolvedOptions, fetchImpl },
        });
      } catch (error) {
        return renderFailurePage({
          title: "Checkout unavailable",
          message: error.message || "Stripe Checkout is unavailable right now.",
          status: 503,
        });
      }

      if (!checkoutURL) {
        return renderFailurePage({
          title: "Checkout unavailable",
          message: "Stripe Checkout is not configured for this environment.",
          status: 503,
        });
      }

      await resolvedStore.markBillingEntryUsed(entryToken);
      return Response.redirect(checkoutURL, 303);
    }

    if (request.method === "GET" && path === "/billing/checkout/success") {
      const callbackURL = callbackURLForBillingRefresh(resolvedOptions);
      return renderCheckoutSuccessPage({ callbackURL });
    }

    if (request.method === "GET" && path === "/billing/checkout/cancel") {
      const entryToken = (url.searchParams.get("entry") ?? "").trim();
      if (!entryToken) {
        return renderFailurePage({
          title: "Checkout canceled",
          message: "Return to Office Resume and choose a plan again.",
          status: 200,
        });
      }

      const entryRecord = await resolvedStore.billingEntryByToken(entryToken, { allowUsed: true });
      if (!entryRecord) {
        return renderFailurePage({
          title: "Checkout canceled",
          message: "Return to Office Resume and choose a plan again.",
          status: 200,
        });
      }

      const replacementEntry = await resolvedStore.createBillingEntry(entryRecord.email);
      const pricingURL = new URL("/billing/pricing", url.origin);
      pricingURL.searchParams.set("entry", replacementEntry);
      pricingURL.searchParams.set("cancelled", "1");
      return Response.redirect(pricingURL.toString(), 302);
    }

    if (request.method === "POST" && path === "/webhooks/stripe") {
      const payload = await request.text();
      const isValidSignature = await verifyStripeWebhook(request, payload, {
        stripeWebhookSecret,
        webhookToleranceSeconds,
        nowMillis,
      });
      if (!isValidSignature) {
        return jsonResponse({ error: "invalid stripe signature" }, 401);
      }

      let event = null;
      try {
        event = JSON.parse(payload || "null");
      } catch {
        return jsonResponse({ error: "invalid webhook payload" }, 400);
      }
      if (!event || typeof event.type !== "string") {
        return jsonResponse({ error: "invalid webhook payload" }, 400);
      }

      if (event.type.startsWith("customer.subscription.")) {
        const object = event.data?.object ?? {};
        const email = extractCustomerEmail(object);

        if (email) {
          const interval = inferPlanFromStripeObject(object);
          const trialEndsAt = object.trial_end
            ? new Date(object.trial_end * 1000).toISOString()
            : null;
          const validUntil = object.current_period_end
            ? new Date(object.current_period_end * 1000).toISOString()
            : null;

          await resolvedStore.upsertSubscription(email, {
            status: object.status ?? "inactive",
            plan: interval,
            validUntil,
            trialEndsAt,
            customerID: extractCustomerID(object),
          });
        }
      }

      return jsonResponse({ received: true }, 200);
    }

    return jsonResponse({ error: "not found" }, 404);
  };
}

export default {
  async fetch(request, env, context) {
    if (!globalThis.__officeResumeWorkerApp) {
      globalThis.__officeResumeWorkerApp = createApp(null, { env });
    }
    return globalThis.__officeResumeWorkerApp(request, env, context);
  },
};
