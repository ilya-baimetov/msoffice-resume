const JSON_HEADERS = { "content-type": "application/json" };

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: JSON_HEADERS,
  });
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
  for (let i = 0; i < left.length; i += 1) {
    result |= left.charCodeAt(i) ^ right.charCodeAt(i);
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

export class InMemoryEntitlementStore {
  constructor() {
    this.magicLinks = new Map();
    this.sessions = new Map();
    this.subscriptions = new Map();
  }

  createMagicLink(email) {
    const token = randomToken();
    const expiresAt = Date.now() + 15 * 60 * 1000;
    this.magicLinks.set(token, { email, expiresAt });
    return token;
  }

  consumeMagicLink(token) {
    const record = this.magicLinks.get(token);
    if (!record) {
      return null;
    }
    this.magicLinks.delete(token);
    if (record.expiresAt < Date.now()) {
      return null;
    }
    return record.email;
  }

  createSession(email) {
    const token = randomToken();
    this.sessions.set(token, { email, createdAt: Date.now() });
    return token;
  }

  sessionByToken(token) {
    return this.sessions.get(token) ?? null;
  }

  upsertSubscription(email, subscription) {
    this.subscriptions.set(email, subscription);
  }

  subscriptionByEmail(email) {
    return this.subscriptions.get(email) ?? null;
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
        trial_ends_at TEXT
      );
    `);
    this.schemaReady = true;
  }

  async createMagicLink(email) {
    const token = randomToken();
    const expiresAt = this.now() + 15 * 60 * 1000;
    const record = { email, expiresAt };

    if (this.kv) {
      await this.kv.put(`magic:${token}`, JSON.stringify(record), { expirationTtl: 15 * 60 });
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare("INSERT OR REPLACE INTO magic_links(token, email, expires_at) VALUES (?1, ?2, ?3)")
        .bind(token, email, expiresAt)
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
      return record.email;
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
    const token = randomToken();
    const createdAt = this.now();
    const record = { email, createdAt };

    if (this.kv) {
      await this.kv.put(`session:${token}`, JSON.stringify(record), { expirationTtl: 90 * 24 * 60 * 60 });
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare("INSERT OR REPLACE INTO sessions(token, email, created_at) VALUES (?1, ?2, ?3)")
        .bind(token, email, createdAt)
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
      return JSON.parse(raw);
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
      return {
        email: normalize(row.email),
        createdAt: Number(row.created_at ?? this.now()),
      };
    }

    return null;
  }

  async upsertSubscription(email, subscription) {
    const payload = {
      status: subscription.status ?? "inactive",
      plan: subscription.plan ?? "monthly",
      validUntil: subscription.validUntil ?? null,
      trialEndsAt: subscription.trialEndsAt ?? null,
    };

    if (this.kv) {
      await this.kv.put(`sub:${normalize(email)}`, JSON.stringify(payload));
    }

    if (this.d1) {
      await this.ensureSchema();
      await this.d1
        .prepare(
          `
          INSERT INTO subscriptions(email, status, plan, valid_until, trial_ends_at)
          VALUES (?1, ?2, ?3, ?4, ?5)
          ON CONFLICT(email) DO UPDATE SET
            status = excluded.status,
            plan = excluded.plan,
            valid_until = excluded.valid_until,
            trial_ends_at = excluded.trial_ends_at
          `,
        )
        .bind(normalize(email), payload.status, payload.plan, payload.validUntil, payload.trialEndsAt)
        .run();
    }
  }

  async subscriptionByEmail(email) {
    if (this.kv) {
      const raw = await this.kv.get(`sub:${normalize(email)}`);
      if (!raw) {
        return null;
      }
      return JSON.parse(raw);
    }

    if (this.d1) {
      await this.ensureSchema();
      const row = await this.d1
        .prepare("SELECT status, plan, valid_until, trial_ends_at FROM subscriptions WHERE email = ?1")
        .bind(normalize(email))
        .first();
      if (!row) {
        return null;
      }
      return {
        status: row.status,
        plan: row.plan,
        validUntil: row.valid_until ?? null,
        trialEndsAt: row.trial_ends_at ?? null,
      };
    }

    return null;
  }
}

function activeTrialEntitlement() {
  const now = Date.now();
  const trialEndsAt = new Date(now + 14 * 24 * 60 * 60 * 1000).toISOString();
  return {
    isActive: true,
    plan: "trial",
    validUntil: trialEndsAt,
    trialEndsAt,
  };
}

function activeFreePassEntitlement() {
  const now = Date.now();
  const validUntil = new Date(now + 10 * 365 * 24 * 60 * 60 * 1000).toISOString();
  return {
    isActive: true,
    plan: "yearly",
    validUntil,
    trialEndsAt: null,
    freePass: true,
  };
}

function subscriptionToEntitlement(subscription) {
  if (!subscription) {
    return activeTrialEntitlement();
  }

  return {
    isActive: subscription.status === "active" || subscription.status === "trialing",
    plan: subscription.plan,
    validUntil: subscription.validUntil,
    trialEndsAt: subscription.trialEndsAt ?? null,
  };
}

function createStoreFromEnvironment(env, options) {
  const d1 = options.d1 ?? env?.ENTITLEMENTS_DB ?? env?.DB ?? null;
  const kv = options.kv ?? env?.ENTITLEMENTS_KV ?? env?.KV ?? null;
  if (d1 || kv) {
    return new D1KVEntitlementStore({ d1, kv, now: options.now ?? Date.now });
  }
  return new InMemoryEntitlementStore();
}

export function createApp(store = null, options = {}) {
  const nowMillis = options.now ?? Date.now;
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

  const freePassEmails = new Set([
    ...csvSet(options.freePassEmails ?? ""),
    ...csvSet(options.env?.FREE_PASS_EMAILS ?? ""),
  ]);

  let resolvedStore = store;

  return async function fetch(request, env = {}) {
    if (!resolvedStore) {
      resolvedStore = createStoreFromEnvironment(env, options);
    }

    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "POST" && path === "/auth/request-link") {
      const body = await request.json().catch(() => ({}));
      const email = normalize(body.email);
      if (!email) {
        return jsonResponse({ error: "email is required" }, 400);
      }

      const token = await resolvedStore.createMagicLink(email);
      return jsonResponse({ ok: true, token }, 202);
    }

    if (request.method === "POST" && path === "/auth/verify") {
      const body = await request.json().catch(() => ({}));
      const token = typeof body.token === "string" ? body.token.trim() : "";
      if (!token) {
        return jsonResponse({ error: "token is required" }, 400);
      }

      const email = await resolvedStore.consumeMagicLink(token);
      if (!email) {
        return jsonResponse({ error: "invalid token" }, 401);
      }

      const sessionToken = await resolvedStore.createSession(email);
      return jsonResponse({ ok: true, sessionToken }, 200);
    }

    if (request.method === "GET" && path === "/entitlements/current") {
      const sessionToken = parseBearerToken(request);
      if (!sessionToken) {
        return jsonResponse({ error: "missing bearer token" }, 401);
      }

      const session = await resolvedStore.sessionByToken(sessionToken);
      if (!session) {
        return jsonResponse({ error: "invalid session" }, 401);
      }

      if (freePassEmails.has(normalize(session.email))) {
        return jsonResponse(activeFreePassEntitlement(), 200);
      }

      const subscription = await resolvedStore.subscriptionByEmail(session.email);
      return jsonResponse(subscriptionToEntitlement(subscription), 200);
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
