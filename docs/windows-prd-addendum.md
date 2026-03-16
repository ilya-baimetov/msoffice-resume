# Office Resume for Windows: PRD Addendum

## Status
This document is exploratory and does not amend the canonical macOS v1 product contract.

It describes a proposed Windows product line for Office Resume, based on the current behavior of Microsoft 365 desktop apps on Windows as of March 14, 2026.

## Problem Statement
Microsoft 365 desktop apps on Windows do not offer one consistent, product-wide "resume my last working set" experience across Word, Excel, and PowerPoint after:

- user-initiated quit and relaunch
- Windows logoff and next logon
- Office or Windows update restart flows

Windows can relaunch restartable apps after sign-in, and Outlook has its own restore behavior for previously open items/windows, but Word, Excel, and PowerPoint do not present a clearly documented equivalent of full prior-session restore after an intentional quit.

Office Resume for Windows should provide a predictable, cross-app restore experience for users who routinely work with multiple Office documents and expect their workspace to come back the next time they return.

## Target Users
- knowledge workers who keep multiple Word, Excel, and PowerPoint files open as a working set
- consultants, operators, finance users, sales users, and executives who bounce between Office files all day
- users who sign out, reboot, or restart frequently and want the same Office state back
- users who value deterministic restore over Office's crash-only recovery behavior

## Product Thesis
Office Resume for Windows is valuable if it does all of the following better than the platform default:

- restores saved Word, Excel, and PowerPoint files after normal quit and relaunch
- restores them after logoff/logon if the apps reopen automatically or are launched manually
- restores them after Office or Windows update restarts
- avoids duplicate reopening if Office or Windows already reopened some files
- behaves the same way across Word, Excel, and PowerPoint

## Proposed Windows v1 Scope

### Supported Apps
- Word: full saved-document restore
- Excel: full saved-workbook restore
- PowerPoint: full saved-presentation restore

### Explicitly Out of Scope for Windows v1
- Outlook classic: defer
- new Outlook for Windows: unsupported
- OneNote: unsupported
- unsaved document reconstruction: defer to v1.1+
- exact window geometry restoration: defer
- browser Office apps: unsupported
- perpetual non-Microsoft-365 SKUs as an explicit support target: defer

## Why Outlook Is Deferred
- Outlook already has native restore behavior for previously open items/windows.
- new Outlook for Windows does not support COM/VSTO add-ins, which makes a native Office Resume hook model materially weaker there.
- Windows v1 should focus on the higher-value gap: Word, Excel, and PowerPoint.

## Goals
1. Restore saved Word, Excel, and PowerPoint files after intentional quit and relaunch.
2. Restore saved files after logoff/logon and update-driven relaunch flows.
3. Never reopen duplicates if the app or OS already reopened some files.
4. Require no Accessibility-equivalent system permission model.
5. Use native Office event hooks rather than UI scraping as the primary signal source.
6. Ship as a standard Windows desktop installable app with quiet background behavior.

## Non-Goals
1. Do not attempt to outperform Office crash recovery for unsaved content in v1.
2. Do not restore Outlook session state in v1.
3. Do not restore OneNote in v1.
4. Do not rely on UI Automation as the primary capture mechanism.
5. Do not introduce cloud telemetry as part of core functionality.

## Core User Stories
1. As a Word user, when I reopen Word after quitting it yesterday, my previously open saved documents reopen automatically.
2. As an Excel user, when Windows signs me back in after an update, my prior workbook set comes back without duplicates.
3. As a PowerPoint user, when I restart after an Office update, the decks I was working on reopen automatically.
4. As a user, if Office or Windows already reopened some files, Office Resume should open only the missing ones.
5. As a user, I want a tray icon where I can pause tracking, force a restore, clear the saved snapshot, and inspect recent local logs.

## Functional Requirements

### Capture
- Track Word, Excel, and PowerPoint document open and close lifecycle using native Office desktop event hooks.
- Persist only the latest snapshot per app.
- Track saved file paths only in v1.

