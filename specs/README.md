# Component Specs Index

This folder contains component-scoped technical specs to keep implementation contexts small and deterministic.

## Read Order
1. `AGENTS.md`
2. `intent.md`
3. `PRD.md`
4. `spec.md` (system-level contract)
5. `specs/contracts.md` (cross-component interface contract)
6. relevant component spec(s) in this folder
7. `prompt.md`

## Component Mapping
- `specs/core.md`
  - Owns `Sources/OfficeResumeCore/**` and `Tests/OfficeResumeCoreTests/**`.
- `specs/helper-daemon.md`
  - Owns `Sources/OfficeResumeHelper/**`.
- `specs/menu-ui.md`
  - Owns `Sources/OfficeResumeDirect/**` and `Sources/MenuUIShared/**`.
- `specs/backend-worker.md`
  - Owns `OfficeResumeBackend/**`.

Legacy note:
- `Sources/OfficeResumeMAS/**` may remain in the repository during migration, but it is not part of the active v1 shipping contract.

## Boundary Rule
Component specs can add detail, but cannot contradict `spec.md` or `specs/contracts.md`.
