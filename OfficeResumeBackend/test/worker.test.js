import test from "node:test";
import assert from "node:assert/strict";

import { createApp, D1KVEntitlementStore, InMemoryEntitlementStore } from "../src/worker.js";

function hex(buffer) {
  const bytes = new Uint8Array(buffer);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
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

  const signedPayload = `${timestamp}.${payload}`;
  const digest = await crypto.subtle.sign("HMAC", key, encoder.encode(signedPayload));
  return hex(digest);
}

function createMagicLinkApp(store, options = {}) {
  const sent = [];
  const app = createApp(store, {
    ...options,
    emailSender: async (payload) => {
      sent.push(payload);
      if (options.emailSender) {
        await options.emailSender(payload);
      }
    },
  });
  return { app, sent };
}

function backendRequestURL(externalURL, options = {}) {
  const url = new URL(externalURL);
  const apiBasePath = String(options.apiBasePath ?? "").trim();
  if (!apiBasePath) {
    return url.toString();
  }

  const normalized = apiBasePath.startsWith("/") ? apiBasePath : `/${apiBasePath}`;
  if (url.pathname === normalized || url.pathname.startsWith(`${normalized}/`)) {
    const suffix = url.pathname.slice(normalized.length) || "/";
    url.pathname = suffix.startsWith("/") ? suffix : `/${suffix}`;
  }

  return url.toString();
}

async function signInWithMagicLink(app, sent, email, options = {}) {
  const linkResponse = await app(new Request("https://example.com/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email }),
  }));
  const linkBody = await linkResponse.json();

  assert.equal(linkResponse.status, 202);
  assert.equal(linkBody.ok, true);
  assert.equal("debugToken" in linkBody, false);
  assert.ok(sent.length > 0);

  const verifyURL = sent[sent.length - 1].verifyURL;
  const verifyResponse = await app(new Request(backendRequestURL(verifyURL, options)));
  assert.equal(verifyResponse.status, 302);
  const location = verifyResponse.headers.get("location");
  const callbackURL = new URL(location);
  const verifyBody = {
    ok: true,
    sessionToken: callbackURL.searchParams.get("sessionToken"),
    email: callbackURL.searchParams.get("email"),
  };
  return { linkBody, verifyBody, location };
}

test("request-link sends email and does not expose the raw token", async () => {
  const store = new InMemoryEntitlementStore();
  const { app, sent } = createMagicLinkApp(store);

  const response = await app(new Request("https://example.com/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "debug@example.com" }),
  }));

  assert.equal(response.status, 202);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal("debugToken" in body, false);
  assert.equal(sent.length, 1);
  assert.match(sent[0].verifyURL, /\/auth\/verify\?token=/);
});

