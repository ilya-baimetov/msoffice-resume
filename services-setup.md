# Services Setup Guide (Direct + MAS)

This guide covers all external setup for Office Resume, including a Direct path that works without an Apple Developer account.

## 1. Choose Your Distribution Track

### Track A: Direct-only (no Apple Developer account required)
Use this for local development/testing and private direct distribution.

### Track B: MAS + Direct
Use this when you are ready to ship through App Store and Direct in parallel.

## 2. Common Local Prerequisites

1. Install Xcode 15+ (Xcode 16.2 recommended).
2. Install command line tools:

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

5. Generate Xcode project and run baseline checks:

```bash
cd ~/Projects/msoffice-resume
xcodegen generate
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeMAS -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build test
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeDirect -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build test
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeHelper -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
./scripts/eval-docs-consistency.sh
./scripts/eval-ui-guardrails.sh
```

6. Backend checks:

```bash
cd ~/Projects/msoffice-resume/OfficeResumeBackend
npm ci || npm install
npm run lint
npm test
```

## 3. Direct Local Testing (No Apple Developer Account)

### 3.1 Build local dev pkg

```bash
cd ~/Projects/msoffice-resume
./scripts/package-local-dev.sh
```

### 3.2 Install local dev pkg

```bash
sudo ./scripts/install-local-dev.sh ./dist/OfficeResume-local-dev.pkg
```

### 3.3 Verify installed apps

- `/Applications/OfficeResume.app`
- `/Applications/OfficeResumeHelper.app`

### 3.4 Optional debug entitlement bypass (debug builds only)

If you need local entitlement bypass during development, set this env var in the app/helper scheme:

- `OFFICE_RESUME_ENABLE_DEBUG_ENTITLEMENT_BYPASS=1`

Notes:
- This bypass is explicit, non-default, and debug-only.
- Production Direct entitlement/free-pass is backend-authoritative.

## 4. Cloudflare Worker Setup (Direct Entitlements)

1. Create Cloudflare account and install Wrangler:

```bash
npm install -g wrangler
wrangler login
```

2. Provision Worker and storage:
- Worker service for `OfficeResumeBackend`
- D1 database (durable records)
- KV namespace (fast token/session lookups)

3. Configure Worker secrets/env:
- `MAGIC_LINK_SIGNING_SECRET`
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_WEBHOOK_TOLERANCE_SECONDS` (optional, default 300)
- `FREE_PASS_EMAILS` (optional allowlist for internal users)

4. Deploy and note base URL for the app’s Direct entitlement endpoint.

## 5. Stripe Setup (Direct Billing)

1. Create Stripe account.
2. Create prices:
- monthly: `$5/month`
- yearly: `$50/year`

3. Configure 14-day trial on subscriptions.
4. Create webhook endpoint to Worker:
- `POST /webhooks/stripe`
- events:
  - `customer.subscription.created`
  - `customer.subscription.updated`
  - `customer.subscription.deleted`

5. Store Stripe secret keys and webhook secret in Worker secrets.

## 6. Free-Pass for You + Internal Testers

Use backend allowlist only (Direct channel):

- Add emails to Worker env `FREE_PASS_EMAILS`.
- User must authenticate via magic link.
- `/entitlements/current` returns active free-pass entitlement for allowlisted emails.

No production local free-pass file/env mechanism is supported.

## 7. MAS Setup (Optional)

Needed only for App Store distribution.

1. Enroll in Apple Developer Program.
2. Create app IDs:
- `com.pragprod.msofficeresume.mas`
- `com.pragprod.msofficeresume.helper`

3. Create App Group:
- `group.com.pragprod.msofficeresume`

4. App Store Connect:
- create app record
- create subscription group
- products:
  - `officeresume.monthly`
  - `officeresume.yearly`
- set 14-day introductory trial

## 8. Direct Release Packaging (Canonical)

Run:

```bash
./scripts/release-direct.sh
```

Outputs:
- `dist/OfficeResume-direct-unsigned.pkg`
- `dist/release-direct/` payload

For signed/notarized release, set:
- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_ID_INSTALLER`
- `NOTARYTOOL_PROFILE`

## 9. GitHub Copilot Code Review Setup

These are GitHub-side settings (manual):

1. Enable GitHub Copilot and Copilot code review for your org/account.
2. Enable repository access for Copilot on this repo.
3. Configure branch/ruleset to auto-request Copilot review on pull requests.
4. Ensure PR template is used and filled, including Copilot review metadata.
5. In branch protection, require these checks:
- `docs-guardrails`
- `ui-guardrails`
- `pr-scorecard-guardrail`
- `spec-drift-guardrails`
- `build-test-mas`
- `build-test-direct`
- `backend-tests`

Copilot review is advisory; CI checks remain merge gates.

## 10. Recommended Operating Order

1. Keep docs in sync first (`AGENTS.md` -> `PRD.md` -> `spec.md` -> `specs/*.md` -> `prompt.md`).
2. Implement code changes.
3. Run local checks + tests.
4. Open PR with scorecard and Copilot metadata.
5. Merge only after CI is green.
