---
id: WF-011
title: Restore deterministic replay and liveness prerequisites
state: closed
labels:
  - "wayfinder:prototype"
parent: WF-001
assignee: Main
blocked_by:
  - WF-010
---

## Question

Determine and prototype only the harness changes required for trustworthy migration verification: a fixed simulation epoch and controlled identity fields where they enter observed traces, plus an explicit failure result when deterministic event-loop work exceeds its bound or cannot make progress. Decide which existing Date/UUID fields are injected and which are intentionally excluded from replay assertions.

## Resolution comments

### 2026-07-29 — Keep scheduler phases; share explicit replay inputs and budget

The throwaway [replay/liveness prototype](../prototypes/deterministic-replay-liveness/prototype.swift) proves the minimum production shape. `SimulatorHarness` should accept one immutable `SimulationRunInputs(seed:epochSeconds:identitySeed:)`; migration receipts use seed `42`, epoch `978_307_200`, and identity seed `42`. `SimulatedClock` receives the epoch instead of consulting wall time. Fault and identity streams remain distinct, and a canonical trace records the three inputs plus its fault profile.

Do not merge the clock and event-loop schedulers. Preserve the production order: `SimulatedClock.advance(by:)` drains due timers first, then `SimulatedEventLoop.drain()` runs ready event-loop work. Thread one shared step budget through both loops, and put the completion-predicate/virtual-deadline orchestration in the harness. Timer callbacks may enqueue event-loop work, but that work runs only in the subsequent event-loop phase. The prototype exercises and locks this ordering.

The progress interface returns a receipt with `quiesced`, `stepLimitExceeded`, or `stalled` plus inputs, fault profile, executed steps, start/end virtual time, pending work, last progress, and the unmet predicate. Classification order matters:

1. a satisfied predicate is `quiesced`;
2. an unsatisfied predicate with no pending work, or no work reachable inside the virtual deadline, is `stalled`;
3. exhausted steps are `stepLimitExceeded` only while timer or event-loop work remains.

This makes an empty queue at exactly the step limit `stalled`, not a false step-limit failure. Default limits remain 10,000 combined executions and 60 virtual seconds; any alternate finite limit is frozen in the slice brief before implementation.

#### Date and identity policy

Inject or explicitly supply values only when the field enters a deterministic migration observation:

- `SimulatedClock` start time — required harness epoch;
- `UserNotification.identifier` — deterministic identity from `(identitySeed, namespace, ordinal)` when a scenario observes it;
- simulated certificate creation time — injected clock;
- simulated notification `actualDeliveryDate` — injected clock;
- simulated telemetry flush/shutdown durations — injected clock, producing zero unless the scenario advances virtual time.

Intentionally exclude these from replay equality:

- `UserNotification`'s automatic UUID when the identifier is not observed; preserve the production convenience default, while replay fixtures that observe identity must pass one explicitly;
- `LocationCoordinate`'s reference-date default, which is already fixed;
- UUIDs used only to isolate real temporary directories/defaults domains;
- wall-clock deadlines, durations, addresses, and OS scheduling from real-I/O complements.

`SimulatedFileSystem` already derives dates from `ClockProtocol`; no new seam is needed. Unobserved nondeterministic fields are named exclusions, not normalized strings or deleted assertions. A later slice that begins observing one must inject it before the receipt can count as replay evidence.

The [one-command runner](../prototypes/deterministic-replay-liveness/run.zsh) first failed with the implementation absent, then passed Debug and optimized Release with byte-identical output. It demonstrates fault-stream-sensitive identity independence, clock-derived observed times, the two scheduler phases sharing one budget, successful quiescence, pending-work step exhaustion, virtual-deadline stall, and the exact-limit empty-queue stall.

```text
quiesced=steps:2 virtual:2 pending:0 signal:quiesced
step-limit=steps:5 virtual:0 pending:1 signal:stepLimitExceeded
stalled=steps:0 virtual:60 pending:1 signal:stalled
empty-stall=steps:1 virtual:0 pending:0 signal:stalled
```

Adversarial review found three material issues in the first version: a vacuous fault-stream assertion, incorrect exact-limit classification, and an unrealistic merged scheduler. All were corrected; independent re-review reported no issues. Fresh `just test` evidence passed 1,044 tests in 127 suites. Production source remains unchanged; the prototype is durable decision evidence for later implementation planning, not code to transplant wholesale. No new ticket or Fog graduation is required.

