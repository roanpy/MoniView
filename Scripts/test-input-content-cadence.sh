#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc -DINPUT_CONTENT_CADENCE_TESTING \
    -framework CoreMedia -framework CoreVideo -framework ImageIO \
    "$ROOT/Sources/MoniView/VideoFrameDuplicateDetector.swift" \
    "$ROOT/Sources/MoniView/InputContentCadence.swift" \
    "$ROOT/Tests/InputContentCadenceTests.swift" \
    -o "$WORK/input-content-cadence-tests"
"$WORK/input-content-cadence-tests"
