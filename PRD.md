# Office Resume v1 - Product Requirements Document

## 1. Problem Statement
Microsoft Office for Mac does not reliably restore a real working session after relaunch, reboot, update, or crash. Users lose open-document continuity and reconstruct context manually.

For a standalone external app without Office add-ins, the only robust v1 path on macOS is a direct-download architecture built around Accessibility events plus targeted Office scripting. The previous sandboxed no-AX design cannot observe Office document/window changes reliably enough for the product bar.

Office Resume restores continuity by observing Office app/window behavior externally, capturing the latest recoverable session state, and reopening the missing work automatically.

## 2. Target Users
- Individual professionals and small teams who live in Word, Excel, and PowerPoint on macOS
- Knowledge workers managing many Office documents across relaunches, reboots, and update cycles
- Consultants, operators, and enterprise users who want reliable Office continuity without installing Office add-ins or macros

## 3. Product Goals
1. Restore Office work context automatically and reliably after relaunch.
2. Optimize for actual restoration reliability, not Mac App Store compatibility.
3. Keep user-visible controls small, operational, and quiet.
4. Provide a real billing/account experience for the Direct product.
5. Support monetization with a 14-day trial and recurring subscription.
6. Keep privacy strong: local-only operational logs and no analytics telemetry.
7. Ship a standard Direct installer experience using a signed/notarized `.pkg`.

## 4. Non-Goals (v1)
- Mac App Store distribution
- Shared runtime parity with MAS
- Office add-ins, VBA, or macros
- OneNote restore support
- Outlook item/message-level reconstruction
- Cloud sync of snapshots across devices
- Reverse-engineering Apple's private Resume binary format

## 5. Scope and Support Matrix
### In Scope
- Word document-level capture/restore
- Excel workbook-level capture/restore
- PowerPoint presentation-level capture/restore
- Outlook lifecycle capture + relaunch-only restore
- Menu bar controls and compact account window
- Login helper daemon for background operation
- Accessibility-first capture
- Direct distribution via standard `.pkg` installer
- Backend-authoritative friends-and-family free-pass
- Enterprise-friendly direct deployment path

### Out of Scope
- `OfficeResumeMAS` as a shipping product target
- OneNote automation-based restore
- Outlook item/window reconstruction beyond relaunch
- Client-side production free-pass activation via local files/env overrides

## 6. Core User Experience
### 6.1 First-Run Setup
- App installs as a standard Direct `.pkg`.
- App launches as a menu bar app and registers the helper login item.
- App clearly asks for Accessibility permission because AX is required for capture.
- Apple Events consent is requested lazily when Office state must actually be queried or restored.
- Repeated Accessibility or Apple Events prompt storms are a bug.

### 6.2 Background Behavior
- App auto-starts at login.
- Helper tracks Office launches, terminations, activation, and deactivation via `NSWorkspace`.
- Helper attaches AX observers to supported Office processes while they are running.
- Helper treats AX notifications as the primary event source for capture scheduling.
- Helper uses Office scripting only to resolve canonical Office state after meaningful external events.
- Helper may run a sparse safety reconciliation sweep only as a backup, not as the primary capture model.

### 6.3 Restore Behavior
- Global restore policy applies to all supported apps.
- Restore runs once per app launch instance.
- If Office already restored some docs, Office Resume opens only missing snapshot docs.
- Partial failures are tolerated and logged; successful items still restore.
- Outlook restore is relaunch-only.

### 6.4 Menu Bar Controls
Required controls:
- `Accessibility: OK` or `Accessibility: click to fix`
- `Autostart: OK` or `Autostart: click to fix`
- `Pause Tracking` / `Resume Tracking`
- `Restore Now`
- `Advanced > Clear Snapshot`
- `Advanced > Open Debug Log in Console`
- `Account…`
- `Quit`

Required display:
- helper connection status
- Accessibility setup/remediation state
- autostart health/remediation state
- paused-state feedback when tracking is paused

The main menu does not show entitlement detail tables or recent-event lists in v1.

### 6.5 Account Window
Direct only:
- Signed-out state shows email entry, `Send Sign-In Link`, pricing/trial copy, and verified-email requirement note.
- Signed-in state shows signed-in email, current entitlement/trial status, relevant dates, `Refresh Status`, context-appropriate billing action, and `Sign Out`.
- Signed-in non-paid users see `Choose Plan…`, which opens a Worker-hosted pricing page and then Stripe Checkout.
- Signed-in paid users see `Manage Subscription`, which opens Stripe Billing Portal.
- Free-pass users do not see a paid billing action.

