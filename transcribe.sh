#!/usr/bin/env bash
# Transcribe a recorded call into a speaker-attributed transcript.
#
# Speakers come from channel separation, not from a diarisation model: the far
# end and your microphone were recorded as physically separate streams, so who
# said what is known exactly rather than guessed.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"
callcap_require || exit 1

RECORDINGS_DIR="$CALLCAP_DIR"
MODEL="$CALLCAP_MODEL"
WHISPER="$CALLCAP_WHISPER_BIN"
THREADS="$CALLCAP_THREADS"

ME="$CALLCAP_ME"
THEM="Them"
KEEP_RAW=0
SESSION=""

usage() {
  cat <<USAGE
callcap-transcribe [session-dir|latest] [options]

  --me <name>     label for your microphone channel   (default: $CALLCAP_ME)
  --them <name>   label for the far-end channel       (default: Them)
  --keep-raw      keep the uncompressed WAVs after archiving to call.m4a
  --help

With no session argument, the most recent recording is used.
Writes transcript.md, transcript.json and call.m4a into the session directory.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --me)       ME="$2"; shift 2 ;;
    --them)     THEM="$2"; shift 2 ;;
    --keep-raw) KEEP_RAW=1; shift ;;
    --help|-h)  usage; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 1 ;;
    *)          SESSION="$1"; shift ;;
  esac
done

if [[ -z "$SESSION" || "$SESSION" == "latest" ]]; then
  SESSION="$(ls -1dt "$RECORDINGS_DIR"/call_* 2>/dev/null | head -1 || true)"
  [[ -n "$SESSION" ]] || { echo "no recordings found in $RECORDINGS_DIR" >&2; exit 1; }
fi
SESSION="${SESSION%/}"
[[ -d "$SESSION" ]] || { echo "not a session directory: $SESSION" >&2; exit 1; }
[[ -f "$MODEL" ]]   || { echo "whisper model missing: $MODEL" >&2; exit 1; }

FAR="$SESSION/far.wav"
NEAR="$SESSION/near.wav"
META="$SESSION/recording.json"

# The recorder measures how much later the mic stream started than the app
# stream. Pad the late one so both tracks share a t=0.
OFFSET="$(jq -r '.nearOffsetSeconds // 0' "$META" 2>/dev/null || echo 0)"
NEAR_PAD_MS=0
FAR_PAD_MS=0
if (( $(echo "$OFFSET > 0" | bc -l) )); then
  NEAR_PAD_MS=$(printf '%.0f' "$(echo "$OFFSET * 1000" | bc -l)")
else
  FAR_PAD_MS=$(printf '%.0f' "$(echo "-1 * $OFFSET * 1000" | bc -l)")
fi

echo "==> session : $SESSION"
echo "==> aligning: mic offset ${OFFSET}s (pad near ${NEAR_PAD_MS}ms / far ${FAR_PAD_MS}ms)"

prep() { # <in> <out> <pad-ms>
  local pad_filter=""
  [[ "$3" != "0" ]] && pad_filter="adelay=$3:all=1,"
  ffmpeg -nostdin -v error -y -i "$1" \
    -af "${pad_filter}pan=mono|c0=0.5*c0+0.5*c1,highpass=f=80,loudnorm=I=-18:TP=-2:LRA=11" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$2"
}

# The far stream is stereo and the near stream mono; the pan above collapses
# whatever it is given, but a mono input has no c1 to reference.
prep_mono() { # <in> <out> <pad-ms>
  local pad_filter=""
  [[ "$3" != "0" ]] && pad_filter="adelay=$3:all=1,"
  ffmpeg -nostdin -v error -y -i "$1" \
    -af "${pad_filter}highpass=f=80,loudnorm=I=-18:TP=-2:LRA=11" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$2"
}

channels() { ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 "$1"; }

echo "==> preparing audio"
[[ "$(channels "$FAR")"  == "2" ]] && prep "$FAR"  "$SESSION/.far16.wav"  "$FAR_PAD_MS"  || prep_mono "$FAR"  "$SESSION/.far16.wav"  "$FAR_PAD_MS"
[[ "$(channels "$NEAR")" == "2" ]] && prep "$NEAR" "$SESSION/.near16.wav" "$NEAR_PAD_MS" || prep_mono "$NEAR" "$SESSION/.near16.wav" "$NEAR_PAD_MS"

PROMPT_FILE="$CALLCAP_VOCABULARY"
PROMPT_ARGS=()
[[ -f "$PROMPT_FILE" ]] && PROMPT_ARGS=(--prompt "$(tr '\n' ' ' < "$PROMPT_FILE")")

run_whisper() { # <wav> <out-prefix> <who>
  echo "==> transcribing $3"
  "$WHISPER" -m "$MODEL" -f "$1" -of "$2" -oj -l "$CALLCAP_LANGUAGE" -t "$THREADS" \
    -np -nf "${PROMPT_ARGS[@]}" >/dev/null 2>"$SESSION/.whisper.log" \
    || { echo "whisper failed for $3; see $SESSION/.whisper.log" >&2; exit 1; }
}

run_whisper "$SESSION/.far16.wav"  "$SESSION/.far"  "$THEM"
run_whisper "$SESSION/.near16.wav" "$SESSION/.near" "$ME"

echo "==> merging"
python3 "$HERE/merge_transcript.py" \
  --far "$SESSION/.far.json" --near "$SESSION/.near.json" \
  --them "$THEM" --me "$ME" \
  --meta "$META" \
  --out-md "$SESSION/transcript.md" --out-json "$SESSION/transcript.json"

echo "==> archiving audio"
# join truncates to its shortest input, which would silently clip the archive
# to whichever channel ended first — and the raw WAVs are deleted below, so
# that loss would be unrecoverable. Pad both sides and cut at the longer one.
duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
FAR_SECS="$(duration "$SESSION/.far16.wav")"
NEAR_SECS="$(duration "$SESSION/.near16.wav")"
MAX_SECS="$(echo "if ($FAR_SECS > $NEAR_SECS) $FAR_SECS else $NEAR_SECS" | bc -l)"

ffmpeg -nostdin -v error -y -i "$SESSION/.far16.wav" -i "$SESSION/.near16.wav" \
  -filter_complex "[0:a]apad[l];[1:a]apad[r];[l][r]join=inputs=2:channel_layout=stereo[a]" \
  -map "[a]" -t "$MAX_SECS" -c:a aac -b:a 64k "$SESSION/call.m4a"

rm -f "$SESSION"/.far16.wav "$SESSION"/.near16.wav "$SESSION"/.far.json "$SESSION"/.near.json "$SESSION"/.whisper.log
if [[ "$KEEP_RAW" -eq 0 ]]; then
  rm -f "$FAR" "$NEAR"
  echo "==> removed raw WAVs (call.m4a retained: left=$THEM, right=$ME)"
fi

echo
echo "==> transcript: $SESSION/transcript.md"
