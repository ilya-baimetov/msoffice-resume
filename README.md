# msoffice-resume

Office Resume v1 planning docs are in:

- `AGENTS.md`
- `PRD.md`
- `spec.md`
- `prompt.md`

## Build and Test Process

### Local (developer machine)
Once the Xcode project is scaffolded, run:

```bash
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
