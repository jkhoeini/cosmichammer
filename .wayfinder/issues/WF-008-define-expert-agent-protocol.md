---
id: WF-008
title: Define the expert-agent execution and independent review protocol
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by: []
---

## Question

Define per-slice architecture, implementation, test-oracle, adversarial-review, and integration responsibilities; required handoff artifacts; overlap coordination; and evidence gates for the parallel agent team. “Independent oracle review” must mean grounding assertions in locked pre-migration behavior or having the independent test specialist author/approve new assertions—not merely reviewing implementation and tests authored together. Require each slice touching an existing real-I/O boundary to exercise its relevant loopback or production complement before final convergence.

## Resolution comments

### 2026-07-29 — Separate authorship, evidence, attack, and convergence

Use five named roles. A person or agent may own the same role across multiple non-overlapping slices, but role separation within a slice follows the independence rules below.

| Role | Responsibility | Forbidden work |
|---|---|---|
| Architecture owner | Freezes shared interfaces, invariants, dependency order, risk class, and file ownership before fan-out; arbitrates contract changes. | May not silently revise an active slice contract. |
| Slice owner | Changes only the assigned production files and approved test harness; produces local evidence and the handoff packet. | May not edit shared registry inputs/outputs, `Package.swift`, another slice, or author/approve new oracle assertions. |
| Oracle owner | Locks pre-migration observations and independently authors or approves every new behavioral assertion before relying on it. | May not implement production code in that slice or accept implementation-derived expectations as evidence. |
| Adversarial reviewer | Attacks failure modes, lifecycle, negative space, determinism, stack/type invariants, and real-I/O coverage after local evidence exists. | May not self-review implementation or replace missing evidence with code inspection. |
| Integration owner | Solely edits shared/generated artifacts, integrates in dependency order, regenerates outputs, runs convergence gates, and records the integration receipt. | May not waive oracle, review, deterministic, or real-I/O failures. |

The architecture and integration roles may be held by one owner. A slice owner is never its oracle owner or adversarial reviewer. Oracle owner and adversarial reviewer must be distinct for userdata, lifecycle, callback, scheduling/concurrency, cross-module, and real-I/O slices. They may be the same person only for a pure table-builder slice whose assertions are entirely locked pre-migration evidence; this exception must be declared in the slice brief.

#### Required artifacts

1. **Slice brief, before fan-out:** exact owned files and symbols; forbidden shared files; prerequisites; frozen interfaces and invariants; risk class; deterministic, fault, lifecycle, and real-I/O obligations; acceptance commands; assigned role owners.
2. **Oracle ledger, before implementation:** each assertion mapped to an existing test, captured pre-migration output/fixture, or independently authored assertion; capture command, environment, and expected result; oracle-owner approval. Reviewing tests coauthored with implementation does not establish independence.
3. **Handoff packet:** workspace/change identity; exact touched files; commands and unabridged results; replay seed/configuration where applicable; stack/type/module-loading and owned-file annotation census; relevant loopback or production receipt; known failures and contract deviations.
4. **Review verdict:** reviewer identity, artifacts inspected, adversarial scenarios exercised, blocker-only findings, and pass/fail. Findings return to the slice owner; the reviewer does not patch around them.
5. **Integration receipt:** accepted slices and order, shared/generated changes, conflict decisions, regenerated parity, final deterministic/real-I/O receipts, Release and symbol evidence, `just verify`, and application smoke result.

#### Coordination contract

- Assign disjoint writable file sets before dispatch. Shared interfaces, manifest semantics, generator, generated outputs, `Package.swift`, and common bridge directories have one integration owner.
- Slice agents skip project-wide validation. They run only their brief's bounded checks so concurrent work cannot invalidate another agent's result; integration owns the full gate.
- Frozen interfaces are message-level contracts. A discovered mismatch stops the affected slice, goes to the architecture owner, and is broadcast before work resumes; agents never negotiate incompatible local variants through overlapping edits.
- Unexpected overlap stops both writers. The architecture owner reallocates ownership or integration serializes the change. No agent edits another workspace to resolve it.
- Every command is bounded. After three failed fix/review rounds, return the slice as blocked with root cause and evidence rather than looping or weakening assertions.

#### Evidence gates

1. **Ready:** ownership is disjoint, prerequisites closed, baseline behavior captured, oracle ledger approved, and required real-I/O environment identified.
2. **Slice:** scoped build/tests pass without warnings; positive and negative invariants hold; deterministic runs replay from recorded inputs; every owned `@_cdecl` removal is counted; no forbidden file changed.
3. **Boundary:** a slice touching an existing real-I/O boundary exercises the closest existing loopback or production complement through the same production path. Simulation, mocks, or source inspection cannot substitute. Unavailable hardware/access blocks convergence and becomes an explicit integration action rather than an implicit waiver.
4. **Independent acceptance:** oracle owner confirms behavior against the ledger; adversarial reviewer passes the slice. An oracle changed after implementation requires fresh independent approval and rerunning both baseline comparison and slice evidence.
5. **Handoff:** packet and verdict are complete; no unresolved blocker or contract deviation remains; integration accepts custody.
6. **Convergence:** integration applies dependency order, regenerates once, proves manifest/generated parity, runs deterministic replay and liveness gates, collects every real-I/O receipt, verifies Release dead-strip/symbol behavior, runs `just verify`, smoke-tests the application, and proves no project-owned `@_cdecl` remains in source or linked artifacts.

This protocol defines execution ownership only. Exact slice membership belongs to the existing partition tickets; exact deterministic budgets and fault profiles belong to the deterministic-gates ticket; exact convergence commands belong to the convergence-plan ticket. No new ticket is required.
