#!/bin/zsh
set -euo pipefail

prototype_dir="${0:A:h}"
for configuration in debug release; do
    output="$(swift run --package-path "$prototype_dir" -c "$configuration" DirectSwiftLuaEntrypointPrototype)"
    print -r -- "$output"
    expected="configuration=$configuration preload=require-ok answer=42"
    [[ "$output" == *"$expected"* ]] || {
        print -u2 "missing expected evidence: $expected"
        exit 1
    }
done
