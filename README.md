# msoffice-resume

Office Resume planning and implementation docs:

- `AGENTS.md`
- `PRD.md`
- `spec.md`
- `specs/contracts.md`
- `specs/core.md`
- `specs/helper-daemon.md`
- `specs/menu-ui.md`
- `specs/backend-worker.md`
- `prompt.md`

## Docs/Eval Utilities

- Docs consistency checker: `./scripts/eval-docs-consistency.sh`
- UI guardrails checker: `./scripts/eval-ui-guardrails.sh`
- Methodology/docs:
  - `docs/vibe-coding-methodology.md`
  - `docs/eval-scorecard-template.md`
  - `docs/local-functional-checklist.md`
  - `docs/release-hardening.md`

## Local Dev Install (No Apple Developer Account Required)

Build an unsigned local dev installer package:

```bash
./scripts/package-local-dev.sh
```

Install locally:

```bash
sudo ./scripts/install-local-dev.sh ./dist/OfficeResume-local-dev.pkg
```

Installed paths:

- `/Applications/OfficeResume.app`
- `/Applications/OfficeResumeHelper.app`

Notes:

- Local dev package is convenience-only and non-canonical for public distribution.
- Canonical Direct distribution artifact is the pkg produced by `./scripts/release-direct.sh`.

## Direct Release Packaging (.pkg)

Build release artifacts:

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

Generate project (if needed):

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

## CI

Workflow: `.github/workflows/ci.yml`

Primary jobs:

- `docs-guardrails`
- `ui-guardrails`
- `pr-scorecard-guardrail` (PR body + Copilot metadata)
- `spec-drift-guardrails`
- `build-test-mas` (includes `xcodebuild analyze`)
- `build-test-direct` (includes `xcodebuild analyze`)
- `backend-tests` (includes backend lint + tests)

## Debug-Only Entitlement Bypass (Optional)

For local debug builds only, an explicit bypass can be enabled with:

- `OFFICE_RESUME_ENABLE_DEBUG_ENTITLEMENT_BYPASS=1`

This bypass is non-default and not part of production release behavior.
