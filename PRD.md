# Office Resume v1 - Product Requirements Document

## 1. Problem Statement
Microsoft Office for Mac does not reliably preserve full working context on relaunch. Users lose open-document continuity and must reconstruct sessions after app restarts, system restarts, or crashes.

Office Resume restores continuity by capturing Office state in the background and reopening prior work automatically.

## 2. Target Users
- Individual professionals and small teams using Office heavily on macOS
- Knowledge workers managing many Word/Excel/PowerPoint documents
- Users who expect native-like Resume behavior for Office workflows

## 3. Product Goals
1. Restore Office work context automatically on relaunch.
2. Keep user-visible behavior unified across MAS and Direct channels, except billing/auth implementation.
3. Provide lightweight menu bar controls with minimal interruption.
4. Provide a minimal but real billing/account experience for MAS and Direct.
5. Support monetization with a 14-day trial and recurring subscription.
6. Keep privacy strong: local-only operational logs and no analytics telemetry.
7. Ship a standard Direct installer experience using `.pkg` with upgrade behavior.

## 4. Non-Goals (v1)
- Full OneNote restoration support
- Outlook message-level/window-object reconstruction
- Cloud sync of snapshots across devices
- Cross-channel purchase linking
- Reverse-engineering Apple's private Resume binary format
- Installer-time automatic Accessibility approval

## 5. Scope and Support Matrix
### In Scope
- Word document-level capture/restore
- Excel workbook-level capture/restore
- PowerPoint presentation-level capture/restore
- Outlook lifecycle capture + relaunch-only restore
- Menu bar controls and account window
- Login helper daemon for background operation
- MAS and Direct targets with shared runtime behavior
- Direct distribution via standard `.pkg` installer
- Backend-authoritative friends-and-family free-pass for Direct

### Out of Scope
- OneNote automation-based restore (explicitly unsupported in v1)
- Per-app restore policies (global policy only)
- Client-side production free-pass activation via local files/env overrides

## 6. Core User Experience
### 6.1 Background Behavior
- App auto-starts at login.
- Helper tracks Office launches/quits via `NSWorkspace` and document/window changes via `AXObserver` Accessibility notifications.
- On Office relaunch, restore is attempted automatically.
- On helper startup, a restore pass is attempted for currently running Office apps (to cover login/reboot races where Office relaunches before helper is ready).

### 6.2 Restore Behavior
- Global policy applies to all supported apps.
- Restore runs once per app launch instance (one-shot marker stored outside snapshots).
- If Office already restored some docs, Office Resume opens only missing snapshot docs.
- Partial failures are tolerated and logged; successful items still restore.

### 6.3 Menu Bar Controls
Required actions:
- `Pause Tracking` / `Resume Tracking`
- `Restore Now`
- `Advanced > Clear Snapshot`
- `Advanced > Open Debug Log in Console`
- `Account…`
- `Quit`

Required display:
- Helper connection status
- Autostart health status and remediation action
- Accessibility permission status and remediation action
- Paused-state feedback when tracking is paused

The main menu does not show entitlement details or recent-event lists in v1.

### 6.4 Account Window
Shared account surface opened from the menu.

Direct:
- Signed-out state shows email entry, `Send Sign-In Link`, pricing/trial copy, and an email-verification requirement note.
- Signed-in state shows signed-in email, current entitlement/trial status, relevant dates, `Refresh Status`, a context-appropriate billing action, and `Sign Out`.
- Signed-in non-paid users see `Choose Plan…`, which opens a Worker-hosted pricing page and then Stripe Checkout.
- Signed-in paid users see `Manage Subscription`, which opens Stripe Billing Portal.
- Free-pass users do not see a paid billing action.
- In Debug builds only, explicit local testing shortcuts may appear when enabled by runtime debug opt-in.

MAS:
- Shows current StoreKit-backed entitlement/trial state.
- Shows `Refresh Status` and `Manage Subscription`.

