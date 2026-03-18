# Office Resume - Intent

## Why This Exists
People who work deeply in Microsoft Office on macOS lose context too easily. A relaunch, reboot, Office update, or crash can destroy the exact working session they were in: which documents were open, what order they were in, and what window state mattered. Rebuilding that context manually is repetitive, slow, and error-prone.

Office Resume exists to make Microsoft Office on Mac behave more like a continuity-preserving workstation. The product should quietly remember the user's working set and reopen the missing pieces when Office comes back.

## Product Thesis
A standalone macOS utility can restore Office continuity reliably enough only if it uses the external signals macOS actually exposes well. For this product, that means a direct-download app that treats Accessibility as a first-class dependency, uses `NSWorkspace` for coarse lifecycle boundaries, and uses Office scripting selectively to resolve canonical document state and execute restore.

The project should optimize for restore reliability, quiet operation, and clean paid distribution. It should not optimize for Mac App Store compatibility if that forces a weaker technical architecture.

## Intended User
- Mac users who spend large parts of the day in Word, Excel, and PowerPoint
- Professionals who regularly reopen the same working set after relaunch, reboot, travel, or update cycles
- Users who want an external utility, not Office add-ins, macros, or setup inside each Office app
- Enterprises that can deploy a signed `.pkg` and manage privacy permissions centrally

## Core Capabilities
- `CAP-001`: Detect meaningful Office app/window changes externally and keep a latest recoverable snapshot
- `CAP-002`: Reopen only the missing documents from the last recoverable snapshot after relaunch
- `CAP-003`: Keep the product operationally small: menu bar app, helper, quiet logs, compact account window
- `CAP-004`: Support a direct paid product with trial, subscriptions, and backend-authoritative free-pass access
- `CAP-005`: Remain enterprise-deployable through standard macOS packaging and permission management

## Hard Truths
- A no-add-in, no-AX, sandbox-constrained architecture is not strong enough for the reliability bar this product wants
- The Mac App Store is not the primary constraint for v1
- Accessibility permission is a product requirement, not an implementation detail
- Outlook support is necessarily weaker than Word, Excel, and PowerPoint in v1
- OneNote is out of scope in v1

## What This Is Not
- Not a general office automation platform
- Not a cloud-sync product
- Not a remote analytics product
- Not a macro or VBA toolkit
- Not a Mac App Store-first utility

## Product Shape
Office Resume should feel like infrastructure:
- menu bar first
- mostly automatic
- quiet unless something needs attention
- explicit about permissions and restore state
- direct-download and easy to reinstall or deploy

## Success Condition
A user can quit or relaunch Word, Excel, or PowerPoint and get their working set back with minimal thought. They trust that Office Resume is quiet, local, and predictable, and they do not need to understand the underlying machinery for it to save them time every week.
