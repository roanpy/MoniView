#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/WindowCapturePolicyTests.swift" "$WORK/main.swift"
swiftc -swift-version 5 \
  "$ROOT/Sources/MoniView/MacWindowCapture.swift" \
  "$ROOT/Sources/MoniView/Localization.swift" \
  "$WORK/main.swift" -o "$WORK/window-capture-policy-tests"
"$WORK/window-capture-policy-tests"
