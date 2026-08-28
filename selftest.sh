#!/usr/bin/env bash
# End-to-end check of the transcription pipeline using synthesised audio.
#
# Covers everything downstream of capture: stream alignment, whisper, speaker
# attribution, merge, archive. The capture half needs a live call and TCC
# grants, so it is verified by hand — see README.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)/call_selftest"
trap 'rm -rf "$(dirname "$WORK")"' EXIT
mkdir -p "$WORK"

FAR_TEXT="The quarterly inventory reconciliation finished ahead of schedule this morning."
NEAR_TEXT="Good, then the only thing outstanding is the vendor handover next week."

echo "==> synthesising two channels"
say -v Samantha -o "$WORK/far.aiff"  "$FAR_TEXT"
say -v Daniel   -o "$WORK/near.aiff" "$NEAR_TEXT"
# Shaped like real recorder output: far is 48k stereo float, near 48k mono float.
ffmpeg -nostdin -v error -y -i "$WORK/far.aiff"  -ar 48000 -ac 2 -c:a pcm_f32le "$WORK/far.wav"
ffmpeg -nostdin -v error -y -i "$WORK/near.aiff" -ar 48000 -ac 1 -c:a pcm_f32le "$WORK/near.wav"
rm -f "$WORK"/*.aiff

NEAR_RAW_SECS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/near.wav")"

cat > "$WORK/recording.json" <<JSON
{ "session": "call_selftest", "recordedAt": "2026-01-01T00:00:00Z",
  "app": "selftest", "nearOffsetSeconds": 3.0 }
JSON

echo "==> running transcribe.sh"
"$HERE/transcribe.sh" "$WORK" --me "Near" --them "Far" >/dev/null

fail=0
check() { # <description> <condition-already-evaluated:0|1>
  if [[ "$2" -eq 0 ]]; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=1; fi
}

echo "==> assertions"
[[ -f "$WORK/transcript.md"   ]]; check "transcript.md written" $?
[[ -f "$WORK/transcript.json" ]]; check "transcript.json written" $?
[[ -f "$WORK/call.m4a"        ]]; check "call.m4a archive written" $?
[[ ! -f "$WORK/far.wav"       ]]; check "raw WAVs cleaned up" $?

grep -qi "reconciliation" "$WORK/transcript.md"; check "far-end speech transcribed" $?
grep -qi "handover"      "$WORK/transcript.md"; check "near-end speech transcribed" $?
grep -q  "Far:"         "$WORK/transcript.md"; check "far channel attributed to Far" $?
grep -q  "Near:"        "$WORK/transcript.md"; check "near channel attributed to Near" $?

# Attribution must be exclusive: the word "orchestrator" was only ever spoken
# on the far channel, so it must not appear under Near.
! grep "Near:" "$WORK/transcript.md" | grep -qi "reconciliation"
check "no cross-channel attribution leak" $?

python3 - "$WORK/transcript.json" <<'ASSERT'
import json, sys
turns = json.load(open(sys.argv[1]))["turns"]
assert turns, "no turns"
assert turns[0]["speaker"] == "Far", f"expected Far first, got {turns[0]['speaker']}"
assert {t["speaker"] for t in turns} == {"Far", "Near"}, "both speakers must appear"
ASSERT
check "turns ordered, both speakers present" $?

# Assert the alignment pad landed in the audio rather than in whisper's
# timestamps: whisper snaps its first segment to t=0 no matter how much
# leading silence there is, so the WAV is the only honest witness.
ARCHIVE_SECS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/call.m4a")"
python3 - "$NEAR_RAW_SECS" "$ARCHIVE_SECS" <<'ASSERT'
import sys
raw, archived = float(sys.argv[1]), float(sys.argv[2])
assert archived >= raw + 2.8, f"3s mic pad missing: raw={raw:.2f} archived={archived:.2f}"
ASSERT
check "stream alignment offset applied to audio" $?

# The stereo archive keeps far on the left and near on the right.
[[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$WORK/call.m4a")" == "2" ]]
check "archive is stereo" $?

# Level detection is what callcap-check reports on. It regressed once by
# running volumedetect under `-v error`, which hides its info-level output and
# made every channel — however loud — report as silent.
source "$HERE/levels.sh"
say -v Samantha -o "$WORK/loud.aiff" "This channel definitely contains speech."
ffmpeg -nostdin -v error -y -i "$WORK/loud.aiff" -ar 48000 -ac 1 -c:a pcm_f32le "$WORK/loud.wav"
ffmpeg -nostdin -v error -y -f lavfi -i anullsrc=r=48000:cl=mono -t 3 -c:a pcm_f32le "$WORK/quiet.wav"

LOUD="$(audio_levels "$WORK/loud.wav")"
[[ -n "${LOUD%%|*}" ]]; check "level detection returns a reading" $?
! audio_is_silent "${LOUD%%|*}"; check "speech is not reported as silent" $?
audio_is_silent "$(audio_levels "$WORK/quiet.wav" | cut -d'|' -f1)"
check "true silence is reported as silent" $?

echo
if [[ "$fail" -eq 0 ]]; then echo "PASS"; else echo "FAIL"; exit 1; fi
