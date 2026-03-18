# Backend Worker Spec (`OfficeResumeBackend`)

## Scope
Direct-channel auth, subscription, billing-portal, and entitlement service mounted inside the unified `office-resume` Cloudflare Worker.

## Owned Files
- `OfficeResumeBackend/src/**`
- `OfficeResumeBackend/test/**`
- `OfficeResumeBackend/package.json`

## Responsibilities
1. Provide magic-link auth endpoints.
2. Provide session-backed current entitlement endpoint.
3. Provide authenticated billing entry resolution, Worker-hosted pricing, Stripe Checkout Session creation, and billing-portal URL endpoint.
4. Process Stripe webhook updates.
5. Support backend-authoritative free-pass allowlist.
6. Support persistence with D1/KV, with in-memory fallback for local tests.
7. Deliver production sign-in emails through Resend.
8. Support deployment behind the shared Worker `/api` base path without generating broken root-relative URLs.

## Endpoint Contract
External routes on the shared Worker:
- `POST /api/auth/request-link`
- `GET /api/auth/verify`
- `GET /api/entitlements/current`
- `GET /api/billing/entry`
- `GET /api/billing/pricing`
- `POST /api/billing/checkout`
- `GET /api/billing/checkout/success`
- `GET /api/billing/checkout/cancel`
- `POST /api/webhooks/stripe`

Internal handler contract after the Worker strips `/api`:
- `POST /auth/request-link`
- `GET /auth/verify`
- `GET /entitlements/current`
- `GET /billing/entry`
- `GET /billing/pricing`
- `POST /billing/checkout`
- `GET /billing/checkout/success`
- `GET /billing/checkout/cancel`
- `POST /webhooks/stripe`

## Auth Requirements
- Normalize email before storage/lookup.
- `POST /auth/request-link`:
  - create token, store it, send email, return `202 { ok: true }`
- `GET /auth/verify` validates token, creates session, and redirects to app custom URL scheme.
- Session responses may include email metadata for the client account UI.

## Trial and Subscription Requirements
- Persist one trial start timestamp per normalized verified email.
- First verified sign-in starts the 14-day trial.
- Repeated entitlement reads reuse the same trial window.
- Paid Stripe subscription state overrides trial state normally.
- Subscription storage must retain enough information to create/manage Stripe billing portal sessions.
- Signed-in, non-paid users use Worker-hosted pricing plus Stripe Checkout Sessions for monthly/yearly purchases.
- Checkout must convert remaining trial time into Stripe-supported subscription-trial settings.
- Existing paid users use Stripe Billing Portal instead of Checkout.

## Security Requirements
- Use cryptographically strong token generation for magic links and sessions.
- Production `request-link` must not expose raw verification tokens.
- Verify Stripe webhook signatures when secret is configured.
- Enforce replay-window checks for webhook timestamps.
- Reject invalid bearer/session tokens.
- Normalize email identity fields consistently.

## Free-Pass Requirements
- Free-pass derives only from backend allowlist and verified session identity.
- Support a checked-in hard-coded allowlist file plus env-based additions.
- Response schema remains compatible with app entitlement parser.
- Do not provide unauthenticated free-pass activation paths.

## Persistence Requirements
- D1 tables (or equivalent model): magic links, sessions, subscriptions, trials, and short-lived billing entry tokens.
- KV keys (or equivalent model): temporary link/session/subscription/trial/billing-entry mirrors.
- In-memory store allowed only for local/test fallback.

## Shared-Worker Routing Requirements
- The canonical Worker name is `office-resume`.
- Static site assets are served by the same Worker from `site/`.
- The backend is mounted under `/api/*`.
- Worker-generated links, form actions, and redirects must preserve the `/api` prefix externally.

## Forbidden Changes
- Do not add analytics/event telemetry endpoints.
- Do not change entitlement response schema without updating shared specs/contracts.
- Do not add client-trust free-pass activation behavior.
- Do not add local-only token or sign-in shortcuts that bypass the normal email verification flow.

## Component Acceptance Checks
- `npm test` passes.
- Production `request-link` returns no raw token.
- Trial persistence is covered by tests.
- Webhook signature and replay validation are covered.
- Billing entry, pricing page, Checkout Session creation, and billing portal behavior are covered.
- Free-pass allowlist behavior is covered by tests.
