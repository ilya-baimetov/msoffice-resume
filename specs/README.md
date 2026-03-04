# Component Specs Index

This folder contains component-scoped technical specs to keep implementation contexts small and deterministic.

## Read Order
1. `AGENTS.md`
2. `PRD.md`
3. `spec.md` (system-level contract)
4. `specs/contracts.md` (cross-component interface contract)
5. Relevant component spec(s) in this folder
6. `prompt.md`

## Component Mapping
- `specs/core.md`
  - Owns `Sources/OfficeResumeCore/**` and `Tests/OfficeResumeCoreTests/**`.
- `specs/helper-daemon.md`
  - Owns `Sources/OfficeResumeHelper/**`.
- `specs/menu-ui.md`
  - Owns `Sources/OfficeResumeDirect/**`, `Sources/OfficeResumeMAS/**`, and `Sources/MenuUIShared/**`.
- `specs/backend-worker.md`
  - Owns `OfficeResumeBackend/**`.

## Boundary Rule
Component specs can add detail, but cannot contradict `spec.md` or `specs/contracts.md`.
