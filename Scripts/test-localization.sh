#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
    "$ROOT/Tests/LocalizationTests.swift" \
    -o "$WORK/localization-tests"
"$WORK/localization-tests" "$ROOT"
