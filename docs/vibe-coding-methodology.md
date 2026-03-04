# Vibe Coding Methodology

## Goal
Define a repeatable, documentation-first workflow that improves codegen quality and makes evals objective.

This methodology is optimized for:
- Fast iterative product building with LLM agents
- Low-context handoffs between sessions
- Clear acceptance criteria before coding starts

## Core Principle
Treat docs as executable contracts.

Code generation is phase 2. Phase 1 is creating a coherent contract stack:
1. `AGENTS.md`: guardrails, precedence, contributor workflow, non-negotiables
2. `PRD.md`: user-facing behavior and scope contract
3. `spec.md`: system architecture and implementation contract
4. `specs/*.md`: component-level contracts
5. `prompt.md`: execution instructions that reference all docs above

If code and docs disagree, docs are wrong or code is wrong. Resolve immediately.

## Canonical Order and Change Policy
Use this precedence for decisions:
1. `AGENTS.md`
2. `PRD.md`
3. `spec.md`
4. `specs/contracts.md`
5. `specs/*.md`
6. `prompt.md`

For scope changes, update docs in the same order before implementation changes.

## Workflow

### Phase 0: Scope Lock
Capture immutable decisions first:
- target users
- platform/channel constraints
- pricing/trial policy
- supported vs unsupported features
- security/privacy constraints

Output: a short "locked decisions" list.

### Phase 1: Author Contract Stack
1. Write `AGENTS.md` with mission, precedence, constraints, workflow.
2. Write `PRD.md` with goals, non-goals, user behavior, risks.
3. Write `spec.md` with architecture, interfaces, storage, algorithms, tests.
4. Split into `specs/*.md` by component when complexity grows.
5. Write `prompt.md` that tells a fresh agent to read docs first and execute.

Output: stable baseline docs with no unresolved conflicts.

### Phase 2: Consistency Pass
Run a docs consistency pass before codegen:
- every PRD requirement maps to spec sections
- every spec interface maps to owning component spec
- every critical behavior has an explicit test case
- unsupported behavior is explicit (not implied)

Output: zero ambiguity on expected v1 behavior.

### Phase 3: Codegen Execution
Run implementation from `prompt.md`.

Rules:
- no re-planning unless docs are contradictory
- follow component specs for local decisions
- keep changes scoped; update component specs when code deviates

Output: code + tests + verification summary.

### Phase 4: Eval Loops
Use three eval stages per iteration:

1. **Contract Eval (pre-code)**
- Are docs internally consistent?
- Is scope locked?
- Are acceptance criteria testable?

2. **Implementation Eval**
- Does code satisfy contract without silent scope drift?
- Do automated tests pass?
- Do manual critical-path scenarios pass?

3. **Regression Eval**
- Do changes preserve locked constraints?
- Are docs and code still aligned?

## Eval Rubric
Score each dimension 0-2:
- `0`: missing or contradictory
- `1`: partially satisfied
- `2`: complete and testable

Dimensions:
- Scope fidelity
- Requirement coverage
- Architecture correctness
- Interface stability
- Test completeness
- Operational readiness
- Documentation alignment

Suggested gate:
- No dimension below `1`
- At least 80% of maximum score

## When to Introduce Component Specs
Add or split `specs/*.md` when any of these apply:
- one component exceeds ~500 lines of non-trivial logic
- one component has external integrations (billing, XPC, OS permissions)
- frequent context-window truncation during implementation
- independent parallel workstreams are needed

Use one component spec per folder/module boundary.

## Repo-Specific Execution Pattern
For this repository:
1. Keep `AGENTS.md`, `PRD.md`, `spec.md`, and `specs/*.md` as the source of truth.
2. Use `prompt.md` only as the execution launcher for fresh sessions.
3. For any behavior change:
- update docs first
- implement
- run tests
- run local functional checklist
- update docs if behavior changed during implementation

## Quick Start Checklist
- [ ] Locked decisions list exists
- [ ] `AGENTS.md` up to date
- [ ] `PRD.md` up to date
- [ ] `spec.md` up to date
- [ ] component specs up to date
- [ ] `prompt.md` references all required docs
- [ ] test matrix covers critical flows
- [ ] eval rubric applied and recorded

