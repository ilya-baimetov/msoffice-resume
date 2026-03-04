# Office Resume v1 Local Functional Checklist

Use this checklist to validate local behavior end-to-end.

## Preconditions

1. Build and install local dev package:
- `./scripts/package-local-dev.sh`
- `sudo ./scripts/install-local-dev.sh ./dist/OfficeResume-local-dev.pkg`

2. Ensure apps exist:
- `/Applications/Office Resume.app`
- `/Applications/Office Resume.app/Contents/Library/LoginItems/OfficeResumeHelper.app`

3. Ensure menu app + helper are running.

## Automated Baseline

- `xcodebuild ... OfficeResumeMAS ... build test`: pass
- `xcodebuild ... OfficeResumeDirect ... build test`: pass
- `xcodebuild ... OfficeResumeHelper ... build`: pass
- `cd OfficeResumeBackend && npm run lint && npm test`: pass

## Manual Product Validation

1. Menu bar and helper health
- Open menu.
- Expected: no persistent helper-connection errors; actions enabled when entitlement is active.

2. Accessibility permission status and recovery
- Remove Office Resume/Helper from macOS Accessibility list.
- Relaunch Office Resume.
- Expected: menu shows `Accessibility: click to fix`.
- Click to open Accessibility settings and re-grant permission.
- Expected: menu updates to `Accessibility: OK`.

3. Word restore (saved docs)
- Launch Word.
- Open 2 saved `.docx` files.
- Quit Word.
- Relaunch Word.
- Expected: missing docs auto-open exactly once.

4. Excel restore (saved docs)
- Repeat step 3 with 2 `.xlsx` workbooks.
- Expected: missing workbooks auto-open exactly once.

5. PowerPoint restore (saved docs)
- Repeat step 3 with 2 `.pptx` presentations.
- Expected: missing presentations auto-open exactly once.

6. Duplicate guard
- Before auto-restore completes, manually open one prior document.
- Expected: only remaining missing docs open; no duplicates.

7. Pause tracking
- Toggle `Pause Tracking` on.
- Open/close docs in Word.
- Expected: snapshot timestamps stop changing while paused.

8. Clear snapshot
- Click `Advanced > Clear Snapshot`.
- Relaunch tested Office app.
- Expected: no restore until a new snapshot is captured.

9. Outlook limited mode
- Launch and quit Outlook.
- Relaunch Outlook.
- Expected: lifecycle behavior works; no item/window reconstruction attempted.

10. OneNote UI behavior
- Open menu UI.
- Expected: no dedicated OneNote unsupported row in the menu.

## Diagnostics

Inspect local state/log files:

- Primary (app-group) root:
  - `~/Library/Group Containers/group.com.pragprod.msofficeresume/Saved Application State/`
- Dev fallback root (unsigned local runs):
  - `~/Library/Application Support/com.pragprod.msofficeresume/Saved Application State/`

Example Word files under either root:

- `com.microsoft.Word.savedState/OfficeResume/snapshot-v1.json`
- `com.microsoft.Word.savedState/OfficeResume/events-v1.ndjson`

## Pass Criteria

- Automated baseline checks pass.
- Manual checks 1-10 pass without crash/hang.
- No duplicate restores observed in Word/Excel/PowerPoint.
