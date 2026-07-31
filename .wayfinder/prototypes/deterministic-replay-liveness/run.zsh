#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
source_text="$(<"$root/prototype.swift")"

[[ "$source_text" != *'Date()'* ]]
[[ "$source_text" != *'UUID()'* ]]

expected=$'inputs=seed:42 epoch:978307200 identity-seed:42\nreplay=byte-identical identity=fault-independent time=clock-derived\nquiesced=steps:2 virtual:2 pending:0 signal:quiesced\nstep-limit=steps:5 virtual:0 pending:1 signal:stepLimitExceeded\nstalled=steps:0 virtual:60 pending:1 signal:stalled\nempty-stall=steps:1 virtual:0 pending:0 signal:stalled\nfields=inject:clock.epoch,userNotification.identifier-observed,certificate.createdAt,notification.actualDeliveryDate,telemetry.duration exclude:userNotification.autoUUID-unobserved,location.referenceDate-already-fixed,realIO.tempUUID,realIO.wallClock'

xcrun swiftc -Onone "$root/prototype.swift" -o "$tmpdir/replay-debug"
debug_output="$($tmpdir/replay-debug)"
[[ "$debug_output" == "$expected" ]]

xcrun swiftc -O "$root/prototype.swift" -o "$tmpdir/replay-release"
release_output="$($tmpdir/replay-release)"
[[ "$release_output" == "$expected" ]]
[[ "$debug_output" == "$release_output" ]]

print -r -- "$debug_output"
print 'builds=debug,release output=identical source=nondeterminism-free'
print 'prototype=throwaway production-source=unchanged'
