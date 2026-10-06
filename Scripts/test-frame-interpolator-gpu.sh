#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_MAJOR=${SDK_VERSION%%.*}
if [ "$SDK_MAJOR" -lt 26 ]; then
    echo "SKIP: requires macOS 26 SDK; found $SDK_VERSION (not a pass)"
    exit 0
fi

cp "$ROOT/Tests/FrameInterpolatorGPUTests.swift" "$WORK/main.swift"
xcrun --sdk macosx swiftc -swift-version 5 -D MONIVIEW_FRAME_INTERPOLATOR_TESTING \
    "$ROOT/Sources/MoniView/AIUpscaler.swift" \
    "$ROOT/Sources/MoniView/FrameInterpolator.swift" \
    "$WORK/main.swift" \
    -o "$WORK/frame-interpolator-gpu-tests"

set +e
MTL_DEBUG_LAYER=1 "$WORK/frame-interpolator-gpu-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then
    echo 'Frame interpolator GPU fixture skipped; runtime capability was unavailable (not a pass).'
    exit 0
fi
exit "$RESULT"
