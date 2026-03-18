# Decision Memo - Direct-Only AX Architecture

## Decision
As of March 17, 2026, Office Resume v1 standardizes on a Direct-only macOS architecture built around Accessibility events, `NSWorkspace` lifecycle boundaries, and selective Office scripting.

The project is no longer constrained by Mac App Store compatibility for the v1 shipping contract.

## Why The Previous Direction Was Rejected
The previous target architecture tried to preserve one runtime across Direct and MAS while avoiding Accessibility. That architecture is not strong enough for the actual product promise.

The failure is structural, not just an implementation bug:
- `NSWorkspace` gives coarse app lifecycle signals, not Office document/window lifecycle.
- External Apple Events let us query Office state, but they are request/response only, not a subscribable document/window event stream.
- The richer Office events Microsoft documents live inside Office through VBA or add-in models, which this product intentionally does not want to depend on.
- Microsoft documents that event-based Office add-ins for Word, Excel, and PowerPoint are not supported on Office for Mac.
- Apple DTS guidance indicates App Sandbox and Accessibility are fundamentally at odds for this use case.
- Repeated TCC and automation prompt churn is a practical reliability problem when the product depends on frequent scripted polling instead of stronger external events.

Under those constraints, a standalone helper cannot observe the final Office session state with enough fidelity to make restore reliable. Polling more often only reduces miss probability while increasing fragility and prompt churn.

## Resulting Product Direction
v1 becomes:
- Direct download only
- Developer ID signed and notarized `.pkg`
- unsandboxed release runtime
- Accessibility-first capture
- `NSWorkspace` as secondary lifecycle/session input
- Office scripting as tertiary state resolver and restore execution path
- Word, Excel, and PowerPoint as the full-fidelity targets
- Outlook in limited relaunch-only mode
- OneNote unsupported

## Product Consequences
This decision intentionally changes the product contract:
- Accessibility permission becomes required and visible in the UI.
- The menu regains explicit Accessibility state and remediation.
- App-group-first sandbox storage assumptions are removed from the primary design.
- MAS-specific runtime parity is no longer a governing rule.
- Enterprise distribution becomes easier to justify because direct `.pkg` + PPPC/MDM is a cleaner fit than a weaker MAS-compatible runtime.

## What Stays The Same
- Menu bar app + helper structure
- local-only operational logs
- latest-snapshot restore model
- duplicate guard and one-shot restore markers
- Direct billing/auth/backend model
- Worker-hosted pricing + Stripe Checkout Sessions + Billing Portal
- backend-authoritative free-pass allowlist

## Sources That Drove This Decision
Apple:
- [NSWorkspace lifecycle notifications](https://developer.apple.com/documentation/appkit/nsworkspace)
- [User switch notifications](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/UserSwitchNotifications.html)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [QA1888: Sandboxing and Automation in OS X](https://developer.apple.com/library/archive/qa/qa1888/_index.html)
- [Apple Developer Forums: App Sandbox blocks Accessibility APIs for this class of app](https://developer.apple.com/forums/thread/789896)
- [Apple Developer Forums: related sandboxed accessibility discussion](https://developer.apple.com/forums/thread/810677)

Microsoft:
- [Word `DocumentOpen`](https://learn.microsoft.com/en-us/office/vba/api/word.application.documentopen)
- [Excel `WorkbookOpen`](https://learn.microsoft.com/en-us/office/vba/api/excel.application.workbookopen)
- [PowerPoint `PresentationOpen`](https://learn.microsoft.com/en-us/office/vba/api/powerpoint.application.presentationopen)
- [Office for Mac VBA overview](https://learn.microsoft.com/en-us/office/vba/api/overview/office-mac)
- [Event-based activation limitations on Office for Mac](https://learn.microsoft.com/en-us/office/dev/add-ins/develop/event-based-activation)

VibeLoom framing:
- [VibeLoom home](https://vibeloom.ai/)
- [VibeLoom methodology](https://vibeloom.ai/methodology)
