#!/bin/sh
# Fault-injection harness for CaptureRecorder: synthetic media through the real recorder
# and AVAssetWriter. See Tests/RecorderFaultInjectionTests.swift for coverage notes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/RecorderFaultInjectionTests.swift" "$WORK/main.swift"
swiftc -D MONIVIEW_RECORDER_TESTING -O "$ROOT/Sources/MoniView/DurationBoundedFIFO.swift" "$ROOT/Sources/MoniView/Localization.swift" "$ROOT/Sources/MoniView/VideoImageProcessor.swift" "$ROOT/Sources/MoniView/CaptureRecorder.swift" "$WORK/main.swift" -o "$WORK/recorder-fault-tests"
"$WORK/recorder-fault-tests"
