# Services Setup Guide (Direct + MAS)

This guide covers external setup for Office Resume, including a Direct local-development path that works without an Apple Developer account.

## 1. Distribution Tracks
### Track A: Direct local development / private testing
Use this for local Debug builds, testing, and unsigned Direct packaging.

### Track B: Direct production website distribution
Use this when you are ready to ship a signed/notarized Direct `.pkg`.

### Track C: MAS + Direct
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

4. Install Node 24+:

```bash
brew install node
```

5. Generate project and run baseline checks:

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

## 3. Local Debug Testing (No Apple Developer Account)
### 3.1 Build local Debug pkg

```bash
cd ~/Projects/msoffice-resume
./scripts/package-local-dev.sh
```

### 3.2 Install local Debug pkg

```bash
sudo ./scripts/install-local-dev.sh ./dist/OfficeResume-local-dev.pkg
```

### 3.3 Verify installed apps
- `/Applications/Office Resume.app`
- `/Applications/Office Resume.app/Contents/Library/LoginItems/OfficeResumeHelper.app`

### 3.4 Enable local Debug entitlement/testing shortcuts
- Use the Debug-only account UI/runtime opt-in inside a Debug build.
- These shortcuts do not exist in Release behavior.

## 4. Direct Backend Setup (Cloudflare Worker)
1. Create Cloudflare account and install Wrangler:

```bash
npm install -g wrangler
wrangler login
```

2. Provision Worker and storage:
- Worker service for `OfficeResumeBackend`
- D1 database
- KV namespace

3. Configure Worker secrets/env:
- `RESEND_API_KEY`
- `RESEND_FROM_EMAIL`
- `DIRECT_APP_CALLBACK_SCHEME` (for example `officeresume-direct`)
- `DIRECT_VERIFY_REDIRECT_HOST` (for example `auth/complete` path components if used)
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_WEBHOOK_TOLERANCE_SECONDS` (optional, default 300)
- `STRIPE_BILLING_RETURN_URL`
- `STRIPE_PRICE_MONTHLY`
- `STRIPE_PRICE_YEARLY`
- `FREE_PASS_EMAILS` (optional allowlist extension)
- `ENABLE_DEBUG_MAGIC_LINK_TOKEN` (`1` only for local/dev backend testing)

Checked-in allowlist file:
- `OfficeResumeBackend/src/free-pass-emails.js`

4. Deploy and note the base URL used by the Direct app.

## 5. Resend Setup (Direct Magic Links)
1. Create a Resend account.
2. Verify a sending domain or sender address.
3. Set:
- `RESEND_API_KEY`
- `RESEND_FROM_EMAIL`
4. Ensure the Worker can send a sign-in email containing a link to:
- `GET /auth/verify?token=...`

## 6. Stripe Setup (Direct Billing)
1. Create a Stripe account.
2. Create prices:
- monthly: `$5/month`
- yearly: `$50/year`

3. Configure 14-day trial on subscriptions if you want checkout/portal messaging aligned with the backend policy.
4. Create webhook endpoint to Worker:
- `POST /webhooks/stripe`
- events:
  - `customer.subscription.created`
  - `customer.subscription.updated`
  - `customer.subscription.deleted`

5. Store Stripe secret keys and webhook secret in Worker secrets.
6. Configure Stripe billing portal and return URL.
7. The Worker creates Checkout Sessions for new purchases; do not rely on generic shareable Stripe links for the production Direct flow.

## 7. Direct App Configuration
Recommended Direct app build/runtime values:
- `OFFICE_RESUME_DIRECT_BACKEND_BASE_URL` for local Debug builds
- Release Info.plist/build setting for the production backend base URL
- Direct callback URL scheme matching the Worker redirect config

Normal Direct usage flow:
1. User installs app.
2. User opens `Account…`.
3. User requests sign-in link.
4. User clicks email link.
5. Worker redirects to app callback URL.
6. App stores session token in Keychain and refreshes entitlements.
7. Signed-in non-paid users choose a plan on the Worker-hosted pricing page and continue to Stripe Checkout.
8. Signed-in paid users manage billing through Stripe Billing Portal.

## 8. Friends-and-Family Free Pass
Use backend allowlist only (Direct channel):
- checked-in hard-coded list in backend source for real-world testing
- optional `FREE_PASS_EMAILS` env extension
- user must still authenticate via magic link

No production local free-pass file/env mechanism is supported.

## 9. MAS Setup (Optional)
Needed only for App Store distribution.

1. Enroll in Apple Developer Program.
2. Create app IDs:
- `com.pragprod.msofficeresume.mas`
- `com.pragprod.msofficeresume.helper`

3. Create App Group:
- `group.com.pragprod.msofficeresume`

4. Configure StoreKit/App Store Connect:
- app record
- subscription group
- products:
  - `officeresume.monthly`
  - `officeresume.yearly`
- 14-day introductory trial

## 10. Direct Release Packaging (Canonical)
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

## 11. MAS Release Flow
1. Build/archive `OfficeResumeMAS` from Xcode.
2. Validate StoreKit configuration.
3. Upload through App Store Connect.

## 12. GitHub Copilot Code Review Setup
These are GitHub-side settings when you want PR-based review:
1. Enable GitHub Copilot and Copilot code review for your org/account.
2. Enable repository access for Copilot on this repo.
3. Configure rules to auto-request Copilot review on pull requests.
4. Ensure PR template is used and filled, including Copilot review metadata.
5. Require these checks:
- `docs-guardrails`
- `ui-guardrails`
- `pr-scorecard-guardrail`
- `spec-drift-guardrails`
- `build-test-mas`
- `build-test-direct`
- `backend-tests`

Copilot review is advisory; CI checks remain merge gates.
For the default solo workflow in this repo, local git hooks plus local review are the primary gate before push.

## 13. Recommended Operating Order
1. Keep docs in sync first (`AGENTS.md` -> `PRD.md` -> `spec.md` -> `specs/*.md` -> `prompt.md`).
2. Implement code changes.
3. Install repo-managed hooks once: `./scripts/install-git-hooks.sh`.
4. Use local review + local hooks while iterating.
5. Run/install local Debug package if needed.
6. Push only after local checks + tests pass.
7. Use a PR only when you want GitHub/Copilot review or remote review history.
