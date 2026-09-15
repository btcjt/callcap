#!/usr/bin/env bash
# Shared audio-level helpers.
#
# Extracted so selftest.sh can regression-test them: volumedetect reports at
# ffmpeg's *info* level, so running it under `-v error` silently yields no
# numbers and every channel reads as silent no matter what it contains.

# audio_levels <file> -> "<mean>|<peak>", empty fields if unavailable
audio_levels() {
  local out
  out="$(ffmpeg -nostdin -hide_banner -i "$1" -af volumedetect -f null - 2>&1)"
  printf '%s|%s' \
    "$(awk -F'mean_volume: ' '/mean_volume/ {print $2}' <<<"$out")" \
    "$(awk -F'max_volume: ' '/max_volume/ {print $2}' <<<"$out")"
}

# audio_is_silent <mean-string> -> 0 when silent/unreadable
audio_is_silent() {
  local mean="${1% dB}"
  [[ -z "$mean" ]] && return 0
  (( $(echo "$mean < -60" | bc -l) ))
}

# warn_if_silent <label> <wav> <hint> -> 0 when the file carries audio;
# otherwise prints a warning on stderr and returns 1 (missing file or silent)
warn_if_silent() {
  local mean
  if [[ ! -f "$2" ]]; then
    echo "warning: $1: no audio file — $3" >&2
    return 1
  fi
  mean="$(audio_levels "$2" | cut -d'|' -f1)"
  if audio_is_silent "$mean"; then
    echo "warning: $1 is SILENT (mean ${mean:-unreadable}) — $3" >&2
    return 1
  fi
  return 0
}
