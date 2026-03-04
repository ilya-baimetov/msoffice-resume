# Direct Distribution Hardening (Signing, Notarization, Billing, Review Gates)

This is the minimum hardening baseline before broad external Direct distribution.

## 1. Build Canonical Direct Installer (.pkg)

Run:

```bash
./scripts/release-direct.sh
```

Outputs:

- `dist/OfficeResume-direct-unsigned.pkg`
- `dist/release-direct/` (staged payload with `OfficeResume.app` + `OfficeResumeHelper.app`)

The package uses a stable package identifier/version and supports upgrade installs.
It also enforces channel-conflict protection: Direct install aborts if MAS is already installed at `/Applications/OfficeResume.app`.

## 2. Sign App Bundles + Installer Package

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

## 4. Runtime/Billing Security Baseline

Required protections:

- Direct free-pass is backend-authoritative via verified session + `FREE_PASS_EMAILS` allowlist
- Production client path has no local free-pass file/env override behavior
- Stripe webhook signature verification enabled (`STRIPE_WEBHOOK_SECRET`)
- Stripe replay-window enforced (`STRIPE_WEBHOOK_TOLERANCE_SECONDS`, default 300)

Worker env baseline:

- `MAGIC_LINK_SIGNING_SECRET`
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`
- `FREE_PASS_EMAILS` (optional)
- `STRIPE_WEBHOOK_TOLERANCE_SECONDS` (optional)

## 5. CI and Review Gates

Required PR checks:

- `docs-guardrails`
- `ui-guardrails`
- `pr-scorecard-guardrail`
- `spec-drift-guardrails`
- `build-test-mas`
- `build-test-direct`
- `backend-tests`

Review model:

- GitHub Copilot review enabled and auto-requested on PRs.
- Copilot guidance from `.github/copilot-instructions.md`.
- Copilot is advisory; CI checks are merge gate.

## 6. Release Validation Checklist

1. `./scripts/eval-docs-consistency.sh` passes.
2. `./scripts/eval-ui-guardrails.sh` passes.
3. MAS/Direct/helper builds and tests pass.
4. Backend `npm run lint` and `npm test` pass.
5. Direct pkg install and upgrade path validated.
6. Direct pkg blocks install with clear uninstall-first message when opposite channel is detected.
7. Postinstall behavior restarts/relaunches app cleanly.
8. Free-pass allowlist works for internal accounts.
9. Non-allowlisted accounts require trial/subscription entitlement.
10. No remote analytics/telemetry introduced.