## 7. Functional Requirements
### FR-1 Lifecycle Capture
- Capture app launch/quit events for Word/Excel/PowerPoint/Outlook/OneNote.
- Persist minimal event records locally.

### FR-2 Document/Window Capture (Accessibility-First)
- Use Accessibility notifications as primary trigger for open/close/focus/title transitions.
- Word/Excel/PowerPoint: capture open documents with path/name/saved state via adapter fetch after AX-triggered capture.
- Outlook: capture lifecycle + window metadata only.
- OneNote: no document capture and no restore.
- If Accessibility permission is not granted, degrade gracefully with explicit UI status.

### FR-3 Snapshot Persistence
- Maintain latest snapshot only per Office app.
- Use app-group-first saved-state layout with documented schema:
  - `snapshot-v1.json`
  - `events-v1.ndjson`
  - `unsaved-index-v1.json`
  - `unsaved/`
- Use the same app-group-or-debug-fallback root for logs, restore markers, and IPC status.
- Allow dev-only fallback path for unsigned local builds when app-group container is unavailable.

### FR-4 Untitled Document Handling
- For Word/Excel/PowerPoint untitled docs, force-save to temporary artifacts.
- Track mapping metadata from source doc/session to temp path.
- Reopen temp artifacts during restore when applicable.
- Purge artifacts when no longer referenced by latest lifecycle state.

### FR-5 Restore Execution
- Auto-run restore on relaunch for supported apps.
- Auto-run a startup restore pass for currently running supported apps.
- Dedupe against currently open docs.
- Apply one-shot marker per launch instance.
- Log per-item success/failure locally.

### FR-6 Autostart and Accessibility Visibility
- Menu must surface autostart status:
  - `Autostart: OK` when both main app and helper login-item registration are enabled.
  - `Autostart: click to fix` when registration is not healthy.
- `Autostart: click to fix` opens Login Items settings.
- Menu must surface Accessibility status:
  - `Accessibility: OK` when helper trust is granted.
  - `Accessibility: click to fix` when helper trust is missing.
- Clicking the Accessibility remediation row must prompt from the helper process and open System Settings.

### FR-7 Entitlement and Gating
- 14-day trial.
- Paid plans: `$5/mo` and `$50/yr`.
- On inactive entitlement: monitoring/restore disabled, history/log view remains read-only.
- Offline grace: keep paid/trial features active up to 7 days from last successful validation.
- Direct trial begins only after verified sign-in.
- MAS trial comes from StoreKit configuration/purchase state, not local synthetic trial state.

### FR-8 Distribution and Billing
- `OfficeResumeMAS`: StoreKit 2 subscriptions/trial.
- `OfficeResumeDirect`: Stripe subscriptions/trial + email magic-link + Cloudflare entitlement backend + Resend email delivery.
- Runtime behavior parity across channels except billing/auth provider internals.

### FR-9 Free-Pass Security
- Free-pass for owner/internal users is granted server-side only in Direct backend.
- Free-pass decision requires verified session identity and backend allowlist.
- The backend must support a checked-in hard-coded allowlist plus env-based extensions.
- Production app must not grant free-pass from local files/env toggles.

### FR-10 Direct Installer Experience
- Direct release artifact is a standard `.pkg` installer.
- Installing newer `.pkg` updates existing Direct install cleanly.
- Installer must detect opposite-channel install conflicts (`MAS` vs `Direct`) at install time and stop with an uninstall-first instruction.
- Installed visible app path is `/Applications/Office Resume.app`.
- Helper is packaged as embedded login item inside the main app (`Contents/Library/LoginItems/OfficeResumeHelper.app`) and must not appear as a separate top-level app in `/Applications`.
- Installer should restart/launch the app cleanly after update.
- Required runtime permissions are prompted on first launch/use.

### FR-11 Local Debug Usability
- Developers can build and run a Debug version locally without production service setup.
- Debug-only auth/entitlement shortcuts require explicit runtime opt-in and must not exist in Release behavior.

