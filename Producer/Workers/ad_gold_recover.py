"""Bring speech recovered by a second transcription into the ad gold set's reviews.

The first transcripts lost stretches of speech where the decoder went silent.
After `ad_gold_fetch.py --retranscribe` (which keeps the old transcript as
`transcript.previous.json`), this step:

1. `list`: finds the stretches the new transcript filled, writes
   `recovered.json` and a `recovered.txt` excerpt (with surrounding lines) for
   the labeller, who writes any ads it finds there to `labels.recovered.raw.json`
   in the same format as `labels.opus.raw.json`.
2. `merge`: snaps those ranges to word timings and appends them to
   `labels.opus.json` and, when the owner has started reviewing, to
   `review.json` as pending, reopening a finished show. The owner's decisions
   are never changed. It also recomputes the gaps the review page lists.

Close the review page tab for a show before merging into it: an open page
saves its own copy of the review on the next click.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

from ad_gold_fetch import DEFAULT_ROOT
from ad_gold_label import (
    LabelError,
    review_gaps,
    snap_range,
    untranscribed_gaps,
    word_end,
)

MINIMUM_WORDS = 3
CONTEXT_S = 30.0
DUPLICATE_OVERLAP = 0.5


def recovered_stretches(
    previous: list[list], words: list[list], duration: float | None
) -> list[list[float]]:
    """Stretches of new words inside the previous transcript's gaps."""
    stretches = []
    for start, end in untranscribed_gaps(previous, duration):
        inside = [w for w in words if start < w[0] < end]
        if len(inside) >= MINIMUM_WORDS:
            stretches.append([inside[0][0], round(word_end(inside[-1]), 2)])
    return stretches


def excerpt(transcript_text: str, stretches: list[list[float]]) -> str:
    """The transcript lines within `CONTEXT_S` of any stretch, with a marker between runs."""
    lines, kept, last = transcript_text.splitlines(), [], None
    for index, line in enumerate(lines):
        try:
            at = float(line[1 : line.index("]")])
        except ValueError:
            continue
        if any(s - CONTEXT_S <= at <= e + CONTEXT_S for s, e in stretches):
            if last is not None and index != last + 1:
                kept.append("...")
            kept.append(line)
            last = index
    return "\n".join(kept) + "\n"


def list_show(folder: Path) -> list[list[float]]:
    """Write `recovered.json` and `recovered.txt` for one show and return its stretches."""
    previous_path = folder / "transcript.previous.json"
    if not previous_path.exists():
        return []
    previous = json.loads(previous_path.read_text())["words"]
    words = json.loads((folder / "transcript.json").read_text())["words"]
    duration = json.loads((folder / "episode.json").read_text()).get("durationSeconds")
    stretches = recovered_stretches(previous, words, duration)
    (folder / "recovered.json").write_text(
        json.dumps({"stretches": stretches}, indent=2)
    )
    (folder / "recovered.txt").write_text(
        excerpt((folder / "transcript.txt").read_text(), stretches)
    )
    return stretches


def overlaps_existing(item: dict, ranges: list[dict]) -> bool:
    """True when most of `item` is already covered by one existing range."""
    length = item["end_s"] - item["start_s"]
    return any(
        min(item["end_s"], r["end_s"]) - max(item["start_s"], r["start_s"])
        >= DUPLICATE_OVERLAP * length
        for r in ranges
    )


def write_atomically(path: Path, data: dict) -> None:
    """Replace `path` with `data` as JSON without a window where it is half-written."""
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    with os.fdopen(handle, "w") as file:
        json.dump(data, file, indent=2)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def merge_show(folder: Path) -> int:
    """Append the labeller's recovered ranges to the show's labels and review; returns how many."""
    words = json.loads((folder / "transcript.json").read_text())["words"]
    duration = json.loads((folder / "episode.json").read_text()).get("durationSeconds")
    labels = json.loads((folder / "labels.opus.json").read_text())
    raw_path = folder / "labels.recovered.raw.json"
    raw = json.loads(raw_path.read_text())["ranges"] if raw_path.exists() else []
    review_path = folder / "review.json"
    review = json.loads(review_path.read_text()) if review_path.exists() else None
    existing = labels["ranges"] + (review["ranges"] if review else [])
    taken = {r["id"] for r in existing}
    added, number = [], 0
    for ordinal, item in enumerate(raw, 1):
        snapped = snap_range(item, words, ordinal)
        number += 1
        while f"x{number}" in taken:
            number += 1
        snapped["id"] = f"x{number}"
        taken.add(snapped["id"])
        if not overlaps_existing(snapped, existing + added):
            added.append(snapped)
    labels["ranges"] = sorted(labels["ranges"] + added, key=lambda r: r["start_s"])
    labels["gaps"] = review_gaps(untranscribed_gaps(words, duration), labels["ranges"])
    write_atomically(folder / "labels.opus.json", labels)
    if review is not None and added:
        review["ranges"] = sorted(
            review["ranges"]
            + [
                {
                    "id": r["id"],
                    "start_s": r["start_s"],
                    "end_s": r["end_s"],
                    "kind": r["kind"],
                    "label": r["label"],
                    "decision": "pending",
                    "origin": "opus",
                    "opus": dict(r),
                }
                for r in added
            ],
            key=lambda r: r["start_s"],
        )
        if review.get("status") in ("confirmed", "needs-second-episode"):
            review["status"] = "in-progress"
        write_atomically(review_path, review)
    return len(added)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("action", choices=("list", "merge"))
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument(
        "slugs",
        nargs="*",
        help="shows (default: every show with a previous transcript)",
    )
    args = parser.parse_args(argv)
    folders = (
        [args.root / slug for slug in args.slugs]
        if args.slugs
        else sorted(p.parent for p in args.root.glob("*/transcript.previous.json"))
    )
    status = 0
    for folder in folders:
        try:
            if args.action == "list":
                stretches = list_show(folder)
                print(
                    f"{folder.name}: {len(stretches)} recovered, {sum(e - s for s, e in stretches):.0f} s"
                )
            else:
                print(f"{folder.name}: {merge_show(folder)} ranges added")
        except (OSError, KeyError, json.JSONDecodeError, LabelError) as error:
            print(
                f"FAILED {folder.name}: {type(error).__name__}: {error}",
                file=sys.stderr,
            )
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
