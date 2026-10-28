"""Snap a labeller's proposed ad breaks onto word boundaries for the ad gold set.

The labeller (Opus, reading `transcript.txt`) writes `labels.opus.raw.json` in a
show's gold folder: segment-resolution times plus the first and last few words
of each break, quoted from the transcript. This step finds those words in the
word timings of `transcript.json` and writes `labels.opus.json` with each edge
on the first word's start and the last word's end, the input the review page
reads. An edge whose words cannot be found keeps the labeller's time, moved to
the nearest word boundary, and is flagged so the owner checks it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from ad_gold_fetch import DEFAULT_ROOT

KINDS = {"sponsor", "house-promo", "network-promo", "intro", "outro", "other"}
LABELS = {"must-cut", "acceptable-cut"}
CONFIDENCES = {"high", "medium", "low"}
QUOTE_WORDS = 4
START_WINDOW = (-20.0, 20.0)
END_WINDOW = (-20.0, 45.0)
# The aligner stretches a sentence's last word over the pause after it
# ("exceptional." 38.96-41.2), so an end edge stops this long after the word starts.
LONGEST_WORD_S = 1.2
GAP_S = 8.0
# The review page lists a gap only when it is long or beside a break: short music
# beds inside a story (Radiolab) are not worth the owner's time.
REVIEW_GAP_S = 20.0
NEAR_BREAK_S = 30.0


class LabelError(ValueError):
    """The labeller's file is missing or malformed."""


def normalized(word: str) -> str:
    """A word reduced to lowercase letters and digits, for matching quotes to timings."""
    return re.sub(r"[^a-z0-9]", "", word.lower())


def quote_tokens(quote: str, from_end: bool) -> list[str]:
    """Up to `QUOTE_WORDS` normalized words from the start (or end) of a quote."""
    tokens = [token for token in (normalized(part) for part in quote.split()) if token]
    return tokens[-QUOTE_WORDS:] if from_end else tokens[:QUOTE_WORDS]


def find_sequence(
    words: list[list], tokens: list[str], near: float, window: tuple[float, float]
) -> int | None:
    """Index of the first word of the run matching `tokens` closest to `near`, inside the window."""
    if not tokens:
        return None
    keys = [normalized(word[2]) for word in words]
    best = None
    for index in range(len(words) - len(tokens) + 1):
        if not near + window[0] <= words[index][0] <= near + window[1]:
            continue
        if keys[index : index + len(tokens)] == tokens:
            distance = abs(words[index][0] - near)
            if best is None or distance < best[0]:
                best = (distance, index)
    return None if best is None else best[1]


def word_end(word: list) -> float:
    """Where a word stops, ignoring any pause the aligner folded into it."""
    return min(word[1], word[0] + LONGEST_WORD_S)


def untranscribed_gaps(words: list[list], duration: float | None, minimum: float = GAP_S) -> list[list[float]]:
    """Stretches of at least `minimum` seconds with no transcribed word: music, or speech v3 dropped.

    Ad openings over a music bed are often missing from the transcript, so the
    review page lists these for the owner to listen to.
    """
    edges = [0.0] + [edge for word in words for edge in (word[0], word_end(word))] + [duration or 0.0]
    gaps = []
    for index in range(0, len(edges) - 1, 2):
        start, end = edges[index], edges[index + 1]
        if end - start >= minimum:
            gaps.append([round(start, 2), round(end, 2)])
    return gaps


def review_gaps(
    gaps: list[list[float]], ranges: list[dict], long_s: float = REVIEW_GAP_S, near_s: float = NEAR_BREAK_S
) -> list[list[float]]:
    """The gaps worth listening to: at least `long_s` long, or within `near_s` of a labelled break."""
    return [
        [start, end]
        for start, end in gaps
        if end - start >= long_s
        or any(start - near_s <= r["end_s"] and r["start_s"] <= end + near_s for r in ranges)
    ]