## 7. Functional Requirements
### FR-1 Direct-Only Product Contract
- `OfficeResumeDirect` is the only shipping app target for v1.
- Existing MAS-related code may remain temporarily during migration but is not part of the active product contract.
- Release docs, tests, and packaging must target Direct only.

### FR-2 Accessibility-First Capture
- Capture depends on Accessibility / AX observers.
- Supported Office apps are observed through per-process AX subscriptions while running.
- Capture must not rely on AppleScript polling as the primary event source.
- `NSWorkspace` is used only for coarse lifecycle/session boundaries.

### FR-3 Lifecycle and Snapshot Capture
- Persist minimal lifecycle events locally.
- Capture state for Word, Excel, and PowerPoint after meaningful AX-driven app/window changes.
- Run scripted reconciliation at least on:
  - app launch stabilization
  - relevant AX change notifications
  - app deactivate / focus loss boundaries
  - session resign-active handling
  - sparse safety sweep while frontmost, only as backup
- Never rely on app termination as the final capture point.

### FR-4 Document/Window Capture
- Word/Excel/PowerPoint: capture open documents with path, name, and saved state.
- Outlook: capture lifecycle plus limited window metadata only.
- OneNote: no document capture and no restore.
- Snapshot updates must be coalesced and deduplicated.

### FR-5 Snapshot Persistence
- Maintain latest snapshot only per Office app.
- Persist local events and restore markers.
- Use a direct-only storage layout under `~/Library/Application Support/com.pragprod.msofficeresume/`.
- Local logs remain available for user-visible debugging and are trimmed to the most recent 24 hours.

### FR-6 Untitled Document Handling
- For Word/Excel/PowerPoint untitled docs, force-save to temporary artifacts when needed for recoverability.
- Track mapping metadata from source session to temp artifact.
- Reopen temp artifacts during restore when applicable.
- Purge artifacts when no longer referenced.

### FR-7 Restore Execution
- Auto-run restore on Office relaunch for supported apps.
- Dedupe against currently open docs.
- Apply one-shot marker per launch instance.
- Log per-item success/failure locally.
- Outlook restore action is app relaunch only.

### FR-8 Accessibility and Automation UX
- Menu surfaces Accessibility status and remediation.
- `Accessibility: click to fix` asks the helper to prompt for Accessibility trust and opens the relevant System Settings pane if needed.
- App must not repeatedly re-prompt for Accessibility after the user has already granted it to the current signed build.
- Apple Events consent must be bounded; a single focus/permission churn loop must not fan out into repeated dialogs.

### FR-9 Autostart Visibility
- Menu surfaces autostart status:
  - `Autostart: OK` when main app and helper login-item registration are healthy
  - `Autostart: click to fix` when not healthy
- `Autostart: click to fix` opens Login Items settings.

### FR-10 Entitlement and Gating
- 14-day trial.
- Paid plans: `$5/mo` and `$50/yr`.
- On inactive entitlement: monitoring/restore disabled, logs/status remain readable.
- Offline grace: keep paid/trial features active up to 7 days from last successful validation.
- Direct trial begins only after verified sign-in.

### FR-11 Distribution and Billing
- `OfficeResumeDirect`: Stripe subscriptions, server-side trial, email magic-link auth, Cloudflare entitlement backend, Resend email delivery.
- New purchases use Worker-hosted pricing plus Stripe Checkout Sessions after verified sign-in.
- Existing paid subscriptions are managed through Stripe Billing Portal.
- Checkout converts remaining Direct trial time into Stripe-supported trial settings so billing starts after the unused trial window ends.

### FR-12 Free-Pass Security
- Free-pass for owner/internal users is granted server-side only in the Direct backend.
- Free-pass decision requires verified session identity and backend allowlist.
- The backend must support a checked-in hard-coded allowlist plus env-based extensions.
- Production app must not grant free-pass from local files/env toggles.

### FR-13 Direct Installer Experience
- Direct release artifact is a standard `.pkg` installer.
- Installing a newer `.pkg` updates an existing Direct install cleanly.
- Installed visible app path is `/Applications/Office Resume.app`.
- Helper is packaged as an embedded login item inside the main app and must not appear as a separate top-level app in `/Applications`.
- Installer should restart or relaunch the app cleanly after update.
- Required runtime permissions are prompted on first launch/use, not during install.

