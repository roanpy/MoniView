#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
MODE=${1:---compile-only}

xcrun --sdk macosx swiftc -swift-version 5 -D MONIVIEW_METAL_UPSCALER_TESTING \
    "$ROOT/Sources/MoniView/MetalUpscaler.swift" \
    "$ROOT/Tests/MetalUpscalerLRUTests.swift" \
    -o "$WORK/metal-upscaler-lru-tests"

case "$MODE" in
    --compile-only)
        echo 'COMPILE PASS: MetalUpscaler and its cache/GPU fixture compiled; no test executable was run.'
        ;;
    --cache-only)
        "$WORK/metal-upscaler-lru-tests" --cache-only
        ;;
    --gpu)
        set +e
        MTL_DEBUG_LAYER=1 "$WORK/metal-upscaler-lru-tests" --gpu
        RESULT=$?
        set -e
        if [ "$RESULT" -eq 2 ]; then
            echo 'MetalUpscaler native fixture skipped; runtime capability was unavailable (not a pass).'
            exit 0
        fi
        exit "$RESULT"
        ;;
    *)
        echo "Usage: $0 [--compile-only|--cache-only|--gpu]" >&2
        exit 64
        ;;
esac
