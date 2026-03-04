# Direct Distribution Hardening (Signing, Notarization, Paid Flow)

This document defines the minimum hardening path before broad external distribution.

## 1) Build and Package for Direct Distribution

Use:

```bash
./scripts/release-direct.sh
```

Output:

- `dist/release-direct/`
- `dist/OfficeResume-direct-unsigned.zip`

## 2) Sign With Developer ID

Set environment variable:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: <Company> (<TEAMID>)"
```

Then rerun:

```bash
./scripts/release-direct.sh
```

The script signs:

- `OfficeResumeHelper.app`
- `OfficeResumeDirect.app`
- nested framework binaries

Verification is performed via `codesign --verify --deep --strict`.

## 3) Notarize

Store notary credentials once:

```bash
xcrun notarytool store-credentials office-resume-notary \
  --apple-id "<apple-id>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

Run with profile:

```bash
export NOTARYTOOL_PROFILE="office-resume-notary"
./scripts/release-direct.sh
```

Output:

- `dist/OfficeResume-direct-signed.zip` (signed + notarized + stapled)

## 4) Backend Paid-Flow Hardening

Current backend protections in place:

- Stripe webhook signature verification (`Stripe-Signature`) when `STRIPE_WEBHOOK_SECRET` is configured.
- Replay window enforcement (`STRIPE_WEBHOOK_TOLERANCE_SECONDS`, default 300s).
- Free-pass allowlist override via `FREE_PASS_EMAILS`.

Recommended Worker env:

- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `MAGIC_LINK_SIGNING_SECRET`
- `FREE_PASS_EMAILS` (optional)
- `STRIPE_WEBHOOK_TOLERANCE_SECONDS` (optional)

## 5) Paid Flow End-to-End Validation Plan

1. Auth flow
- Request magic link and verify session token.
- Fetch `/entitlements/current`.
- Expected for new user: active `trial` entitlement.

2. Stripe billing transition
- Create test subscription in Stripe.
- Deliver signed webhook to `/webhooks/stripe`.
- Fetch `/entitlements/current` again.
- Expected: active `monthly` or `yearly` with updated `validUntil`.

3. Cancellation/expiry
- Trigger `customer.subscription.deleted`.
- Fetch entitlement.
- Expected: inactive or trial fallback according to policy.

4. Offline grace app behavior
- Disconnect network after valid entitlement cache is written.
- Expected: restore/monitor remains active for up to 7 days, then disables.

5. Free-pass allowlist
- Add test email to `FREE_PASS_EMAILS`.
- Fetch entitlement after auth.
- Expected: active yearly free-pass without billing.

## 6) Release Gate Before Public Rollout

- Local checklist in `docs/local-functional-checklist.md` fully passed.
- `xcodebuild` MAS + Direct tests green.
- `npm test` backend tests green.
- Signed and notarized direct bundle produced.
- Stripe webhook signature checks validated in staging.