### FR-14 Enterprise Direct Path
- The Direct `.pkg` is suitable for enterprise deployment.
- The product is compatible with MDM deployment, login-item management, and PPPC/TCC approval workflows.
- The product does not require sandboxing for enterprise distribution.

### FR-15 Local Debug Usability
- Developers can build and run a Debug version locally without Apple Developer signing.
- Debug builds use the same packaged install flow and backend-authoritative entitlement behavior as Release builds.

## 8. Non-Functional Requirements
- macOS 14+ only; Apple Silicon only.
- Menu bar app and helper remain responsive under AX event bursts, permission churn, relaunches, and restore retries.
- Local logs only; no analytics telemetry.
- Errors degrade gracefully and preserve core operation where possible.
- Shipping Direct build is unsandboxed and Developer ID signed.

## 9. Privacy and Data Handling
- Store only operational state needed for restore.
- No remote event analytics.
- Do not upload document contents.
- Local temp artifacts may include force-saved Office files.
- Direct backend stores only email, session, and subscription metadata required for entitlement enforcement.

## 10. Monetization Requirements
### Direct Distribution
- Stripe products:
  - monthly (`$5`)
  - yearly (`$50`)
- 14-day trial is enforced server-side per verified user identity.
- Email magic-link auth for entitlement retrieval.
- Entitlement backend on the unified `office-resume` Cloudflare Worker with D1/KV and Resend.
- Static site and backend share the same Worker deployment; public API routes live under `/api/*`.
- New purchases use Worker-hosted pricing plus Stripe Checkout Sessions after verified sign-in.
- Existing paid subscriptions are managed through Stripe Billing Portal.
- Backend free-pass allowlist uses verified session identity.

## 11. Success Metrics
- >= 95% successful restore attempts for saved docs in Word, Excel, and PowerPoint under supported conditions.
- <= 1% duplicate-open incidents after dedupe.
- < 5% helper crash or error rate in internal test runs.
- No repeated Apple Events or Accessibility prompt storms in normal signed builds.

## 12. Launch Criteria (v1)
1. Required menu actions implemented and functional.
2. Word, Excel, and PowerPoint document-level restore works for saved docs.
3. Untitled force-save and restore lifecycle implemented.
4. AX-first capture works and no longer depends on the deprecated no-AX polling architecture.
5. Outlook relaunch-only behavior works.
6. OneNote remains unsupported.
7. Direct billing/account flow works.
8. Direct `.pkg` installer installs/upgrades cleanly.
9. Production Direct flow does not accept local free-pass or fake-session bypass inputs.
10. Debug local packaging uses the same downloaded-package install path and entitlement flow as Release behavior.
11. Copilot review workflow documented.
12. Accessibility flow works and does not reprompt endlessly.
13. Apple Events consent remains bounded under focus churn.

## 13. Risks and Mitigations
### Risk 1: Accessibility dependency raises setup friction
- Impact: users must grant AX before capture works.
- Mitigation: explicit first-run setup, clear menu remediation, enterprise PPPC path.

### Risk 2: Office scripting inconsistencies
- Impact: adapter failures or reduced restore fidelity.
- Mitigation: per-app adapter isolation, defensive parsing, partial-restore tolerance, AX-driven event selection before scripting.

### Risk 3: Untitled force-save side effects
- Impact: user surprise from changed title/path.
- Mitigation: clear docs and recoverability-first behavior.

### Risk 4: TCC and automation prompt churn
- Impact: degraded UX and unreliable monitoring.
- Mitigation: signed release identity, AX-first eventing, bounded Apple Events usage, strict event/command serialization, no tight scripting loops.

### Risk 5: Direct entitlement security bypass attempts
- Impact: unpaid users enabling premium features.
- Mitigation: remove production local bypasses; enforce backend-authoritative sign-in, trial, and free-pass.

### Risk 6: Installer/update regressions
- Impact: failed app upgrades or orphan processes.
- Mitigation: pkg update tests, postinstall process-management checks.

### Risk 7: Direct email delivery or callback misconfiguration
- Impact: users cannot complete sign-in.
- Mitigation: explicit service setup docs, callback URL tests, backend allowlist for internal free-pass accounts.

## 14. Open Questions For Future Versions
- Whether a later MAS-compatible product should exist at all
- Whether Outlook should ever go beyond relaunch-only support
- Whether a Windows product should live in a separate repo
- Whether enterprise deployment docs should include sample PPPC payloads