test("api base path prefixes generated auth and billing URLs", async () => {
  const store = new InMemoryEntitlementStore();
  const { app, sent } = createMagicLinkApp(store, {
    apiBasePath: "/api",
    checkoutSessionFactory: async () => "https://checkout.stripe.com/pay/cs_test",
  });

  const { verifyBody } = await signInWithMagicLink(app, sent, "prefixed@example.com", {
    apiBasePath: "/api",
  });
  assert.match(sent[0].verifyURL, /^https:\/\/example\.com\/api\/auth\/verify\?token=/);

  const entryResponse = await app(new Request("https://example.com/billing/entry", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  assert.equal(entryResponse.status, 200);
  const entryBody = await entryResponse.json();
  assert.match(entryBody.url, /^https:\/\/example\.com\/api\/billing\/pricing\?entry=/);

  const entryToken = new URL(entryBody.url).searchParams.get("entry");
  const pricingResponse = await app(new Request(`https://example.com/billing/pricing?entry=${entryToken}`));
  assert.equal(pricingResponse.status, 200);
  const pricingBody = await pricingResponse.text();
  assert.match(pricingBody, /action="\/api\/billing\/checkout"/);

  await store.markBillingEntryUsed(entryToken);
  const cancelResponse = await app(new Request(`https://example.com/billing/checkout/cancel?entry=${entryToken}`));
  assert.equal(cancelResponse.status, 302);
  assert.match(cancelResponse.headers.get("location"), /^https:\/\/example\.com\/api\/billing\/pricing\?entry=/);
});

test("auth flow returns a persistent 14-day trial window", async () => {
  let now = Date.UTC(2026, 0, 1);
  const store = new InMemoryEntitlementStore(() => now);
  const { app, sent } = createMagicLinkApp(store, { now: () => now });

  const { verifyBody } = await signInWithMagicLink(app, sent, "user@example.com");

  let entitlementResponse = await app(new Request("https://example.com/entitlements/current", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  let entitlement = await entitlementResponse.json();
  assert.equal(entitlement.isActive, true);
  assert.equal(entitlement.plan, "trial");
  const originalTrialEndsAt = entitlement.trialEndsAt;

  now += 5 * 24 * 60 * 60 * 1000;
  entitlementResponse = await app(new Request("https://example.com/entitlements/current", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  entitlement = await entitlementResponse.json();
  assert.equal(entitlement.trialEndsAt, originalTrialEndsAt);

  now += 10 * 24 * 60 * 60 * 1000;
  entitlementResponse = await app(new Request("https://example.com/entitlements/current", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  entitlement = await entitlementResponse.json();
  assert.equal(entitlement.isActive, false);
  assert.equal(entitlement.plan, "none");
  assert.equal(entitlement.trialEndsAt, originalTrialEndsAt);
});

test("free pass email bypasses billing checks only after verified auth", async () => {
  const store = new InMemoryEntitlementStore();
  const { app, sent } = createMagicLinkApp(store, {
    freePassEmails: "vip@example.com",
  });

  const { verifyBody } = await signInWithMagicLink(app, sent, "vip@example.com");

  const entitlementResponse = await app(new Request("https://example.com/entitlements/current", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  const entitlement = await entitlementResponse.json();

  assert.equal(entitlement.isActive, true);
  assert.equal(entitlement.plan, "yearly");
  assert.equal(entitlement.freePass, true);
});

test("billing entry requires a valid session and returns a pricing page URL for signed-in non-paid users", async () => {
  const store = new InMemoryEntitlementStore();
  const { app, sent } = createMagicLinkApp(store, {
    checkoutSessionFactory: async () => "https://checkout.stripe.com/pay/cs_test",
  });

  const unauthorizedResponse = await app(new Request("https://example.com/billing/entry", {
    method: "GET",
  }));
  assert.equal(unauthorizedResponse.status, 401);

  const { verifyBody } = await signInWithMagicLink(app, sent, "billable@example.com");
  const response = await app(new Request("https://example.com/billing/entry", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.kind, "subscribe");
  assert.equal(body.title, "Choose Plan…");
  assert.match(body.url, /^https:\/\/example\.com\/billing\/pricing\?entry=/);
});

test("billing entry returns no action for free-pass users", async () => {
  const store = new InMemoryEntitlementStore();
  const { app, sent } = createMagicLinkApp(store, {
    freePassEmails: "vip@example.com",
    checkoutSessionFactory: async () => "https://checkout.stripe.com/pay/cs_test",
  });

  const { verifyBody } = await signInWithMagicLink(app, sent, "vip@example.com");
  const response = await app(new Request("https://example.com/billing/entry", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));

  assert.equal(response.status, 204);
});

test("pricing page requires a valid entry token and renders both plans", async () => {
  const store = new InMemoryEntitlementStore();
  const entryToken = await store.createBillingEntry("pricing@example.com");
  const app = createApp(store, {
    checkoutSessionFactory: async () => "https://checkout.stripe.com/pay/cs_test",
  });

  const response = await app(new Request(`https://example.com/billing/pricing?entry=${entryToken}`));
  assert.equal(response.status, 200);
  const body = await response.text();
  assert.match(body, /Continue with Monthly/);
  assert.match(body, /Continue with Yearly/);

  const invalidResponse = await app(new Request("https://example.com/billing/pricing?entry=bad-token"));
  assert.equal(invalidResponse.status, 401);
});

test("checkout endpoint rejects invalid or expired billing entries", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store, {
    checkoutSessionFactory: async () => "https://checkout.stripe.com/pay/cs_test",
  });

  const response = await app(new Request("https://example.com/billing/checkout", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ entry: "bad-token", plan: "monthly" }).toString(),
  }));

  assert.equal(response.status, 401);
});

test("checkout endpoint creates a checkout session with verified email and remaining trial", async () => {
  let now = Date.UTC(2026, 0, 1);
  const store = new InMemoryEntitlementStore(() => now);
  const captured = [];
  const { app, sent } = createMagicLinkApp(store, {
    now: () => now,
    checkoutSessionFactory: async (payload) => {
      captured.push(payload);
      return "https://checkout.stripe.com/pay/cs_test_123";
    },
  });

  const { verifyBody } = await signInWithMagicLink(app, sent, "trialing@example.com");
  const entryResponse = await app(new Request("https://example.com/billing/entry", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  const entryBody = await entryResponse.json();
  const entryToken = new URL(entryBody.url).searchParams.get("entry");

  const response = await app(new Request("https://example.com/billing/checkout", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ entry: entryToken, plan: "yearly" }).toString(),
  }));

  assert.equal(response.status, 303);
  assert.equal(response.headers.get("location"), "https://checkout.stripe.com/pay/cs_test_123");
  assert.equal(captured.length, 1);
  assert.equal(captured[0].email, "trialing@example.com");
  assert.equal(captured[0].plan, "yearly");
  assert.ok(captured[0].trialConfig);
  assert.ok(captured[0].trialConfig.trialEnd || captured[0].trialConfig.trialPeriodDays);
});

test("checkout endpoint rounds short remaining trial into Stripe-supported trial settings", async () => {
  let now = Date.UTC(2026, 0, 1);
  const store = new InMemoryEntitlementStore(() => now);
  const captured = [];
  const { app, sent } = createMagicLinkApp(store, {
    now: () => now,
    checkoutSessionFactory: async (payload) => {
      captured.push(payload);
      return "https://checkout.stripe.com/pay/cs_short_trial";
    },
  });

  const { verifyBody } = await signInWithMagicLink(app, sent, "almostdone@example.com");
  now += 13.5 * 24 * 60 * 60 * 1000;

  const entryResponse = await app(new Request("https://example.com/billing/entry", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  const entryBody = await entryResponse.json();
  const entryToken = new URL(entryBody.url).searchParams.get("entry");

  const response = await app(new Request("https://example.com/billing/checkout", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ entry: entryToken, plan: "monthly" }).toString(),
  }));

  assert.equal(response.status, 303);
  assert.equal(captured.length, 1);
  assert.equal(captured[0].trialConfig?.trialPeriodDays, 1);
});

test("checkout success page deep-links back into the app", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store, {
    callbackScheme: "officeresume-direct",
    callbackHost: "auth",
    callbackPath: "/complete",
  });

  const response = await app(new Request("https://example.com/billing/checkout/success"));
  assert.equal(response.status, 200);
  const body = await response.text();
  assert.match(body, /officeresume-direct:\/\/auth\/complete\?action=billingRefresh/);
});

test("checkout cancel route redirects back to pricing with a fresh token and cancel state", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store, {
    checkoutSessionFactory: async () => "https://checkout.stripe.com/pay/cs_cancel",
  });

  const originalEntry = await store.createBillingEntry("cancel@example.com");
  await store.markBillingEntryUsed(originalEntry);

  const response = await app(new Request(`https://example.com/billing/checkout/cancel?entry=${originalEntry}`));
  assert.equal(response.status, 302);
  const location = response.headers.get("location");
  assert.match(location, /^https:\/\/example\.com\/billing\/pricing\?entry=/);
  assert.match(location, /cancelled=1/);
  assert.ok(!location.includes(originalEntry));
});

