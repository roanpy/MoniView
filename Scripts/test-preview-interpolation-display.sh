#!/bin/sh
set -eu
if [ "${1:-}" = "--help" ]; then
 cat <<'HELP'
Preview interpolation fixture

Configuration is supplied through environment variables:
  MONIVIEW_TEST_TARGET=native|2k|4k|screen   (default: native)
  MONIVIEW_TEST_LOW_LATENCY=0|1              (default: 1; 0 permits full target size)
  MONIVIEW_TEST_STRENGTH=0..1                (default: 0)
  MONIVIEW_TEST_FLOWBLEND=1                  (use the optical-flow Beta tier; overrides MONIVIEW_TEST_QUALITY / MONIVIEW_TEST_BALANCED)
  MONIVIEW_TEST_QUALITY=1                    (use the Clear interpolation tier)
  MONIVIEW_TEST_REQUIRE_METALFX=1            (strict run must observe MetalFX)
  MONIVIEW_TEST_FULLSCREEN=1                 (fixture enters native fullscreen after launch; no persistent app setting)
  MONIVIEW_TEST_WINDOW_WIDTH / _HEIGHT       (fixture window size; default 960x540)
  MONIVIEW_TEST_VIVID=1                      (apply the shipped Vivid preset: contrast, saturation, vibrance, highlight recovery)
  MONIVIEW_TEST_FOLLOW=1                     (enable content-rate Follow; does not repeat synthetic frames)
  MONIVIEW_TEST_REPEAT=1|2|3                 (synthetic content repeat divisor; default 1, or 2 with DUPLICATES=1)
  MONIVIEW_TEST_DUPLICATES=1                 (legacy alias for Follow plus default repeat divisor 2; REPEAT can override)
  MONIVIEW_REQUIRE_120=1                     (run the unchanged strict 60→120 gate)
  MONIVIEW_REQUIRE_2X=1                      (require 2x throughput in 6/7 steady windows; duplicates use content FPS)
  MONIVIEW_TEST_RESTART=1                    (stop, re-enable the same engine, and verify generated presentations resume)
  MONIVIEW_TEST_SWITCH=1                     (with RESTART: switch to quality and back; verify original target rate)
  MONIVIEW_TEST_FOLLOW_SWITCH=1              (tick 16 disable Follow, tick 20 restore; needs Follow, 60 FPS, repeat=2, 120 Hz)
  MONIVIEW_TEST_COMPILE_ONLY=1               (compile fixture, do not launch its window)

Strict mode requires the bound display to report at least 120 Hz and checks the
test window's visible, unminimized, unoccluded state throughout sampling. If the
display rate drops or the window becomes ineligible, it reports SKIP and exits 2;
this is not a pass.

Follow can be tested with unique 60 FPS synthetic input without enabling frame
repetition. For a Follow toggle/restore run, use 60 FPS with repeat divisor 2;
ticks 18 and 19 check resumed generation and the 60 FPS basis on a 120 Hz display.

Follow on with unique 60 FPS input (strict 60→120 gate):
  MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60 MONIVIEW_TEST_FOLLOW=1 \
  Scripts/test-preview-interpolation-display.sh

Follow off/on transition with repeated 60 FPS input carrying 30 FPS content:
  MONIVIEW_TEST_FPS=60 MONIVIEW_TEST_REPEAT=2 MONIVIEW_TEST_FOLLOW=1 \
  MONIVIEW_TEST_FOLLOW_SWITCH=1 Scripts/test-preview-interpolation-display.sh

Example joint MetalFX + interpolation run (uses the native display/GPU):
  MONIVIEW_REQUIRE_120=1 MONIVIEW_TEST_FPS=60 MONIVIEW_TEST_FULLSCREEN=1 \
  MONIVIEW_TEST_TARGET=4k \
  MONIVIEW_TEST_LOW_LATENCY=0 MONIVIEW_TEST_STRENGTH=0.35 \
  MONIVIEW_TEST_QUALITY=1 MONIVIEW_TEST_REQUIRE_METALFX=1 \
  Scripts/test-preview-interpolation-display.sh

Compile only, without launching a window or running the performance gate:
  MONIVIEW_TEST_COMPILE_ONLY=1 Scripts/test-preview-interpolation-display.sh
HELP
 exit 0
fi
if [ "$#" -ne 0 ]; then
 echo 'No positional arguments are supported; use --help for environment options.' >&2
 exit 2
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/PreviewInterpolationDisplayTests.swift" "$WORK/main.swift"
swiftc -swift-version 5 -O -D MONIVIEW_PREVIEW_TESTING \
 "$ROOT/Sources/MoniView/AIUpscaler.swift" "$ROOT/Sources/MoniView/FrameInterpolator.swift" \
 "$ROOT/Sources/MoniView/VideoFrameDuplicateDetector.swift" "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" "$ROOT/Sources/MoniView/ContentCadencePolicy.swift" "$ROOT/Sources/MoniView/PreviewLayerView.swift" \
 "$ROOT/Sources/MoniView/FlowBlendInterpolator.swift" \
 "$ROOT/Sources/MoniView/MetalUpscaler.swift" "$ROOT/Sources/MoniView/InputContentCadence.swift" "$ROOT/Sources/MoniView/CaptureManager.swift" \
 "$ROOT/Sources/MoniView/CaptureRecorder.swift" "$ROOT/Sources/MoniView/VideoImageProcessor.swift" \
 "$ROOT/Sources/MoniView/MacWindowCapture.swift" "$ROOT/Sources/MoniView/CaptureSessionPolicy.swift" \
 "$ROOT/Sources/MoniView/DurationBoundedFIFO.swift" "$ROOT/Sources/MoniView/ConfigurationRevision.swift" \
 "$ROOT/Sources/MoniView/Localization.swift" "$WORK/main.swift" -o "$WORK/display-tests"
case "${MONIVIEW_TEST_COMPILE_ONLY:-0}" in
 1) echo 'PASS fixture compiled (runtime not launched)'; exit 0 ;;
 0) ;;
 *) echo 'MONIVIEW_TEST_COMPILE_ONLY must be 0 or 1' >&2; exit 2 ;;
esac
set +e
"$WORK/display-tests"
RESULT=$?
set -e
if [ "$RESULT" -eq 2 ]; then echo 'SKIP fixture inconclusive (exit 2; not a pass)'; exit 2; fi
exit "$RESULT"