## 8. Non-Functional Requirements
- macOS 14+ only; Apple Silicon only.
- Menu bar app and helper remain responsive under bursty Accessibility events.
- Local logs only; no analytics telemetry.
- Errors degrade gracefully and preserve core operation where possible.

## 9. Privacy and Data Handling
- Store only operational state needed for restore.
- No remote event analytics.
- Do not upload document contents.
- Local temp artifacts may include force-saved Office files.
- Direct backend stores only email/session/subscription metadata required for entitlement enforcement.

## 10. Monetization Requirements
### App Store (MAS)
- StoreKit 2 subscription group with:
  - monthly (`$5`)
  - yearly (`$50`)
- Both configured with 14-day introductory trial.

### Direct Distribution
- Stripe products mirror MAS pricing.
- 14-day trial is enforced server-side per verified user identity.
- Email magic-link auth for entitlement retrieval.
- Entitlement backend on Cloudflare Worker with D1/KV and Resend.
- New purchases use Worker-hosted pricing plus Stripe Checkout Sessions after verified sign-in.
- Existing paid subscriptions are managed through Stripe Billing Portal.
- Checkout converts remaining Direct trial time into Stripe-supported trial settings so billing starts after the unused trial window.
- Backend free-pass allowlist via verified session identity.

## 11. Success Metrics
- >= 95% successful restore attempts for saved docs in W/E/P under supported conditions.
- <= 1% duplicate-open incidents after dedupe.
- < 5% helper crash/error rate in internal test runs.
- Free-pass bypass resistance improved by server-authoritative enforcement.

## 12. Launch Criteria (v1)
1. Required menu actions implemented and functional.
2. W/E/P document-level restore works for saved docs.
3. Untitled force-save and restore lifecycle implemented.
4. Accessibility-first capture works when granted; degraded behavior is clear when denied.
5. Outlook relaunch-only behavior works.
6. OneNote remains unsupported (no dedicated menu row).
7. Billing/account flows exist for MAS and Direct.
8. Direct `.pkg` installer installs/upgrades Direct builds cleanly and blocks MAS/Direct cross-channel overwrite.
9. Production Direct flow does not accept local free-pass or fake-session bypass inputs.
10. Debug local flow exists without weakening Release behavior.
11. Copilot review workflow documented and PR metadata captured.

## 13. Risks and Mitigations
### Risk 1: MAS automation review constraints
- Impact: reduced automation permissions.
- Mitigation: explicit App Review risk documentation and Direct fallback channel.

### Risk 2: Office scripting inconsistencies
- Impact: adapter failures or reduced restore fidelity.
- Mitigation: per-app adapter isolation, defensive parsing, partial-restore tolerance.

### Risk 3: Untitled force-save side effects
- Impact: user surprise from changed title/path.
- Mitigation: clear docs and recoverability-first behavior.

### Risk 4: Channel collision in `/Applications/Office Resume.app`
- Impact: Direct installer could overwrite MAS app (or vice versa) if not guarded.
- Mitigation: install-time channel conflict check and explicit uninstall-first UX.

### Risk 5: Direct entitlement security bypass attempts
- Impact: unpaid users enabling premium features.
- Mitigation: remove production local bypasses; enforce backend-authoritative sign-in, trial, and free-pass.

### Risk 6: Installer/update regressions
- Impact: failed app upgrades or orphan processes.
- Mitigation: pkg update tests, postinstall process-management checks.

### Risk 7: Direct email delivery or callback misconfiguration
- Impact: users cannot complete sign-in.
- Mitigation: explicit service setup docs, debug-only local shortcut path, callback URL tests.

## 14. Open Questions for Future Versions (Not Blocking v1)
- OneNote support feasibility via alternative APIs.
- Optional per-app restore policies.
- Cross-channel entitlement linking.
- Stronger device binding for Direct entitlement.
