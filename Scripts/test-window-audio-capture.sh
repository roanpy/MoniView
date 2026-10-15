#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
cp "$ROOT/Tests/WindowAudioCaptureTests.swift" "$WORK/main.swift"
swiftc -swift-version 5 -O -D MONIVIEW_CAPTURE_TESTING \
 "$ROOT/Sources/MoniView/FrameInterpolationPolicy.swift" "$ROOT/Sources/MoniView/ContentCadencePolicy.swift" \
 "$ROOT/Sources/MoniView/CaptureSessionPolicy.swift" "$ROOT/Sources/MoniView/DurationBoundedFIFO.swift" \
 "$ROOT/Sources/MoniView/ConfigurationRevision.swift" "$ROOT/Sources/MoniView/Localization.swift" \
 "$ROOT/Sources/MoniView/VideoImageProcessor.swift" "$ROOT/Sources/MoniView/CaptureRecorder.swift" \
 "$ROOT/Sources/MoniView/MacWindowCapture.swift" "$ROOT/Sources/MoniView/InputContentCadence.swift" "$ROOT/Sources/MoniView/VideoFrameDuplicateDetector.swift" "$ROOT/Sources/MoniView/CaptureManager.swift" "$ROOT/Sources/MoniView/FittedWindowPreview.swift" \
 "$WORK/main.swift" -o "$WORK/moniview-window-audio-tests"
if [ "${MONIVIEW_COMPILE_ONLY:-0}" = "1" ]; then
  printf '%s\n' 'PASS window-audio fixture compile-only; runtime capture was not started'
  exit 0
fi
"$WORK/moniview-window-audio-tests" "$WORK/window.mov"
ffprobe -v error -count_packets -show_entries stream=codec_type,nb_read_packets,start_time,duration \
 -of json "$WORK/window.mov" > "$WORK/tracks.json"
python3 - "$WORK/tracks.json" <<'PY'
import json, math, sys
tracks = {s['codec_type']: s for s in json.load(open(sys.argv[1]))['streams']}
assert 'audio' in tracks and 'video' in tracks, tracks
for kind in ('audio', 'video'):
    assert int(tracks[kind]['nb_read_packets']) > 20, tracks
    assert float(tracks[kind]['duration']) > 0, tracks
starts = {kind: float(tracks[kind]['start_time']) for kind in ('audio', 'video')}
durations = {kind: float(tracks[kind]['duration']) for kind in ('audio', 'video')}
assert all(math.isfinite(value) for value in (*starts.values(), *durations.values())), tracks
assert all(value > 0 for value in durations.values()), tracks
ends = {kind: starts[kind] + durations[kind] for kind in ('audio', 'video')}
overlap = min(ends.values()) - max(starts.values())
start_delta = abs(starts['audio'] - starts['video'])
assert overlap > 1, (overlap, tracks)
assert start_delta < 0.5, (start_delta, tracks)
print('PASS short clip actual audio/video time-range overlap >1s and start offset <0.5s; this does not establish long-recording sync:',
      {'starts': starts, 'overlap': overlap, 'streams': tracks})
PY
