import test from "node:test";
import assert from "node:assert/strict";

import { createApp, InMemoryEntitlementStore } from "../src/worker.js";

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

test("magic link tokens use 256-bit hex format", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store);

  const firstLinkResponse = await app(new Request("https://example.com/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "token1@example.com" }),
  }));
  const secondLinkResponse = await app(new Request("https://example.com/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "token2@example.com" }),
  }));

  const firstLinkBody = await firstLinkResponse.json();
  const secondLinkBody = await secondLinkResponse.json();

  assert.match(firstLinkBody.token, /^[a-f0-9]{64}$/);
  assert.match(secondLinkBody.token, /^[a-f0-9]{64}$/);
  assert.notEqual(firstLinkBody.token, secondLinkBody.token);
});

test("auth flow returns trial entitlement by default", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store);

  const linkResponse = await app(new Request("https://example.com/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "user@example.com" }),
  }));

  assert.equal(linkResponse.status, 202);
  const linkBody = await linkResponse.json();
  assert.equal(linkBody.ok, true);
  assert.ok(linkBody.token);

  const verifyResponse = await app(new Request("https://example.com/auth/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: linkBody.token }),
  }));

  assert.equal(verifyResponse.status, 200);
  const verifyBody = await verifyResponse.json();
  assert.equal(verifyBody.ok, true);
  assert.ok(verifyBody.sessionToken);

  const entitlementResponse = await app(new Request("https://example.com/entitlements/current", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));

  assert.equal(entitlementResponse.status, 200);
  const entitlement = await entitlementResponse.json();
  assert.equal(entitlement.isActive, true);
  assert.equal(entitlement.plan, "trial");
});

test("stripe webhook updates current entitlement", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store);

  const linkResponse = await app(new Request("https://example.com/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "paid@example.com" }),
  }));
  const linkBody = await linkResponse.json();

  const verifyResponse = await app(new Request("https://example.com/auth/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: linkBody.token }),
  }));
  const verifyBody = await verifyResponse.json();

  const nowUnix = Math.floor(Date.now() / 1000);
  const webhookResponse = await app(new Request("https://example.com/webhooks/stripe", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      type: "customer.subscription.updated",
      data: {
        object: {
          customer_email: "paid@example.com",
          status: "active",
          interval: "month",
          current_period_end: nowUnix + 30 * 24 * 60 * 60,
        },
      },
    }),
  }));

  assert.equal(webhookResponse.status, 200);

  const entitlementResponse = await app(new Request("https://example.com/entitlements/current", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));

  const entitlement = await entitlementResponse.json();
  assert.equal(entitlement.isActive, true);
  assert.equal(entitlement.plan, "monthly");
  assert.ok(entitlement.validUntil);
});

test("free pass email bypasses billing checks", async () => {
  const store = new InMemoryEntitlementStore();
  const app = createApp(store, { freePassEmails: "vip@example.com" });

  const linkResponse = await app(new Request("https://example.com/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: "vip@example.com" }),
  }));
  const linkBody = await linkResponse.json();

  const verifyResponse = await app(new Request("https://example.com/auth/verify", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: linkBody.token }),
  }));
  const verifyBody = await verifyResponse.json();

  const entitlementResponse = await app(new Request("https://example.com/entitlements/current", {
    method: "GET",
    headers: { authorization: `Bearer ${verifyBody.sessionToken}` },
  }));
  const entitlement = await entitlementResponse.json();

  assert.equal(entitlement.isActive, true);
  assert.equal(entitlement.plan, "yearly");
  assert.equal(entitlement.freePass, true);
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
  const store = new InMemoryEntitlementStore();
  const fixedNow = Date.now();
  const webhookSecret = "whsec_test_valid";
  const app = createApp(store, {
    stripeWebhookSecret: webhookSecret,
    now: () => fixedNow,
  });

  const linkResponse = await app(
    new Request("https://example.com/auth/request-link", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ email: "sig@example.com" }),
    }),
  );
  const linkBody = await linkResponse.json();

  const verifyResponse = await app(
    new Request("https://example.com/auth/verify", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token: linkBody.token }),
    }),
  );
  const verifyBody = await verifyResponse.json();

  const nowUnix = Math.floor(fixedNow / 1000);
  const payload = JSON.stringify({
    type: "customer.subscription.updated",
    data: {
      object: {
        customer_details: { email: "sig@example.com" },
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
