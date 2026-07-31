---
id: WF-014
title: Decide historical Objective-C header retirement and native bridge types
state: open
labels:
  - "wayfinder:grilling"
parent: WF-001
assignee:
blocked_by:
  - WF-002
  - WF-004
  - WF-005
---

## Question

Given two independent source sweeps found no compiled consumers of the historical `CosmicHammer/*.h` bridge headers, confirm the remaining reflection-based `@interface` risks and choose the clean retirement boundary. Define typed Swift replacements for NSString/NSArray/AnyObject/raw-pointer signatures across lifecycle, UI/controller, configuration, logging, AX, keycodes, and tests. Preserve the genuine `objc_tryCatch` Objective-C boundary as an explicit separate seam.
