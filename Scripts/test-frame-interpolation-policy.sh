#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" "$ROOT/Tests/FrameInterpolationPolicyTests.swift" -o "$WORK/frame-interpolation-policy-tests"
"$WORK/frame-interpolation-policy-tests"
