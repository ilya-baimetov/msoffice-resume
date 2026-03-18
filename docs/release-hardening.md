# Direct Distribution Hardening (Signing, Notarization, Permissions, Billing, Review Gates)

This is the minimum hardening baseline before broad external Direct distribution.

## 1. Build Canonical Direct Installer (`.pkg`)
Run:
```bash
./scripts/release-direct.sh
```

Outputs:
- `dist/OfficeResume-direct-unsigned.pkg`
- `dist/release-direct/` (staged payload with `Office Resume.app`, containing embedded `Contents/Library/LoginItems/OfficeResumeHelper.app`)

The package uses a stable package identifier and version and supports upgrade installs.
It may enforce channel-conflict protection if a legacy MAS install is still detected.
Package components are built as non-relocatable to avoid installer relocation of `Office Resume.app` into user-local folders.
The installer cannot grant TCC permissions; runtime prompts are triggered on first launch or use.

## 2. Sign App Bundles And Installer Package
Set:
```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: <Company> (<TEAMID>)"
export DEVELOPER_ID_INSTALLER="Developer ID Installer: <Company> (<TEAMID>)"
```

Rerun:
```bash
./scripts/release-direct.sh
```

Result:
- app bundles are codesigned and verified
- signed package produced at `dist/OfficeResume-direct-signed.pkg`

## 3. Notarize
Store credentials once:
```bash
xcrun notarytool store-credentials office-resume-notary \
  --apple-id "<apple-id>" \
  --team-id "<team-id>" \
  --password "<app-specific-password>"
```

Then:
```bash
export NOTARYTOOL_PROFILE="office-resume-notary"
./scripts/release-direct.sh
```

Expected:
- pkg submitted to notary service
- pkg stapled and validated

## 4. Runtime And Billing Security Baseline
Required protections:
- Direct free-pass is backend-authoritative via verified session and allowlist
- Production client path has no local free-pass file or env override behavior
- Stripe webhook signature verification enabled (`STRIPE_WEBHOOK_SECRET`)
- Stripe replay-window enforced (`STRIPE_WEBHOOK_TOLERANCE_SECONDS`, default 300)

Worker env baseline:
- `MAGIC_LINK_SIGNING_SECRET`
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `STRIPE_PRICE_MONTHLY`
- `STRIPE_PRICE_YEARLY`
- `FREE_PASS_EMAILS` (optional)
- `STRIPE_WEBHOOK_TOLERANCE_SECONDS` (optional)

Checked-in free-pass allowlist:
- `OfficeResumeBackend/src/free-pass-emails.js`

## 5. Permission Stability Baseline
Required release expectations:
- Accessibility permission is clearly requested and accurately reflected in the menu
- Apple Events prompts are bounded and do not fan out into repeated dialogs
- Signed app and helper identities remain stable across updates
- AX and Apple Events logic is serialized enough to avoid prompt storms under focus churn

## 6. CI And Review Gates
Required PR checks when using a PR:
- `docs-guardrails`
- `ui-guardrails`
- `pr-scorecard-guardrail`
- `spec-drift-guardrails`
- `build-test-direct`
- `backend-tests`

Review model:
- GitHub Copilot review enabled and auto-requested on PRs
- Copilot guidance from `.github/copilot-instructions.md`
- Copilot is advisory; CI checks are the merge gate
- Default solo path may skip PRs and rely on local hooks plus local review before push

## 7. Release Validation Checklist
1. `./scripts/eval-docs-consistency.sh` passes.
2. `./scripts/eval-ui-guardrails.sh` passes.
3. Direct and helper builds and tests pass.
4. Backend `npm run lint` and `npm test` pass.
5. Direct pkg install and upgrade path is validated.
6. Postinstall behavior restarts or relaunches the app cleanly.
7. Free-pass allowlist works for internal accounts.
8. Non-allowlisted accounts require trial or subscription entitlement.
9. Direct checkout uses Worker-hosted pricing plus Stripe Checkout Sessions after verified sign-in.
10. Accessibility flow works and does not reprompt endlessly for the signed build.
11. Apple Events prompts remain bounded under focus churn.
12. No remote analytics or telemetry introduced.
