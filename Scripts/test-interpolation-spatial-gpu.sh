#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:---compile-only}
case "$MODE" in
    --compile-only|--gpu) ;;
    *)
        echo "Usage: $0 [--compile-only|--gpu]" >&2
        exit 2
        ;;
esac

SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_MAJOR=${SDK_VERSION%%.*}
if [ "$SDK_MAJOR" -lt 26 ]; then
    echo "SKIP: joint interpolation/spatial fixture requires macOS 26 SDK; found $SDK_VERSION (not a pass)"
    exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/InterpolationSpatialGPUTests.swift" "$WORK/main.swift"
xcrun --sdk macosx swiftc -O -swift-version 5 \
    -D MONIVIEW_FRAME_INTERPOLATOR_TESTING \
    "$ROOT/Sources/MoniView/AIUpscaler.swift" \
    "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" \
    "$ROOT/Sources/MoniView/FrameInterpolator.swift" \
    "$ROOT/Sources/MoniView/MetalUpscaler.swift" \
    "$WORK/main.swift" \
    -o "$WORK/interpolation-spatial-gpu-tests"

if [ "$MODE" = "--compile-only" ]; then
    echo "COMPILE-ONLY PASS: optimized (-O) joint VideoToolbox→MetalFX fixture compiled with macOS SDK $SDK_VERSION; GPU was not started."
    echo "Run serially after other GPU work is idle: $0 --gpu"
    exit 0
fi

set +e
"$WORK/interpolation-spatial-gpu-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then
    echo "SKIP: interpolation/spatial runtime fixture did not complete (not a pass)."
fi
exit "$RESULT"
