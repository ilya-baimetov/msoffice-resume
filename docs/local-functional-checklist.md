# Office Resume v1 Local Functional Checklist

Use this checklist to validate the local free-pass build end-to-end.

## Preconditions

- Install local build:
  - `./scripts/package-local-free-pass.sh`
  - `./dist/local-free-pass/install-local-free-pass.sh`
- Confirm free-pass file exists:
  - `~/Library/Application Support/com.pragprod.msofficeresume/entitlements/free-pass-v1.json`
- Ensure helper + app are running.

## Automated Baseline (already executed)

- `xcodebuild ... OfficeResumeMAS ... build test`: pass
- `xcodebuild ... OfficeResumeDirect ... build test`: pass
- `cd OfficeResumeBackend && npm test`: pass

## Manual Product Validation

1. Menu bar and helper health
- Open `Office Resume` from menu bar.
- Expected: status shows `Helper Connected` and `Entitlement: Active`.

2. Polling settings persistence
- Change polling from `15s` to `5s`.
- Quit and relaunch `Office Resume`.
- Expected: polling remains `5s`.

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
- Before auto-restore completes, manually open one of the previous docs.
- Expected: app opens only remaining missing docs, no duplicates.

7. Pause tracking
- Toggle `Pause tracking` on.
- Open/close docs in Word.
- Expected: snapshot timestamps stop changing while paused.

8. Clear snapshot
- Click `Clear snapshot`.
- Relaunch a tested Office app.
- Expected: no restore occurs until new state is captured.

9. Outlook limited mode
- Launch and quit Outlook.
- Relaunch Outlook.
- Expected: lifecycle logging works; no unreliable item/window reconstruction attempted.

10. OneNote unsupported
- Open menu UI.
- Expected: OneNote listed as unsupported.

## Diagnostics

Inspect local state/log files:

- Word snapshot:
  - `~/Library/Saved Application State/com.microsoft.Word.savedState/OfficeResume/snapshot-v1.json`
- Word events:
  - `~/Library/Saved Application State/com.microsoft.Word.savedState/OfficeResume/events-v1.ndjson`
- Equivalent files exist for Excel/PowerPoint/Outlook bundle IDs.

## Pass Criteria

- All automated baseline checks pass.
- Manual checks 1-10 pass without crash/hang.
- No duplicate restores observed in Word/Excel/PowerPoint.
