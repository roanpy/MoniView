#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/PreviewInterpolationDisplayTests.swift" "$WORK/main.swift"
swiftc -O -D MONIVIEW_PREVIEW_TESTING \
 "$ROOT/Sources/MoniView/AIUpscaler.swift" "$ROOT/Sources/MoniView/FrameInterpolator.swift" \
 "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" "$ROOT/Sources/MoniView/PreviewLayerView.swift" \
 "$ROOT/Sources/MoniView/MetalUpscaler.swift" "$ROOT/Sources/MoniView/CaptureManager.swift" \
 "$ROOT/Sources/MoniView/CaptureRecorder.swift" "$ROOT/Sources/MoniView/VideoImageProcessor.swift" \
 "$ROOT/Sources/MoniView/DurationBoundedFIFO.swift" "$ROOT/Sources/MoniView/ConfigurationRevision.swift" \
 "$ROOT/Sources/MoniView/Localization.swift" "$WORK/main.swift" -o "$WORK/display-tests"
set +e
"$WORK/display-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then echo 'SKIP native display runtime unavailable (not a pass)'; exit 0; fi
exit "$RESULT"