def nearest_boundary(words: list[list], seconds: float, use_end: bool) -> float:
    """The word start (or end) closest to `seconds`."""
    edge = 1 if use_end else 0
    return min(
        (word[edge] for word in words),
        key=lambda value: abs(value - seconds),
        default=seconds,
    )


def snap_range(raw: dict, words: list[list], ordinal: int) -> dict:
    """One labelled range with word-accurate edges."""
    for key, allowed in (
        ("kind", KINDS),
        ("label", LABELS),
        ("confidence", CONFIDENCES),
    ):
        if raw.get(key) not in allowed:
            raise LabelError(
                f"range {ordinal}: {key} {raw.get(key)!r} is not one of {sorted(allowed)}"
            )
    start_s, end_s = float(raw["start_s"]), float(raw["end_s"])
    first = quote_tokens(str(raw.get("first_words", "")), from_end=False)
    last = quote_tokens(str(raw.get("last_words", "")), from_end=True)
    start_index = find_sequence(words, first, start_s, START_WINDOW)
    end_index = find_sequence(words, last, end_s, END_WINDOW)
    snapped_start = (
        words[start_index][0]
        if start_index is not None
        else nearest_boundary(words, start_s, False)
    )
    snapped_end = (
        word_end(words[end_index + len(last) - 1])
        if end_index is not None
        else nearest_boundary(words, end_s, True)
    )
    unmatched = [
        name
        for name, index in (("start", start_index), ("end", end_index))
        if index is None
    ]
    if snapped_end <= snapped_start:
        snapped_start, snapped_end = start_s, max(end_s, start_s + 1.0)
        unmatched = ["start", "end"]
    note = str(raw.get("note", "")).strip()
    if unmatched:
        note = (
            note + " " if note else ""
        ) + f"[check {' and '.join(unmatched)}: quoted words not found]"
    return {
        "id": f"r{ordinal}",
        "start_s": round(snapped_start, 2),
        "end_s": round(snapped_end, 2),
        "kind": raw["kind"],
        "label": raw["label"],
        "confidence": "low" if unmatched else raw["confidence"],
        "sponsor": raw.get("sponsor") or None,
        "note": note,
    }


def snap_show(folder: Path) -> dict:
    """Read the raw labels and transcript in `folder`, write and return `labels.opus.json`."""
    raw_path = folder / "labels.opus.raw.json"
    try:
        raw = json.loads(raw_path.read_text())
        words = json.loads((folder / "transcript.json").read_text())["words"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        raise LabelError(f"{folder.name}: {error}") from error
    if not isinstance(raw.get("ranges"), list) or not isinstance(
        raw.get("pattern"), str
    ):
        raise LabelError(f"{folder.name}: needs a pattern string and a ranges list")
    ranges = sorted(
        (snap_range(item, words, i) for i, item in enumerate(raw["ranges"], 1)),
        key=lambda item: item["start_s"],
    )
    duration = json.loads((folder / "episode.json").read_text()).get("durationSeconds") if (folder / "episode.json").exists() else None
    labels = {"pattern": raw["pattern"].strip(), "ranges": ranges, "gaps": review_gaps(untranscribed_gaps(words, duration), ranges)}
    (folder / "labels.opus.json").write_text(json.dumps(labels, indent=2))
    return labels


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument(
        "slugs", nargs="*", help="shows to snap (default: every show with raw labels)"
    )
    args = parser.parse_args(argv)
    folders = (
        [args.root / slug for slug in args.slugs]
        if args.slugs
        else sorted(path.parent for path in args.root.glob("*/labels.opus.raw.json"))
    )
    status = 0
    for folder in folders:
        try:
            labels = snap_show(folder)
        except LabelError as error:
            print(f"FAILED {error}", file=sys.stderr)
            status = 1
            continue
        flagged = sum("[check" in item["note"] for item in labels["ranges"])
        print(
            f"{folder.name}: {len(labels['ranges'])} ranges"
            + (f", {flagged} edges to check" if flagged else "")
        )
    return status


if __name__ == "__main__":
    sys.exit(main())
