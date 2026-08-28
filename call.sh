#!/usr/bin/env bash
# Record a call and transcribe it in one step.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=config.sh
source "$HERE/config.sh"

# The recorder binary lives inside the app bundle; the wrapper on PATH is a
# shim, so call the bundle directly and stay independent of PATH ordering.
CALLCAP_BIN="${CALLCAP_APP_BUNDLE:-/Applications/Call Capture.app}/Contents/MacOS/callcap-rec"

usage() {
  cat <<USAGE
callcap [options] — record a call, then transcribe it

  --with <name>     who you are talking to; labels the far-end channel
                    and slugs the recording directory
  --app <app>       capture only this app, by name or bundle id — more
                    precise when you know which app owns the call
  --system          capture all system audio (the default)
  --mic <name>      input device to record you with. Naming a non-Bluetooth
                    mic keeps AirPods in high-quality listening mode.
  --silence-timeout <min>  stop after N min with no audio (default 5, 0 off)
  --max-duration <min>     hard cap (default 180, 0 off)
  --no-auto-stop           run until Ctrl-C regardless of length or silence
  --me <name>       label for your channel (default: $CALLCAP_ME)
  --no-transcribe   record only
  --help

Recording stops on Ctrl-C, after which transcription runs automatically.
USAGE
}

WITH=""; ME="$CALLCAP_ME"; APP="$CALLCAP_APP"; TRANSCRIBE=1; SYSTEM=0
MIC="$CALLCAP_MIC"; PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)          WITH="$2"; shift 2 ;;
    --me)            ME="$2"; shift 2 ;;
    --app)           APP="$2"; shift 2 ;;
    --system)        SYSTEM=1; shift ;;
    --mic)           MIC="$2"; shift 2 ;;
    --silence-timeout|--max-duration)
                     PASSTHROUGH+=("$1" "$2"); shift 2 ;;
    --no-auto-stop)  PASSTHROUGH+=("$1"); shift ;;
    --no-transcribe) TRANSCRIBE=0; shift ;;
    --help|-h)       usage; exit 0 ;;
    *)               echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

REC_ARGS=()
[[ -n "$WITH" ]] && REC_ARGS+=(--label "$(echo "$WITH" | tr '[:upper:] ' '[:lower:]-')")
[[ -n "$APP"  ]] && REC_ARGS+=(--app "$APP")
[[ "$SYSTEM" -eq 1 ]] && REC_ARGS+=(--system)
[[ -n "$MIC" ]] && REC_ARGS+=(--mic "$MIC")
REC_ARGS+=("${PASSTHROUGH[@]}")

# Ctrl-C reaches every process in the foreground group, so without a trap the
# wrapper dies alongside the recorder and transcription never runs, leaving a
# finished recording that silently never became a transcript.
#
# It must be `trap 'handler'`, never `trap ''`: an *ignored* signal is
# inherited by children, which would stop Ctrl-C reaching the recorder at all.
# A handled one is reset to default in the child, so the recorder still sees it
# and shuts down cleanly while this script survives to transcribe.
trap 'true' INT

# The recorder prints the session directory on stdout; everything else is
# progress output on stderr, so this capture stays clean.
SESSION="$(caffeinate -i "$CALLCAP_BIN" "${REC_ARGS[@]}" \
      2> >(grep -v "AVCaptureDeviceTypeExternal\|NSCameraUseContinuityCameraDeviceType" >&2))"
[[ -n "$SESSION" && -d "$SESSION" ]] || { echo "recording failed" >&2; exit 1; }

if [[ "$TRANSCRIBE" -eq 1 ]]; then
  echo
  # Restore default handling so a second Ctrl-C can abort transcription; the
  # recording is already safely on disk by this point.
  trap - INT
  "$HERE/transcribe.sh" "$SESSION" --me "$ME" --them "${WITH:-Them}"
else
  echo
  echo "recording saved. transcribe it with:"
  echo "  callcap-transcribe \"$SESSION\" --me \"$ME\" --them \"${WITH:-Them}\""
fi
