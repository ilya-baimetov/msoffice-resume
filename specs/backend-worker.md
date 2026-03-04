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
4. Support free-pass email allowlist path.
5. Support persistence with D1/KV, with in-memory fallback for local tests.

## Endpoint Contract
- `POST /auth/request-link`
- `POST /auth/verify`
- `GET /entitlements/current`
- `POST /webhooks/stripe`

## Security Requirements
- Verify Stripe webhook signatures when secret configured.
- Reject invalid bearer/session tokens.
- Normalize email/device identity fields consistently.

## Persistence Requirements
- D1 tables (or equivalent model): magic links, sessions, subscriptions.
- KV keys (or equivalent model): temporary link/session/subscription mirrors.
- In-memory store allowed only for local/test fallback.

## Forbidden Changes
- Do not add analytics/event telemetry endpoints.
- Do not change entitlement response schema without updating shared contracts/spec.

## Component Acceptance Checks
- `npm test` passes.
- Webhook signature validation behavior is covered.
- Subscription updates are persisted and reflected in entitlement reads.
