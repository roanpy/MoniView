#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/AIUpscalerGPUTests.swift" "$WORK/main.swift"
swiftc "$@" "$ROOT/Sources/MoniView/AIUpscaler.swift" "$WORK/main.swift" -o "$WORK/ai-gpu-tests"
set +e
MTL_DEBUG_LAYER=1 "$WORK/ai-gpu-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then
    echo 'AI GPU test skipped; no supported runtime. This is not a pass.'
fi
exit "$RESULT"
