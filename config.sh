#!/usr/bin/env bash
# Shared configuration for callcap.
#
# Precedence: command-line flags > environment > ~/.config/callcap/config.env >
# the defaults below. Nothing here is specific to a person, machine or company;
# put your own values in the config file rather than editing this.

CALLCAP_CONFIG_DIR="${CALLCAP_CONFIG_DIR:-$HOME/.config/callcap}"

# shellcheck disable=SC1091
[[ -f "$CALLCAP_CONFIG_DIR/config.env" ]] && source "$CALLCAP_CONFIG_DIR/config.env"

# Where recordings and transcripts are written.
CALLCAP_DIR="${CALLCAP_DIR:-$HOME/Documents/call-recordings}"

# How your own channel is labelled. Falls back to the account's full name.
if [[ -z "${CALLCAP_ME:-}" ]]; then
  CALLCAP_ME="$(id -F 2>/dev/null | awk '{print $1}')"
  CALLCAP_ME="${CALLCAP_ME:-Me}"
fi

# whisper.cpp. Discovered on PATH so this is not tied to one package manager
# or CPU architecture.
CALLCAP_WHISPER_BIN="${CALLCAP_WHISPER_BIN:-$(command -v whisper-cli || true)}"
CALLCAP_MODEL="${CALLCAP_MODEL:-$HOME/.cache/whisper-cpp/ggml-large-v3.bin}"
CALLCAP_THREADS="${CALLCAP_THREADS:-$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 8)}"
CALLCAP_LANGUAGE="${CALLCAP_LANGUAGE:-en}"

# Domain terms that improve transcription of jargon and proper nouns. User
# owned: the tool ships an example, never a vocabulary of its own.
CALLCAP_VOCABULARY="${CALLCAP_VOCABULARY:-$CALLCAP_CONFIG_DIR/vocabulary.txt}"

# Auto-stop, in minutes; 0 disables. Overridden per-run by flags.
CALLCAP_SILENCE_TIMEOUT="${CALLCAP_SILENCE_TIMEOUT:-5}"
CALLCAP_MAX_DURATION="${CALLCAP_MAX_DURATION:-180}"

# Optional: default input device name, and a default app to capture. Empty
# means "system default microphone" and "all system audio" respectively —
# the combination that works without knowing anything about the setup.
CALLCAP_MIC="${CALLCAP_MIC:-}"
CALLCAP_APP="${CALLCAP_APP:-}"

callcap_require() {
  local missing=0
  [[ -x "$CALLCAP_WHISPER_BIN" ]] || { echo "whisper-cli not found — brew install whisper-cpp" >&2; missing=1; }
  [[ -f "$CALLCAP_MODEL" ]] || {
    echo "whisper model not found at $CALLCAP_MODEL" >&2
    echo "  download one, e.g.:" >&2
    echo "  curl -L --create-dirs -o \"$CALLCAP_MODEL\" \\" >&2
    echo "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin" >&2
    missing=1
  }
  command -v ffmpeg >/dev/null || { echo "ffmpeg not found — brew install ffmpeg" >&2; missing=1; }
  command -v jq >/dev/null || { echo "jq not found — brew install jq" >&2; missing=1; }
  return $missing
}
