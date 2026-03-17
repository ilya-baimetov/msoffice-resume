# Office Resume

Office Resume is a macOS menu bar app plus helper that restores Microsoft Office sessions across relaunches.

Canonical docs:
- `AGENTS.md`
- `PRD.md`
- `spec.md`
- `specs/contracts.md`
- `specs/core.md`
- `specs/helper-daemon.md`
- `specs/menu-ui.md`
- `specs/backend-worker.md`
- `prompt.md`

## Docs and Eval Utilities
- Docs consistency checker: `./scripts/eval-docs-consistency.sh`
- UI guardrails checker: `./scripts/eval-ui-guardrails.sh`
- Install repo-managed git hooks: `./scripts/install-git-hooks.sh`
- Local Node baseline: `.node-version` / `.nvmrc` pin Node 24; older versions are unsupported
- Methodology/docs:
  - `docs/vibe-coding-methodology.md`
  - `docs/eval-scorecard-template.md`
  - `docs/local-functional-checklist.md`
  - `docs/release-hardening.md`

## Recommended Solo Workflow
Default local workflow for this repo:

1. edit
2. local review
3. commit
4. repeat
5. push to `main` only after local hooks and full checks pass

PRs are optional. Use them only when you want GitHub-hosted review history, Copilot PR review comments, or an extra merge gate.

Enable repo-managed hooks once per workstation:

```bash
./scripts/install-git-hooks.sh
```

Hook behavior:
- `pre-commit`: fast guardrails and targeted lint checks
- `pre-push`: full repo checks based on changed files since upstream

Manual local review helper:

```bash
./scripts/review-local.sh staged
./scripts/review-local.sh unstaged
./scripts/review-local.sh last-commit
```

Manual local check helper:

```bash
./scripts/check-local.sh fast
./scripts/check-local.sh full
```

## Local Debug Build and Install
No Apple Developer account is required for local Debug builds.

Build a local Debug installer package:

```bash
./scripts/package-local-dev.sh
```

Install locally:

```bash
sudo ./scripts/install-local-dev.sh ./dist/OfficeResume-local-dev.pkg
```

Installed paths:
- `/Applications/Office Resume.app`
- `/Applications/Office Resume.app/Contents/Library/LoginItems/OfficeResumeHelper.app`

Notes:
- Local Debug package is convenience-only and non-canonical for public distribution.
- Canonical Direct distribution artifact is the pkg produced by `./scripts/release-direct.sh`.
- Runtime permissions are requested after install when the app/helper actually needs them.
- Debug-only entitlement bypass remains available only when explicitly enabled at runtime in a Debug build.

## Direct Release Packaging (.pkg)
Build Direct release artifacts:

```bash
./scripts/release-direct.sh
```

Outputs:
- `dist/OfficeResume-direct-unsigned.pkg`
- `dist/release-direct/` (staged app payload)

Optional signing/notarization env vars:
- `DEVELOPER_ID_APPLICATION`
- `DEVELOPER_ID_INSTALLER`
- `NOTARYTOOL_PROFILE`

## Build and Test
Generate project if needed:

```bash
xcodegen generate
```

Run macOS builds/tests:

```bash
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeMAS -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build test
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeDirect -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build test
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeHelper -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run backend checks:

```bash
cd OfficeResumeBackend
npm ci || npm install
npm run lint
npm test
```

The repo baseline is Node 24+. CI uses Node 24, and older local Node versions are unsupported.

## Build Modes
### Debug local build
- Works without production backend if you use Debug-only local shortcuts.
- Suitable for local feature testing and Accessibility/restore verification.

### ReleaseDirect
- Intended for website distribution.
- Uses production Direct backend and signed/notarized `.pkg`.
- No client-side local bypasses are accepted.

### ReleaseMAS
- Intended for Mac App Store distribution.
- Uses StoreKit 2 and App Store Connect configuration.

## Direct Backend Configuration
Direct production build expects a configured backend base URL and callback scheme.

Recommended configuration sources:
- Info.plist/build settings for Release builds
- environment overrides only for local Debug workflows

See `services-setup.md` for the exact service setup and required env/build settings.

Direct billing flow:
- sign in by email magic link first
- if not yet paid, `Account…` opens a Worker-hosted pricing page and then Stripe Checkout
- if already paid, `Account…` opens Stripe Billing Portal

## Friends-and-Family Free Pass
Direct free-pass is backend-authoritative.

Sources of allowlisted emails:
- checked-in hard-coded backend list for real-world testing
- optional `FREE_PASS_EMAILS` environment variable to extend it

Checked-in file:
- `OfficeResumeBackend/src/free-pass-emails.js`

The client app does not grant free-pass locally.

## CI
Workflow: `.github/workflows/ci.yml`

Primary jobs:
- `docs-guardrails`
- `ui-guardrails`
- `site-worker-dry-run`
- `pr-scorecard-guardrail`
- `spec-drift-guardrails`
- `build-test-mas`
- `build-test-direct`
- `backend-tests`

`pr-scorecard-guardrail` matters only when you choose to use a PR.

## Debug-Only Entitlement Bypass
For local Debug builds only, an explicit bypass can be enabled from the Debug account UI/runtime opt-in path.

It is:
- non-default
- Debug-only
- not part of Release behavior
