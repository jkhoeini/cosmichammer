---
id: WF-016
title: Partition Lua entrypoint cleanup into parallel waves
state: open
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee:
blocked_by:
  - WF-005
  - WF-007
  - WF-008
  - WF-009
  - WF-010
  - WF-011
---

## Question

Given the already-chosen registration architecture, assign exact module files, generated outputs, tests, oracle owners, reviewers, and dependency order to its implementation wave shape. Keep the generator and checked-in outputs under one owner, avoid overlapping module ownership with the active LuaSwift work packages, and require each wave’s deterministic, lifecycle, and relevant real-I/O evidence before convergence.
