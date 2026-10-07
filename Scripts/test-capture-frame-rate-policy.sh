#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/MoniView/CaptureFrameRatePolicy.swift" \
    "$ROOT/Tests/CaptureFrameRatePolicyTests.swift" \
    -o "$WORK/capture-frame-rate-policy-tests"
"$WORK/capture-frame-rate-policy-tests"