### Restore
- On supported app startup, determine whether a restore should run for the current app instance.
- Compare currently open files with the last saved snapshot.
- Open only the missing files.
- Apply a one-shot restore marker per process launch instance.

### Trigger Scenarios
- normal app relaunch after explicit quit
- app launch after Windows logon
- app launch after Office or Windows update restart
- manual restore via tray menu

### Tray UX
Tray menu should include:
- tracking status
- `Pause Tracking` / `Resume Tracking`
- `Restore Now`
- `Clear Snapshot`
- `Open Log`
- `Quit`

### Logging
- local logs only
- no remote analytics
- recent operational logs accessible from the tray

## Supported Restore Semantics

### Normal Quit -> Reopen
Supported and primary value proposition.

### Logoff -> Logon
Supported when:
- Windows restarts the Office app automatically and the add-in startup path runs restore, or
- the user launches the app manually after sign-in

### Office / Windows Update
Supported when:
- the Office app is restarted by the platform, or
- the user launches it after update completion

## Proposed Packaging and Distribution
- direct Windows desktop installer first
- signed MSI as canonical Windows artifact
- auto-start tray app on sign-in
- standard in-place upgrade behavior for same-channel installs

Microsoft Store distribution is not required for Windows v1.

## Monetization Proposal
Keep monetization aligned with the macOS app unless strategy changes:

- 14-day trial
- $5/month
- $50/year
- friends-and-family free-pass allowlist for internal testing

## Success Criteria
1. Word, Excel, and PowerPoint reliably restore saved files after explicit quit and relaunch.
2. Duplicate reopen rate is near zero in normal usage.
3. Logoff/logon and update restart flows behave materially better than platform default for W/E/P.
4. Tray app remains quiet and stable.
5. No privileged accessibility-style trust ceremony is required.

## Main Risks
1. OneDrive / SharePoint / cloud-backed path normalization may be inconsistent across apps.
2. VSTO/COM deployment is Windows-only and older technology.
3. new Outlook for Windows cannot be addressed with the same native add-in model.
4. Office update behavior may vary by channel and enterprise policy.

## Mitigations
1. Support only local/saved paths in v1.
2. Keep Outlook out of Windows v1.
3. Use native Office events as the primary signal source and UI Automation only as fallback.
4. Keep restore logic per app simple and deterministic.

## References
- [Word `Application.DocumentOpen`](https://learn.microsoft.com/en-us/office/vba/api/word.application.documentopen)
- [Word `Application.DocumentBeforeClose`](https://learn.microsoft.com/en-us/office/vba/api/word.application.documentbeforeclose)
- [Excel `Application.WorkbookBeforeClose`](https://learn.microsoft.com/en-us/office/vba/api/excel.application.workbookbeforeclose)
- [Excel `Workbooks.Open`](https://learn.microsoft.com/en-us/office/vba/api/Excel.Workbooks.Open)
- [PowerPoint `Application.PresentationOpen`](https://learn.microsoft.com/en-us/office/vba/api/powerpoint.application.presentationopen)
- [PowerPoint `Application.PresentationClose`](https://learn.microsoft.com/en-us/office/vba/api/powerpoint.application.presentationclose)
- [Windows sign-in options](https://support.microsoft.com/en-us/windows/sign-in-options-in-windows-8ae09c04-c5da-41c9-972f-b126a13d18a8)
- [Outlook restore previous items](https://support.microsoft.com/en-us/office/outlook-unexpectedly-prompts-to-reopen-items-from-your-last-session-66fb5584-b793-436a-9e28-8857e3c7f471)
- [Office Add-ins platform overview](https://learn.microsoft.com/en-us/office/dev/add-ins/overview/office-add-ins)
- [COM and VSTO add-ins aren't supported in new Outlook on Windows](https://learn.microsoft.com/en-us/office/dev/add-ins/develop/make-office-add-in-compatible-with-existing-com-add-in)
