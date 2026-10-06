#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" \
    "$ROOT/Sources/MoniView/ContentCadencePolicy.swift" \
    "$ROOT/Tests/ContentCadencePolicyTests.swift" \
    -o "$WORK/content-cadence-policy-tests"
"$WORK/content-cadence-policy-tests"
