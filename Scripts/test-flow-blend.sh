#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:---gpu}
case "$MODE" in
    --compile-only|--gpu) ;;
    *)
        echo "Usage: $0 [--compile-only|--gpu]" >&2
        exit 2
        ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/FlowBlendTests.swift" "$WORK/main.swift"
xcrun --sdk macosx swiftc -O -swift-version 5 \
    "$ROOT/Sources/MoniView/FlowBlendInterpolator.swift" \
    "$WORK/main.swift" \
    -o "$WORK/flow-blend-tests"

if [ "$MODE" = "--compile-only" ]; then
    echo "COMPILE-ONLY PASS: optimized FlowBlendInterpolator GPU fixture compiled."
    exit 0
fi

set +e
"$WORK/flow-blend-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then
    echo "SKIP: FlowBlend Metal runtime was unavailable (not a pass)."
fi
exit "$RESULT"
