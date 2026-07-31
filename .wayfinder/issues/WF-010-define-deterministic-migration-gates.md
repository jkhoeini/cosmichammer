---
id: WF-010
title: Define TigerStyle and deterministic migration gates
state: closed
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee: Main
blocked_by: []
---

## Question

Resolve the migration-specific choices left after the project’s documented TigerStyle and DST principles: fixed epoch and deterministic identity inputs, explicit liveness budget and failure signal, per-slice fault-profile triage, assertion-pair vocabulary, and the mapping from changed boundaries to deterministic and real-I/O evidence. Record unrelated pre-existing simulator debt separately rather than making it an implicit prerequisite.

## Resolution comments

### 2026-07-29 — Replay explicit inputs; fail bounded progress visibly

Treat a **migration scenario** as one production path plus its locked observations. Its deterministic receipt is fully identified by `SimulationRunInputs(seed:epochSeconds:identitySeed:)`; the canonical migration values are seed `42`, epoch `978_307_200` (`2001-01-01T00:00:00Z`, matching Foundation's reference date), and identity seed `42`. Fault PRNG state and identity allocation are separate streams. Observable synthetic identities come from `(identitySeed, namespace, ordinal)`, never `UUID()`, process-randomized hashing, memory addresses, or fault-RNG consumption. Dates included in a deterministic trace come from the simulated clock.

A replay gate runs the same scenario twice with the same inputs and requires byte-identical canonical observations: public Lua results/errors and Lua types, callback order, module/preload order, state-generation and registry-ref/canary counts, virtual time, pending-work counts, and only the synthetic identities the scenario intentionally observes. Wall-clock durations, addresses, OS scheduling order, and isolation-only UUIDs in real-I/O tests are excluded rather than normalized after the fact. The receipt records all three inputs, the fault profile, and the observation digest; a failure always prints enough to replay.

#### Bounded progress

Scheduling, callback, lifecycle, and async scenarios declare a completion predicate and use both limits: at most `10_000` total simulator steps—timer firings plus event-loop blocks (extending the existing event-loop bound across both schedulers)—and at most `60` seconds of virtual-time advance. The scenario cancels intentionally repeating work before its completion check. A legitimate scenario that needs more than 10,000 steps or 60 virtual seconds requires different finite step and/or time horizons declared in the slice brief before implementation; a failure never extends its own budget. A clean liveness run is separate from faulted safety runs unless the production path actually supports recovery from the injected fault.

The harness must return a structured result—`quiesced`, `stepLimitExceeded`, or `stalled`—rather than silently stop. Failure evidence includes the three run inputs, fault profile, executed-step count, simulated start/end time, pending work, last progress snapshot, and unmet completion predicate. `stepLimitExceeded` means timer or event-loop work remained after 10,000 combined steps; the prototype must therefore bound `SimulatedClock.advance(by:)` as well as `SimulatedEventLoop.drain()`. `stalled` means the predicate remained false with no executable work or before the next deadline could be reached within 60 virtual seconds. Any non-`quiesced` result fails the slice. This interface is prototyped by [Restore deterministic replay and liveness prerequisites](WF-011-restore-replay-liveness-prerequisites.md); this decision does not retrofit the simulator itself.

#### Per-slice fault triage

Apply only rows whose seam changed; running unrelated faults adds noise, not evidence.

| Changed seam | Required deterministic profile | Liveness | Real complement |
|---|---|---|---|
| Registration, table builder, pure conversion | canonical clean replay twice; locked old/new Lua result, error, type, stack, and order observations | no | none |
| Userdata, cross-module identity, registry ref, GC | clean replay; positive/negative type extraction; identity and acquire/release counts; relevant targeted constructor/teardown failure | if callbacks or scheduled teardown exist | app/runtime smoke; fixture-backed AppKit conversion when used |
| Synchronous simulated OS state or error-returning I/O | clean path plus every changed failure branch at `100%` through a proven-wired targeted `FaultConfig` field | only if work is queued | closest existing temp-file, `UserDefaults`, pasteboard, or OS integration path |
| Callback, watcher, timer, lifecycle, or async I/O | clean replay; every relevant proven-wired targeted fault; the slice scenario over swarm seeds `0..<32` with fixed epoch and identity seed | required | real run-loop or localhost complement through the same production path |
| Network/Bonjour/socket/HTTP | success, timeout/drop/connect-failure profiles; `0..<32` slice swarm; callback/order/resource invariants | required | existing `127.0.0.1`/localhost loopback |
| Hardware-only boundary | deterministic unavailable/permission/error behavior where modeled | when callbacks exist | physical-device receipt; unavailable hardware blocks convergence rather than becoming a waiver |

A targeted profile must force the branch (`1.0` or the corresponding Boolean), and the test must prove the fault knob reached the changed seam. A `FaultConfig` field merely existing is not evidence. Swarm is additional coverage, never a replacement for targeted success and failure cases. Integration replays every failing seed and each slice's canonical receipt; it does not run the whole suite under every seed.

#### Assertion-pair vocabulary

Each slice brief names the invariant and two independent check sites in local domain language; duplicated expressions at adjacent lines are one assertion, not a pair. Always cover expected positive space and the nearest plausible negative space without changing valid public Lua behavior or replacing established Lua errors with crashes.

- **descriptor / loader** — manifest identity and uniqueness at generation; `package.preload`/`require` identity, order, type, and caching at consumption;
- **producer / consumer** — pushed Swift/Lua type and metatable at creation; typed extraction and wrong-type rejection where consumed;
- **capture / invoke** — callback ref and state generation when captured; current generation, ownership, and stack balance immediately before invocation;
- **acquire / release** — registry ref, self-ref, observer, timer, or retained object count after acquisition; zero/baseline count after explicit teardown and GC;
- **request / completion** — normalized request and resource state before I/O; result/error convention, callback cardinality, and terminal state at completion;
- **encode / decode** — source type/bytes and Lua representation at push; round-trip type/bytes and documented divergence at decode.

Tests may provide one side where adding a production assertion would alter public behavior, but the oracle ledger must say so. A simulation-only assertion and a mock expectation do not jointly prove a production interface.

#### Changed-boundary evidence rule

Deterministic simulation proves logic, ordering, failure handling, identity, lifecycle, and bounded progress through the production interface. The real complement proves only what simulation replaces: Foundation/AppKit conversion with real objects, filesystem/defaults/pasteboard with isolated local resources, callbacks with the real run loop, networking with loopback, and hardware with the device. A slice that does not touch an external I/O seam needs no invented real-I/O test. A slice that does touch one cannot substitute simulation or source inspection for the closest existing complement.

#### Pre-existing simulator debt

[Restore deterministic replay and liveness prerequisites](WF-011-restore-replay-liveness-prerequisites.md) owns only the minimum gate-critical prototype: `SimulatedClock` currently defaults from `Date()`, `SimulatedEventLoop.drain()` silently truncates at 10,000, and observed synthetic Date/UUID fields need clock/identity injection. Current examples are `NotificationInfo`'s default UUID, certificate creation time, notification delivery time, and simulated telemetry durations. The prototype decides which enter canonical traces; unobserved fields remain explicitly excluded.

Other debt is not a global migration prerequisite. `timerSkipProbability`, `timerJitterRange`, and `sleepFails` are declared but not wired; they cannot count as Timer evidence and become slice-local blockers only if that slice requires them. Wall-clock deadlines and UUIDs used solely to isolate real integration tests remain valid because real-boundary receipts are not deterministic replay traces. Any newly discovered nondeterminism blocks only the slice whose canonical observation includes it, is recorded in that handoff, and is fixed or excluded explicitly—never hidden by deleting the assertion.

No new ticket is required. The replay/liveness prototype is already the next dependency of the parallel Lua-entrypoint partition, and the map's generic simulator-debt Fog item is now fully represented there. Independent adversarial review found the original step-budget escape hatch too narrow; the contract above now permits only predeclared finite overrides for either dimension.

Fresh baseline evidence before closing: `just test` passed 1,044 tests in 127 suites.

