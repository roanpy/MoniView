#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:---compile-only}
case "$MODE" in
    --compile-only|--gpu|--async-diagnostic) ;;
    *)
        echo "Usage: $0 [--compile-only|--gpu|--async-diagnostic]" >&2
        echo "Optional runtime filter: MONIVIEW_JOINT_CASES=640|960|1920 (comma-separated for --gpu)." >&2
        exit 2
        ;;
esac

SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
SDK_MAJOR=${SDK_VERSION%%.*}
if [ "$SDK_MAJOR" -lt 26 ]; then
    echo "SKIP: joint interpolation requires macOS 26 SDK; found $SDK_VERSION (not a pass)"
    exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/JointInterpolationGPUTests.swift" "$WORK/main.swift"
xcrun --sdk macosx swiftc -swift-version 5 \
    "$WORK/main.swift" \
    -o "$WORK/joint-interpolation-gpu-tests"

if [ "$MODE" = "--compile-only" ]; then
    echo "COMPILE-ONLY PASS: joint interpolation fixture compiled with macOS SDK $SDK_VERSION; GPU was not started."
    echo "To explicitly run the native GPU fixture after GPU work is idle, pass --gpu."
    exit 0
fi

set +e
if [ "$MODE" = "--async-diagnostic" ]; then
    "$WORK/joint-interpolation-gpu-tests" --async-diagnostic
else
    MTL_DEBUG_LAYER=1 "$WORK/joint-interpolation-gpu-tests"
fi
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then
    echo "Joint processing fixture skipped at runtime; this is not a pass."
fi
exit "$RESULT"
