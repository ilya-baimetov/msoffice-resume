# Office Resume v1 Local Functional Checklist

Use this checklist to validate local behavior end-to-end.

## Preconditions
1. Build and install the local dev package:
- `./scripts/package-local-dev.sh`
- `sudo ./scripts/install-local-dev.sh ./dist/OfficeResume-local-dev.pkg`

2. Ensure apps exist:
- `/Applications/Office Resume.app`
- `/Applications/Office Resume.app/Contents/Library/LoginItems/OfficeResumeHelper.app`

3. Ensure the menu app and helper are running.

## Automated Baseline
- `xcodebuild ... OfficeResumeDirect ... build test`: pass
- `xcodebuild ... OfficeResumeHelper ... build`: pass
- `cd OfficeResumeBackend && npm run lint && npm test`: pass

Legacy note:
- `OfficeResumeMAS` may still build during migration, but it is not part of the active shipping contract.

## Manual Product Validation
1. Menu bar and helper health
- Open the menu.
- Expected: no persistent helper-connection errors; actions enabled when entitlement is active.

2. Accessibility dependency
- Relaunch Office Resume.
- Open the menu.
- Expected: Accessibility row is present and accurately reflects current trust state.
- Expected: after grant, the signed build does not reprompt endlessly.

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
- Open and close docs in Word.
- Expected: snapshot timestamps stop changing while paused.

8. Clear snapshot
- Click `Advanced > Clear Snapshot`.
- Relaunch the tested Office app.
- Expected: no restore until a new snapshot is captured.

9. Outlook limited mode
- Launch and quit Outlook.
- Relaunch Outlook.
- Expected: lifecycle behavior works; no item or window reconstruction attempted beyond relaunch.

10. OneNote UI behavior
- Open the menu.
- Expected: no dedicated OneNote unsupported row in the menu.

11. Billing and account flow
- Open `Account…`.
- Expected: signed-out state shows email input and sign-in action.
- After sign-in as a non-paid user, expected: `Choose Plan…` opens Worker-hosted pricing.
- After sign-in as a paid user, expected: `Manage Subscription` opens Billing Portal.

## Diagnostics
Inspect local state and log files under:
- `~/Library/Application Support/com.pragprod.msofficeresume/`

Example Word files:
- `state/com.microsoft.Word/snapshot-v1.json`
- `state/com.microsoft.Word/events-v1.ndjson`
- `logs/debug-v1.log`

## Pass Criteria
- Automated baseline checks pass.
- Manual checks 1-11 pass without crash or hang.
- No duplicate restores observed in Word, Excel, or PowerPoint.
- No repeated Accessibility or Apple Events prompt storms are observed in the signed test build.
