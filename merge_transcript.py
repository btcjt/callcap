#!/usr/bin/env python3
"""Merge two single-speaker whisper JSON outputs into one attributed transcript.

Each channel was recorded separately, so attribution is exact. The only real
work is interleaving by timestamp and suppressing the crosstalk that leaks
between channels (the far end is audible in the room mic, and vice versa).
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, asdict
from pathlib import Path

# Whisper emits these for silence or room tone; they are not speech.
NOISE = re.compile(
    r"^[\s\W]*(\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|blank_audio|silence|music|"
    r"inaudible|no speech)?[\s\W]*$",
    re.IGNORECASE,
)


@dataclass
class Segment:
    speaker: str
    start: float
    end: float
    text: str


def parse_timestamp(value: str) -> float:
    """'00:01:23,456' -> 83.456"""
    hours, minutes, rest = value.split(":")
    seconds, _, millis = rest.partition(",")
    return int(hours) * 3600 + int(minutes) * 60 + int(seconds) + int(millis or 0) / 1000


def load(path: Path, speaker: str) -> list[Segment]:
    data = json.loads(path.read_text())
    segments: list[Segment] = []
    for raw in data.get("transcription", []):
        text = raw.get("text", "").strip()
        if not text or NOISE.match(text):
            continue
        offsets = raw.get("offsets")
        if offsets:  # milliseconds — the precise form
            start, end = offsets["from"] / 1000, offsets["to"] / 1000
        else:
            ts = raw.get("timestamps", {})
            start, end = parse_timestamp(ts["from"]), parse_timestamp(ts["to"])
        segments.append(Segment(speaker, start, end, text))
    return segments


def drop_crosstalk(segments: list[Segment], window: float = 1.0) -> list[Segment]:
    """Remove a segment that merely echoes what the other channel said.

    Each mic picks up some of the other party (speaker bleed, or the far end
    leaking through an open room mic). Such a segment appears on both channels
    with near-identical text at near-identical times; the quieter, later copy
    is the echo.
    """

    def normalise(text: str) -> str:
        return re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()

    keep: list[Segment] = []
    for segment in segments:
        norm = normalise(segment.text)
        if len(norm) < 8:
            keep.append(segment)
            continue
        echo = any(
            other.speaker != segment.speaker
            and abs(other.start - segment.start) <= window
            and normalise(other.text) == norm
            for other in keep
        )
        if not echo:
            keep.append(segment)
    return keep


def collapse(segments: list[Segment], gap: float = 1.5) -> list[Segment]:
    """Join consecutive segments from the same speaker into one turn."""
    turns: list[Segment] = []
    for segment in segments:
        if turns and turns[-1].speaker == segment.speaker and segment.start - turns[-1].end <= gap:
            turns[-1].end = segment.end
            turns[-1].text = f"{turns[-1].text} {segment.text}".strip()
        else:
            turns.append(Segment(**asdict(segment)))
    return turns


def clock(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--far", required=True, type=Path)
    parser.add_argument("--near", required=True, type=Path)
    parser.add_argument("--them", default="Them")
    parser.add_argument("--me", default="Me")
    parser.add_argument("--meta", type=Path)
    parser.add_argument("--out-md", required=True, type=Path)
    parser.add_argument("--out-json", required=True, type=Path)
    args = parser.parse_args()

    segments = load(args.far, args.them) + load(args.near, args.me)
    segments.sort(key=lambda s: (s.start, s.speaker))
    turns = collapse(drop_crosstalk(segments))

    meta = {}
    if args.meta and args.meta.exists():
        meta = json.loads(args.meta.read_text())

    duration = max((t.end for t in turns), default=0.0)
    words = sum(len(t.text.split()) for t in turns)
    by_speaker = {
        name: round(sum(t.end - t.start for t in turns if t.speaker == name), 1)
        for name in {t.speaker for t in turns}
    }

    args.out_json.write_text(
        json.dumps(
            {
                "session": meta.get("session"),
                "recordedAt": meta.get("recordedAt"),
                "app": meta.get("app"),
                "durationSeconds": round(duration, 1),
                "wordCount": words,
                "speakingSeconds": by_speaker,
                "turns": [asdict(t) for t in turns],
            },
            indent=2,
        )
    )

    lines = [
        f"# Call transcript — {meta.get('session', args.out_md.parent.name)}",
        "",
        f"- Recorded: {meta.get('recordedAt', 'unknown')}",
        f"- Duration: {clock(duration)}",
        f"- Speakers: {args.them} (far end), {args.me} (microphone)",
        f"- Speaking time: " + ", ".join(f"{k} {clock(v)}" for k, v in sorted(by_speaker.items())),
        f"- Words: {words}",
        "",
        "---",
        "",
    ]
    for turn in turns:
        lines.append(f"**[{clock(turn.start)}] {turn.speaker}:** {turn.text}")
        lines.append("")

    args.out_md.write_text("\n".join(lines))
    print(f"    {len(turns)} turns, {words} words, {clock(duration)}")


if __name__ == "__main__":
    main()
