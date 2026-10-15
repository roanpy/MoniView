#!/bin/sh
set -eu
if [ "${1:-}" = "--help" ]; then
 cat <<'HELP'
Mac window capture fixture

Opens synthetic windows, runs a real ScreenCaptureKit session through
MacWindowCapture and checks frame delivery, size, pixel format, timestamp order,
unchanged-content accounting, stop and restart. Compiler flags may be forwarded as
arguments. Requires Screen Recording permission for the invoking terminal; a
permission failure is reported as SKIP (exit 2), not a pass.
HELP
 exit 0
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/MacWindowCaptureTests.swift" "$WORK/main.swift"
swiftc "$@" -swift-version 5 -O \
 "$ROOT/Sources/MoniView/MacWindowCapture.swift" "$ROOT/Sources/MoniView/Localization.swift" \
 "$WORK/main.swift" -o "$WORK/mac-window-tests"
set +e
"$WORK/mac-window-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then echo 'SKIP mac window capture inconclusive (exit 2; not a pass)'; fi
exit "$RESULT"
