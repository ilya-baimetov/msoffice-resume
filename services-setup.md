# Services Setup Guide (Direct + MAS)

This guide explains how to set up all external services for `Office Resume`, with a **Direct-only path that does not require Apple Developer**.

## 1. Choose Your Track

### Track A: Direct-only (no Apple Developer account required)
Use this if you want to:
- run locally,
- test with selected users,
- test billing through Stripe/Cloudflare,
- avoid App Store work for now.

### Track B: MAS + Direct
Use this if you also want App Store distribution and StoreKit billing.

## 2. Common Prerequisites

1. Install Xcode 15+.
2. Install Xcode command line tools:
```bash
xcode-select --install
```
3. Install XcodeGen:
```bash
brew install xcodegen
```
4. Install Node 20+:
```bash
brew install node
```
5. In repo root, generate project and run tests:
```bash
cd /Users/ilya.baimetov/Projects/msoffice-resume
xcodegen generate
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeMAS -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build test
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeDirect -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build test
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeHelper -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
6. Backend tests:
```bash
cd /Users/ilya.baimetov/Projects/msoffice-resume/OfficeResumeBackend
npm test
```

## 3. Direct-Only Local Mode (No Apple Developer Required)

### 3.1 What works without Apple Developer
- Building and running helper + menu bar app from Xcode.
- Running backend locally.
- Testing direct entitlement flow.
- Enabling "free pass" users.

### 3.2 What does not fully work without Apple Developer
- App Store Connect distribution.
- StoreKit production flow.
- Notarized public DMG/ZIP for zero-friction external install.

You can still share a direct build privately; users may need Gatekeeper bypass steps.

### 3.3 Enable local entitlement bypass for development
Set `OFFICE_RESUME_LOCAL_MODE=1` in Xcode scheme environment variables (both app and helper schemes you run).

When enabled:
- monitoring and restore stay active,
- entitlement is treated as active (free-pass yearly state),
- no payment required.

## 4. Free Pass for Selected People

There are two free-pass controls:
1. **App-side override** (for local app behavior).
2. **Backend email allowlist** (for direct entitlement API).

### 4.1 App-side free pass via config file
Create this file on each tester machine:

`~/Library/Application Support/com.pragprod.msofficeresume/entitlements/free-pass-v1.json`

Example:
```json
{
  "localModeEnabled": false,
  "freePassDeviceIDs": [
    "ilya@ilya-macbook-pro",
    "qa1@qa-mac-mini"
  ],
  "freePassEmails": [
    "ilya@example.com",
    "qa1@example.com"
  ]
}
```

Notes:
- `localModeEnabled=true` gives all users on that machine a free pass.
- `freePassDeviceIDs` and `freePassEmails` are exact-match, case-insensitive.

### 4.2 App-side free pass via environment variables
Alternative (good for local dev in Xcode):
- `OFFICE_RESUME_LOCAL_MODE=1`
- `OFFICE_RESUME_DEVICE_ID=<custom-id>`
- `OFFICE_RESUME_USER_EMAIL=<tester@email>`
- `OFFICE_RESUME_FREE_PASS_DEVICE_IDS=id1,id2`
- `OFFICE_RESUME_FREE_PASS_EMAILS=a@b.com,c@d.com`

### 4.3 Backend free pass via email allowlist
Set on Cloudflare Worker env/secrets:
- `FREE_PASS_EMAILS=vip1@example.com,vip2@example.com`

When an authenticated session email is in this list, `/entitlements/current` returns active free-pass entitlement.

## 5. Stripe Setup (Direct Billing)

1. Create Stripe account.
2. Create products/prices:
- monthly: `$5/month`
- yearly: `$50/year`
3. Configure trial:
- `trial_period_days=14` on both prices/subscriptions.
4. Generate keys:
- publishable key,
- secret key,
- webhook signing secret.
5. Configure webhook to Worker endpoint:
- `POST /webhooks/stripe`
- events: `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`.

## 6. Cloudflare Setup (Direct Entitlements)

1. Create Cloudflare account.
2. Install Wrangler:
```bash
npm install -g wrangler
```
3. Login:
```bash
wrangler login
```
4. Create Worker and deploy backend code under `OfficeResumeBackend`.
5. Create D1 database and KV namespace (for production state, sessions, caches).
6. Configure Worker secrets/env:
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `FREE_PASS_EMAILS` (optional)
- `MAGIC_LINK_SIGNING_SECRET`

7. Publish Worker and note base URL.

## 7. Apple Developer + MAS Setup (Optional if Direct-only)

Do this only if you want App Store path now.

1. Enroll in Apple Developer Program.
2. In Certificates/Identifiers:
- App IDs:
  - `com.pragprod.msofficeresume.mas`
  - `com.pragprod.msofficeresume.helper`
- App Group:
  - `group.com.pragprod.msofficeresume`
3. App Store Connect:
- create app record,
- create subscription group,
- products:
  - `officeresume.monthly`
  - `officeresume.yearly`
- both with 14-day intro trial,
- create Sandbox testers.

## 8. Local Run Workflow

### 8.1 Build and run
Fastest path (build + package + installer):
```bash
cd /Users/ilya.baimetov/Projects/msoffice-resume
./scripts/package-local-free-pass.sh
./dist/local-free-pass/install-local-free-pass.sh
```

Manual path:
1. Start helper scheme once (`OfficeResumeHelper`).
2. Start app scheme (`OfficeResumeDirect` preferred for direct testing).
3. Confirm menu bar icon appears.
4. Confirm helper connection status is green.

### 8.2 Validate free pass quickly
1. Set `OFFICE_RESUME_LOCAL_MODE=1` in scheme env.
2. Relaunch helper + app.
3. In menu bar app, entitlement should show active.
4. Restore/polling actions should remain enabled.

### 8.3 Validate backend free pass
1. Add tester email to `FREE_PASS_EMAILS`.
2. Complete auth flow with that email.
3. Call `GET /entitlements/current`.
4. Verify response includes active `yearly` free-pass entitlement.

## 9. Sharing Direct Builds Privately (Without Apple Developer)

For internal testers only:
1. Build `OfficeResumeDirect.app` locally.
2. Zip and share.
3. On tester machine, if blocked by Gatekeeper:
```bash
xattr -dr com.apple.quarantine /path/to/OfficeResumeDirect.app
```

This is acceptable for private testing but not ideal for public distribution.

## 10. Recommended Order From Here

1. Finish Direct-only local validation first.
2. Set up Stripe + Cloudflare and verify API flow.
3. Enable free pass for your internal testers.
4. Add Apple Developer/App Store only when you want MAS release.

For release hardening details, see:

- `docs/local-functional-checklist.md`
- `docs/release-hardening.md`
