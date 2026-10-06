#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc -O -framework CoreVideo -framework ImageIO \
    "$ROOT/Sources/MoniView/VideoFrameDuplicateDetector.swift" \
    "$ROOT/Tests/VideoFrameDuplicateDetectorTests.swift" \
    -o "$WORK/video-frame-duplicate-tests"
"$WORK/video-frame-duplicate-tests"