test("paid users receive a manage-subscription billing action backed by the portal", async () => {
  const store = new InMemoryEntitlementStore();
  await store.upsertSubscription("paid@example.com", {
    status: "active",
    plan: "monthly",
    validUntil: new Date(Date.UTC(2026, 0, 20)).toISOString(),
    customerID: "cus_paid_123",
  });

  const { app, sent } = createMagicLinkApp(store, {
    billingPortalFactory: async () => "https://billing.stripe.com/session/test_portal",
  });

  const { verifyBody } = await signInWithMagicLink(app, sent, "paid@example.com");
  const response = await app(new Request("https://example.com/billing/entry", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.kind, "manageSubscription");
  assert.equal(body.title, "Manage Subscription");
  assert.equal(body.url, "https://billing.stripe.com/session/test_portal");
});

test("stripe webhook rejects invalid signatures when secret is configured", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store, { stripeWebhookSecret: "whsec_test" });

  const response = await app(
    new Request("https://example.com/webhooks/stripe", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "customer.subscription.updated", data: { object: {} } }),
    }),
  );

  assert.equal(response.status, 401);
  const body = await response.json();
  assert.equal(body.error, "invalid stripe signature");
});

test("stripe webhook accepts valid signatures and updates entitlement", async () => {
  const fixedNow = Date.now();
  const store = new InMemoryEntitlementStore(() => fixedNow);
  const webhookSecret = "whsec_test_valid";
  const { app, sent } = createMagicLinkApp(store, {
    stripeWebhookSecret: webhookSecret,
    now: () => fixedNow,
  });

  const { verifyBody } = await signInWithMagicLink(app, sent, "sig@example.com");

  const nowUnix = Math.floor(fixedNow / 1000);
  const payload = JSON.stringify({
    type: "customer.subscription.updated",
    data: {
      object: {
        metadata: { email: "sig@example.com" },
        customer: "cus_123",
        status: "active",
        items: {
          data: [
            {
              price: {
                recurring: {
                  interval: "year",
                },
              },
            },
          ],
        },
        current_period_end: nowUnix + 30 * 24 * 60 * 60,
      },
    },
  });

  const signature = await stripeSignature(webhookSecret, nowUnix, payload);
  const webhookResponse = await app(
    new Request("https://example.com/webhooks/stripe", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "stripe-signature": `t=${nowUnix},v1=${signature}`,
      },
      body: payload,
    }),
  );
  assert.equal(webhookResponse.status, 200);

  const entitlementResponse = await app(
    new Request("https://example.com/entitlements/current", {
      method: "GET",
      headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
    }),
  );
  const entitlement = await entitlementResponse.json();

  assert.equal(entitlement.isActive, true);
  assert.equal(entitlement.plan, "yearly");
  assert.ok(entitlement.validUntil);
});

test("magic link verify endpoint redirects to app callback URL", async () => {
  const store = new InMemoryEntitlementStore();
  const { app, sent } = createMagicLinkApp(store, {
    callbackScheme: "officeresume-direct",
    callbackHost: "auth",
    callbackPath: "/complete",
  });

  const { location } = await signInWithMagicLink(app, sent, "callback@example.com");
  assert.match(location, /^officeresume-direct:\/\/auth\/complete\?/);
  assert.match(location, /sessionToken=/);
  assert.match(location, /email=callback%40example.com/);
});

test("d1 schema bootstrap executes individual create table statements", async () => {
  const executed = [];
  const d1 = {
    async exec(statement) {
      executed.push(String(statement).trim());
    },
    prepare() {
      return {
        bind() {
          return {
            async run() {
              return { success: true };
            },
          };
        },
      };
    },
  };

  const store = new D1KVEntitlementStore({ d1 });
  await store.createMagicLink("d1@example.com");

  assert.equal(executed.length, 5);
  assert.match(executed[0], /^CREATE TABLE IF NOT EXISTS magic_links/);
  assert.match(executed[4], /^CREATE TABLE IF NOT EXISTS billing_entries/);
});
