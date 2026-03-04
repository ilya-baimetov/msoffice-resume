# Backend Worker Spec (`OfficeResumeBackend`)

## Scope
Direct-channel entitlement service for auth + subscription state.

## Owned Files
- `OfficeResumeBackend/src/**`
- `OfficeResumeBackend/test/**`
- `OfficeResumeBackend/package.json`

## Responsibilities
1. Provide magic-link auth endpoints.
2. Provide session-backed current entitlement endpoint.
3. Process Stripe webhook updates.
4. Support free-pass allowlist path (backend-authoritative).
5. Support persistence with D1/KV, with in-memory fallback for local tests.

## Endpoint Contract
- `POST /auth/request-link`
- `POST /auth/verify`
- `GET /entitlements/current`
- `POST /webhooks/stripe`

## Security Requirements
- Use cryptographically strong token generation for magic links and sessions.
- Verify Stripe webhook signatures when secret is configured.
- Enforce replay-window checks for webhook timestamps.
- Reject invalid bearer/session tokens.
- Normalize email identity fields consistently.

## Free-Pass Requirements
- Free-pass derives only from backend allowlist (`FREE_PASS_EMAILS`) and verified session identity.
- Response schema remains compatible with app entitlement parser.
- Do not provide unauthenticated free-pass activation paths.

## Persistence Requirements
- D1 tables (or equivalent model): magic links, sessions, subscriptions.
- KV keys (or equivalent model): temporary link/session/subscription mirrors.
- In-memory store allowed only for local/test fallback.

## Forbidden Changes
- Do not add analytics/event telemetry endpoints.
- Do not change entitlement response schema without updating shared specs/contracts.
- Do not add client-trust free-pass activation behavior.

## Component Acceptance Checks
- `npm test` passes.
- Webhook signature and replay validation are covered.
- Subscription updates are persisted and reflected in entitlement reads.
- Free-pass allowlist behavior is covered by tests.
