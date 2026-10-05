#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/MoniView/DurationBoundedFIFO.swift" "$ROOT/Tests/DurationBoundedFIFOTests.swift" -o "$WORK/audio-buffer-tests"
"$WORK/audio-buffer-tests"
