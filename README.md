# msoffice-resume

Office Resume v1 planning docs are in:

- `AGENTS.md`
- `PRD.md`
- `spec.md`
- `specs/contracts.md`
- `specs/core.md`
- `specs/helper-daemon.md`
- `specs/menu-ui.md`
- `specs/backend-worker.md`
- `prompt.md`

Service/account setup instructions are in:

- `services-setup.md`
- `docs/local-functional-checklist.md`
- `docs/release-hardening.md`
- `docs/vibe-coding-methodology.md`
- `docs/eval-scorecard-template.md`

Docs consistency checker:

- `scripts/eval-docs-consistency.sh`

Run it from repo root:

```bash
./scripts/eval-docs-consistency.sh
```

## Local Free-Pass Build (Direct + Helper)

To build a locally installable package (no Apple Developer account required):

```bash
./scripts/package-local-free-pass.sh
```

This produces:

- `dist/local-free-pass/`
- `dist/OfficeResume-local-free-pass.zip`

Install and launch in free-pass mode:

```bash
./dist/local-free-pass/install-local-free-pass.sh
```

Default install path is `~/Applications/OfficeResumeLocal`.
Free-pass is enabled via:
`~/Library/Application Support/com.pragprod.msofficeresume/entitlements/free-pass-v1.json`.

## Direct Release Build (Sign + Notarize Optional)

Build release artifacts:

```bash
./scripts/release-direct.sh
```

Optional environment variables for signing/notarization:

- `DEVELOPER_ID_APPLICATION`
- `NOTARYTOOL_PROFILE`

## Build and Test Process

### Local (developer machine)
Once the Xcode project is scaffolded, run:

```bash
xcodegen generate
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeMAS -destination 'platform=macOS' build test
xcodebuild -workspace OfficeResume.xcworkspace -scheme OfficeResumeDirect -destination 'platform=macOS' build test
```

If only a project exists (no workspace), use `-project <path>.xcodeproj`.

For the direct backend (`OfficeResumeBackend`):

```bash
cd OfficeResumeBackend
npm ci || npm install
npm test
```

### CI (GitHub Actions)
Workflow: `.github/workflows/ci.yml`

Runs on every push to PRs targeting `main`, and on pushes to `main`/`codex/**`.

Jobs:
- `docs-guardrails`
- `build-test-mas`
- `build-test-direct`
- `backend-tests`

Notes:
- Until Xcode/backend scaffolding exists, build/test jobs skip cleanly.
- After scaffolding exists, CI enforces scheme presence and runs real build/tests.

## PR Gate
`main` should require CI status checks before merge.

Recommended required checks:
- `docs-guardrails`
- `build-test-mas`
- `build-test-direct`
- `backend-tests`
