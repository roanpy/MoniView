#!/bin/sh
set -eu

if [ "${1:-}" = "--help" ]; then
    cat <<'HELP'
Real-window interpolation display fixture

Creates a visible, continuously moving AppKit window driven at 20 FPS and pipes its
actual ScreenCaptureKit samples through MacWindowCapture, LatestVideoFrame and the
production CapturePreviewNSView. No capture card is used.

The visible run checks steady motion, static stop and stale-evidence expiry, resumed
motion, then a stopped/restarted source. It requires Flow, force, Follow, MetalFX screen
and enhancement strength 0.60. Exit codes are 0 PASS, 1 FAIL, 2 SKIP.

Compile only, without creating a window or starting ScreenCaptureKit:
  MONIVIEW_TEST_COMPILE_ONLY=1 ./Scripts/test-window-interpolation-display.sh

Run the visible fixture after the main agent schedules GPU/UI acceptance:
  ./Scripts/test-window-interpolation-display.sh

Temporarily raise both non-overlapping windows above other apps (default: floating):
  MONIVIEW_TEST_WINDOW_ABOVE_ALL=1 ./Scripts/test-window-interpolation-display.sh
This uses the same screen-saver window level for both fixture windows. Automatic
tabbing is disabled. Startup waits at most 3 seconds for actual visibility and prints
both windows' frames, visibility, occlusion, level, tabs and screen information.
The fixture enters NSApplication.run() and launches an async MainActor task after
applicationDidFinishLaunching. Bounded waits suspend with Task.sleep so AppKit events
and renderer main-queue callbacks can run. Each sample prints actual presentation
rates, renderer states, drawable waits/size, cadence and visibility before assertions.
Startup diagnostics also report cumulative CAD ticks, frame drawable acquisitions,
first source/generated callbacks, blank-request state and presentation-recovery times.
Blank requests are not proof of blank presentation; current hooks do not expose blank
callbacks or the current outstanding-token count. Queue peaks remain checked.
Like the product, onPresentationRecovery replaces the entire preview using the same
input mailbox. At most one startup rebuild is allowed, without extending warmup or
resetting measurements. Any later/repeated recovery is FAIL, including source restart.
For the main agent's next scheduled diagnostic run:
  MONIVIEW_TEST_WINDOW_ABOVE_ALL=1 MONIVIEW_TEST_TRACE=1 ./Scripts/test-window-interpolation-display.sh
PASS, FAIL and SKIP exits remove both temporary windows. Visibility and FPS assertions
remain mandatory; an ineligible environment still returns SKIP (exit 2).

The fixture needs an unlocked visible display of at least 60 Hz, Screen Recording
permission, working Flow/MetalFX, and enough screen area for two windows. It does not
replace the existing strict 60→120 or other production threshold tests.
HELP
    exit 0
fi

if [ "$#" -ne 0 ]; then
    echo 'No positional arguments are supported; use --help.' >&2
    exit 2
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/WindowInterpolationDisplayTests.swift" "$WORK/main.swift"

swiftc -swift-version 5 -O -D MONIVIEW_PREVIEW_TESTING \
    "$ROOT/Sources/MoniView/AIUpscaler.swift" \
    "$ROOT/Sources/MoniView/FrameInterpolator.swift" \
    "$ROOT/Sources/MoniView/VideoFrameDuplicateDetector.swift" \
    "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" \
    "$ROOT/Sources/MoniView/ContentCadencePolicy.swift" \
    "$ROOT/Sources/MoniView/PreviewLayerView.swift" \
    "$ROOT/Sources/MoniView/FlowBlendInterpolator.swift" \
    "$ROOT/Sources/MoniView/MetalUpscaler.swift" \
    "$ROOT/Sources/MoniView/InputContentCadence.swift" \
    "$ROOT/Sources/MoniView/CaptureManager.swift" \
    "$ROOT/Sources/MoniView/FittedWindowPreview.swift" \
    "$ROOT/Sources/MoniView/CaptureRecorder.swift" \
    "$ROOT/Sources/MoniView/VideoImageProcessor.swift" \
    "$ROOT/Sources/MoniView/MacWindowCapture.swift" \
    "$ROOT/Sources/MoniView/CaptureSessionPolicy.swift" \
    "$ROOT/Sources/MoniView/DurationBoundedFIFO.swift" \
    "$ROOT/Sources/MoniView/ConfigurationRevision.swift" \
    "$ROOT/Sources/MoniView/Localization.swift" \
    "$WORK/main.swift" -o "$WORK/window-display-tests"

case "${MONIVIEW_TEST_COMPILE_ONLY:-0}" in
    1)
        echo 'PASS real-window fixture compiled (runtime not launched)'
        exit 0
        ;;
    0) ;;
    *)
        echo 'MONIVIEW_TEST_COMPILE_ONLY must be 0 or 1' >&2
        exit 2
        ;;
esac

set +e
"$WORK/window-display-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then
    echo 'SKIP real-window fixture was inconclusive (exit 2; not a pass)'
fi
exit "$RESULT"
