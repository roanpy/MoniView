#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/MoniView/ConfigurationRevision.swift" "$ROOT/Tests/ConfigurationRevisionTests.swift" -o "$WORK/configuration-revision-tests"
"$WORK/configuration-revision-tests"
