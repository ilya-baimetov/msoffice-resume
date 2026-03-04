# Office Resume v1 - Product Requirements Document

## 1. Problem Statement
Microsoft Office for Mac does not reliably provide macOS-style Resume behavior across apps and document types. Users lose context after app restarts, crashes, machine reboots, or routine relaunches.

Office Resume restores user continuity by capturing Office state in the background and reopening prior work automatically.

## 2. Target Users
- Individual professionals who use Office heavily on macOS
- Knowledge workers managing multiple documents/presentations/workbooks
- Users expecting native Resume-style workflow continuity

## 3. Product Goals
1. Restore Office work context automatically on app relaunch.
2. Mimic native Resume behavior conventions where feasible on macOS.
3. Provide lightweight menu bar controls with minimal interruption.
4. Support monetization with a 14-day trial and recurring subscription.
5. Keep privacy strong: local-only logs and no analytics telemetry in v1.

## 4. Non-Goals (v1)
- Full OneNote restoration support
- Outlook message-level/window object restoration
- Cloud sync of snapshots across devices
- Team accounts or cross-channel purchase linking
- Reverse-engineering Apple's private Resume binary format

## 5. Scope and Support Matrix
### In Scope
- Word document-level capture/restore
- Excel workbook-level capture/restore
- PowerPoint presentation-level capture/restore
- Outlook lifecycle capture + relaunch-only restoration
- Menu bar controls and status/log visibility
- Login helper daemon for background operation
- MAS and direct distribution variants

### Out of Scope
- OneNote automation-based restore (explicitly unsupported in v1)
- Per-app restore policies (global policy only in v1)

## 6. Core User Experience
### 6.1 Background Behavior
- App auto-starts at login.
- Helper tracks Office app launches/quits via `NSWorkspace` and document/window changes via Accessibility notifications (`AXObserver`) as the primary source.
- On Office relaunch, restore is attempted automatically.

### 6.2 Restore Behavior
- Global policy applies to all supported apps.
- Restore runs once per app launch instance (one-shot marker).
- If Office already restored some docs, Office Resume opens only missing snapshot docs.
- Partial failures are tolerated and logged; successful items still restore.

### 6.3 Menu Bar Controls
Required actions:
- `Restore now`
- `Pause tracking`
- `Clear snapshot`

Required display:
- Tracking status
- Accessibility permission status and remediation guidance
- Current entitlement status
- Recent local restore/log events
- OneNote marked as unsupported

## 7. Functional Requirements
### FR-1 Lifecycle Capture
- Capture app launch and quit events for Word/Excel/PowerPoint/Outlook/OneNote.
- Persist minimal event records locally.

### FR-2 Document/Window Capture (Accessibility-First)
- Use Accessibility notifications as the primary trigger for open/close/focus/title transitions and infer document/window transitions from those events.
- Word/Excel/PowerPoint: capture open documents with path/name/saved state using adapter fetch after AX-triggered capture.
- Outlook: capture basic window metadata only.
- OneNote: no document capture; show unsupported status.
- If Accessibility permission is not granted, degrade to lifecycle-only mode with explicit UI warning.

### FR-3 Snapshot Persistence
- Maintain latest snapshot only per supported Office app.
- Write to native-like saved-state directories using custom schema:
  - `snapshot-v1.json`
  - `events-v1.ndjson`
  - `unsaved-index-v1.json`
  - `unsaved/`

### FR-4 Untitled Document Handling
- For Word/Excel/PowerPoint untitled docs, periodically force-save to temp artifacts.
- Track mapping metadata from source doc/session to temp path.
- Reopen temp artifacts as part of restore flow.
- Purge artifacts when no longer needed by active/latest snapshot lifecycle.
- Side effect (untitled becomes saved temp file) is acceptable.

### FR-5 Restore Execution
- Auto-run restore on every relaunch for supported apps.
- Dedupe by comparing currently open docs to snapshot list.
- Apply one-shot marker per launch instance.
- Log successes/failures locally.

### FR-6 Entitlement and Gating
- 14-day free trial.
- Paid plans: `$5/mo` and `$50/yr`.
- On inactive entitlement: disable monitoring and restore, keep history view read-only.
- Offline grace: keep paid/trial features active for up to 7 days since last valid check.

### FR-7 Distribution Variants
- `OfficeResumeMAS`: StoreKit 2 subscriptions/trial.
- `OfficeResumeDirect`: Stripe subscriptions/trial + email magic link + Cloudflare entitlement backend.
- No purchase linking between channels in v1.

## 8. Non-Functional Requirements
- macOS 14+ only; Apple Silicon only.
- Menu bar app and helper should remain responsive under bursty Accessibility event traffic.
- All logs stored locally; no remote analytics.
- Errors should degrade gracefully and keep app operational.

## 9. Privacy and Data Handling
- Store only operational state needed for restore.
- No remote event analytics.
- Do not upload document content.
- Local files may include temp force-saved documents in user storage paths.

## 10. Monetization Requirements
### App Store (MAS)
- StoreKit 2 subscription group with two products:
  - monthly (`$5`)
  - yearly (`$50`)
- Both configured with 14-day introductory trial.

### Direct Distribution
- Stripe products and prices mirroring MAS plans.
- Trial period of 14 days.
- Email magic-link auth for entitlement retrieval.
- Entitlement backend on Cloudflare Worker with D1/KV.

## 11. Success Metrics
- >= 95% successful restore attempts for saved docs in W/E/P under supported conditions.
- <= 1% duplicate-open incidents after restore dedupe logic.
- < 5% crash/error rate in helper process over internal test runs.
- Trial-to-paid conversion and churn tracked only through billing providers, not behavioral analytics.

## 12. Launch Criteria (v1)
1. All required menu actions implemented and functional.
2. W/E/P document-level restore works for saved docs.
3. Untitled force-save and restore lifecycle implemented.
4. Accessibility-first capture works when permission is granted, and degraded mode behavior is clear when denied.
5. Outlook limited relaunch behavior works.
6. OneNote unsupported state clearly exposed.
7. Entitlement gating and offline grace validated for MAS and direct flows.
8. Local-only logging/privacy constraints validated.

## 13. Risks and Mitigations
### Risk 1: MAS Apple Events/App Review constraints
- Impact: reduced cross-app automation permissions.
- Mitigation: direct channel fallback and explicit MAS review documentation.

### Risk 2: Office scripting inconsistencies across versions
- Impact: adapter failures or reduced restore fidelity.
- Mitigation: per-app adapter isolation, defensive parsing, graceful partial restore.

### Risk 3: Untitled force-save side effects
- Impact: user surprise due to file title/path changes.
- Mitigation: clear documentation and recoverability-first behavior.

### Risk 4: Billing complexity across two channels
- Impact: increased maintenance burden.
- Mitigation: shared entitlement abstraction, channel-specific provider implementations.

### Risk 5: Accessibility permission adoption
- Impact: users may decline Accessibility access, reducing capture fidelity.
- Mitigation: clear first-run guidance, visible permission status in menu, graceful degraded mode fallback.

## 14. Open Questions for Future Versions (Not Blocking v1)
- OneNote support feasibility via other automation channels.
- Optional per-app restore policies.
- Cross-channel entitlement linking.
- Optional secure encryption for temp artifacts.
