#!/usr/bin/env bash
# Smoke-test capture: record briefly, then report the signal level on each
# channel independently.
#
# Levels are the fast diagnostic. A silent far channel means Screen Recording
# permission or the wrong target app; a silent near channel means Microphone
# permission or the wrong input device. Transcript quality can't tell those
# apart, and takes far longer to find out.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=config.sh
source "$HERE/config.sh"
# shellcheck source=levels.sh
source "$HERE/levels.sh"

CALLCAP_BIN="${CALLCAP_APP_BUNDLE:-/Applications/Call Capture.app}/Contents/MacOS/callcap-rec"

APP="$CALLCAP_APP"
SECONDS_TO_RECORD=20
SYSTEM=0
MIC="$CALLCAP_MIC"
TRANSCRIBE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)      APP="$2"; shift 2 ;;
    --system)   SYSTEM=1; shift ;;
    --mic)      MIC="$2"; shift 2 ;;
    --seconds)  SECONDS_TO_RECORD="$2"; shift 2 ;;
    --no-transcribe) TRANSCRIBE=0; shift ;;
    --help|-h)
      cat <<USAGE
callcap-check [--app <app>] [--system] [--mic <name>] [--seconds N] [--no-transcribe]

Records N seconds (default 20) and reports whether each channel got audio.
Play something in the target app AND talk, so both channels have signal.
USAGE
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=============================================="
echo " capture check — ${SECONDS_TO_RECORD}s from $([[ "$SYSTEM" -eq 1 || -z "$APP" ]] && echo "all system audio" || echo "$APP")"
echo "=============================================="
echo
echo "  Make sure BOTH are happening while this runs:"
echo "    1. the app is playing audio you can hear"
echo "    2. you are talking"
echo
for i in 3 2 1; do printf "\r  starting in %d… " "$i"; sleep 1; done
printf "\r  recording now — talk!      \n\n"

REC_ARGS=(--label check --duration "$SECONDS_TO_RECORD")
if [[ "$SYSTEM" -eq 1 || -z "$APP" ]]; then REC_ARGS+=(--system); else REC_ARGS+=(--app "$APP"); fi
[[ -n "$MIC" ]] && REC_ARGS+=(--mic "$MIC")

# set -e must not swallow a non-zero exit here without explanation.
if ! SESSION="$(caffeinate -i "$CALLCAP_BIN" "${REC_ARGS[@]}" \
      2> >(grep -v "AVCaptureDeviceTypeExternal\|NSCameraUseContinuityCameraDeviceType" >&2))"; then
  echo "capture failed — see the error above" >&2
  exit 1
fi
[[ -n "$SESSION" && -d "$SESSION" ]] || { echo "capture failed" >&2; exit 1; }

echo
echo "=== channel levels ==="

report() { # <label> <wav> <hint>
  if [[ ! -f "$2" ]]; then
    printf "  %-22s NO DATA — %s\n" "$1" "$3"
    return 1
  fi
  local levels mean peak
  levels="$(audio_levels "$2")"
  mean="${levels%%|*}"
  peak="${levels##*|}"
  if audio_is_silent "$mean"; then
    printf "  %-22s SILENT (mean %s) — %s\n" "$1" "${mean:-n/a}" "$3"
    return 1
  fi
  printf "  %-22s ok   mean %-10s peak %s\n" "$1" "$mean" "$peak"
  return 0
}

far_ok=0; near_ok=0
report "far end (them)" "$SESSION/far.wav" \
  "check Screen Recording permission, and that $APP was actually playing audio" || far_ok=1
report "near end (you)" "$SESSION/near.wav" \
  "check Microphone permission and the selected input device" || near_ok=1

echo
if [[ "$far_ok" -eq 0 && "$near_ok" -eq 0 ]]; then
  echo "  BOTH CHANNELS CAPTURED"
  if [[ "$TRANSCRIBE" -eq 1 ]]; then
    echo
    "$HERE/transcribe.sh" "$SESSION" --me "$CALLCAP_ME" --them "Far end"
    echo
    echo "=== transcript ==="
    cat "$SESSION/transcript.md"
  fi
else
  echo "  PROBLEM FOUND — see the hint above. Raw audio kept at:"
  echo "  $SESSION"
  exit 1
fi
