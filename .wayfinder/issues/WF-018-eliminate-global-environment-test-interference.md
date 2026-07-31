---
id: WF-018
title: Eliminate cross-suite global Environment test interference
state: open
labels:
  - "wayfinder:prototype"
parent: WF-001
assignee:
blocked_by: []
---

## Question

Reproduce and eliminate cross-suite interference in the process-global `Environment` during parallel Swift Testing. A full `just test` run recorded two contradictory settings observations in `DSTSettingsIntegrationTests.testSettingsSetterViaSimulator`, while the isolated 15-test suite passed. Determine the smallest test-harness seam—consistent ownership through `globalEnvLock`, removal of process-global fallback from isolated tests, or another deterministic approach—that preserves production behavior and suite parallelism. Prove it with repeated full-suite runs; do not hide the race with retries, sleeps, or broader serialization.
