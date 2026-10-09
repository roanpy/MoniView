#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" "$ROOT/Sources/MoniView/ContentCadencePolicy.swift" "$ROOT/Sources/MoniView/CaptureSessionPolicy.swift" "$ROOT/Sources/MoniView/DurationBoundedFIFO.swift" "$ROOT/Sources/MoniView/ConfigurationRevision.swift" "$ROOT/Sources/MoniView/Localization.swift" "$ROOT/Sources/MoniView/VideoImageProcessor.swift" "$ROOT/Sources/MoniView/CaptureRecorder.swift" "$ROOT/Sources/MoniView/MacWindowCapture.swift" "$ROOT/Sources/MoniView/InputContentCadence.swift" "$ROOT/Sources/MoniView/VideoFrameDuplicateDetector.swift" "$ROOT/Sources/MoniView/CaptureManager.swift" "$ROOT/Sources/MoniView/FittedWindowPreview.swift" "$ROOT/Tests/CaptureCompatibilityTests.swift" -o "$WORK/capture-compatibility-tests"
"$WORK/capture-compatibility-tests" "$@"
