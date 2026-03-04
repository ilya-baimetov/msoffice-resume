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
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
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

export function createApp(store = new InMemoryEntitlementStore(), options = {}) {
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

  return async function fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "POST" && path === "/auth/request-link") {
      const body = await request.json().catch(() => ({}));
      const email = normalize(body.email);
      if (!email) {
        return jsonResponse({ error: "email is required" }, 400);
      }

      const token = store.createMagicLink(email);
      return jsonResponse({ ok: true, token }, 202);
    }

    if (request.method === "POST" && path === "/auth/verify") {
      const body = await request.json().catch(() => ({}));
      const token = typeof body.token === "string" ? body.token.trim() : "";
      if (!token) {
        return jsonResponse({ error: "token is required" }, 400);
      }

      const email = store.consumeMagicLink(token);
      if (!email) {
        return jsonResponse({ error: "invalid token" }, 401);
      }

      const sessionToken = store.createSession(email);
      return jsonResponse({ ok: true, sessionToken }, 200);
    }

    if (request.method === "GET" && path === "/entitlements/current") {
      const sessionToken = parseBearerToken(request);
      if (!sessionToken) {
        return jsonResponse({ error: "missing bearer token" }, 401);
      }

      const session = store.sessionByToken(sessionToken);
      if (!session) {
        return jsonResponse({ error: "invalid session" }, 401);
      }

      if (freePassEmails.has(normalize(session.email))) {
        return jsonResponse(activeFreePassEntitlement(), 200);
      }

      const subscription = store.subscriptionByEmail(session.email);
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

          store.upsertSubscription(email, {
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

const app = createApp();

export default {
  fetch: app,
};
