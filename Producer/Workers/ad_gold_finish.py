"""Finish confirmed shows in the ad gold set: keep padded clips, export the labels.

Once the owner marks a show confirmed in the review page, the full download is
no longer needed. For each confirmed show this step:

1. Cuts one clip per ad break with `PADDING_S` of programme either side
   (overlapping windows merge), as 16 kHz mono Opus, the rate speech-to-text
   resamples to anyway, and records in `clips.json` where each clip sits in the
   original episode so labels keep their original times.
2. Moves the full download to the Trash (recoverable, never deleted outright).
3. Writes the confirmed labels for every confirmed show to `--export`
   (default `Producer/Workers/adcorpus/gold.json`): times, kinds, labels and the
   show's ad pattern, keyed to the audio's SHA-256. No transcript text or audio.

Without `--apply` it only prints what it would do.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from ad_gold_fetch import DEFAULT_ROOT, REPO_ROOT

PADDING_S = 120.0
CLIP_SAMPLE_RATE = 16000
CLIP_BITRATE = "48k"
DEFAULT_EXPORT = REPO_ROOT / "Producer" / "Workers" / "adcorpus" / "gold.json"
TRASH = Path.home() / ".Trash"


def load_json(path: Path):
    """Parsed JSON from `path`, or None when it is absent."""
    return json.loads(path.read_text()) if path.exists() else None


def confirmed_review(folder: Path) -> dict | None:
    """The show's review when the owner confirmed it and nothing is pending."""
    review = load_json(folder / "review.json")
    if not review or review.get("status") != "confirmed":
        return None
    if any(item.get("decision") != "confirmed" for item in review.get("ranges", [])):
        return None
    return review


def clip_windows(
    ranges: list[dict], duration: float, padding: float = PADDING_S
) -> list[tuple[float, float]]:
    """Padded windows around every cut range, merged where they overlap."""
    windows: list[list[float]] = []
    for item in sorted(
        (r for r in ranges if r["label"] != "not-ad"), key=lambda r: r["start_s"]
    ):
        start, end = (
            max(0.0, item["start_s"] - padding),
            min(duration, item["end_s"] + padding),
        )
        if windows and start <= windows[-1][1]:
            windows[-1][1] = max(windows[-1][1], end)
        else:
            windows.append([start, end])
    return [(round(start, 2), round(end, 2)) for start, end in windows]


def cut_clips(
    folder: Path, audio: Path, windows: list[tuple[float, float]]
) -> list[dict]:
    """Encode each window as a clip; returns the `clips.json` entries."""
    clips = []
    for index, (start, end) in enumerate(windows, 1):
        name = f"clip-{index:02d}.opus"
        subprocess.run(
            [
                "ffmpeg",
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-ss",
                f"{start}",
                "-to",
                f"{end}",
                "-i",
                str(audio),
                "-ac",
                "1",
                "-ar",
                str(CLIP_SAMPLE_RATE),
                "-c:a",
                "libopus",
                "-b:a",
                CLIP_BITRATE,
                str(folder / name),
            ],
            check=True,
        )
        clips.append({"file": name, "sourceStart_s": start, "sourceEnd_s": end})
    return clips


def trash(path: Path) -> Path:
    """Move `path` into the user's Trash under a unique name and return the new path."""
    target = TRASH / f"wilted-gold-{path.parent.name}-{path.name}"
    suffix = 1
    while target.exists():
        suffix += 1
        target = TRASH / f"wilted-gold-{path.parent.name}-{suffix}-{path.name}"
    shutil.move(str(path), target)
    return target


def export_entry(folder: Path, episode: dict, review: dict) -> dict:
    """The repository record for one confirmed show: times and labels only."""
    return {
        "slug": folder.name,
        "show": episode["show"],
        "episodeID": episode.get("episodeID"),
        "publishedAt": episode.get("publishedAt"),
        "audioSha256": f"sha256:{episode['audioSha256']}",
        "durationSeconds": episode["durationSeconds"],
        "pattern": review.get("pattern", ""),
        "confirmedAt": review.get("updatedAt"),
        "ranges": [
            {
                "start_s": item["start_s"],
                "end_s": item["end_s"],
                "kind": item["kind"],
                "label": item["label"],
                "origin": item.get("origin", "opus"),
            }
            for item in sorted(review["ranges"], key=lambda r: r["start_s"])
        ],
    }


def finish_show(folder: Path, apply: bool) -> dict | None:
    """Clip and trash one confirmed show; returns its export entry, or None when not confirmed."""
    review = confirmed_review(folder)
    episode = load_json(folder / "episode.json")
    if review is None or episode is None:
        return None
    audio = folder / episode["audioFile"]
    if audio.exists():
        windows = clip_windows(review["ranges"], episode["durationSeconds"])
        kept = sum(end - start for start, end in windows)
        print(
            f"{folder.name}: {len(windows)} clips, {kept / 60:.1f} of {episode['durationSeconds'] / 60:.1f} min kept"
        )
        if apply:
            clips = cut_clips(folder, audio, windows)
            (folder / "clips.json").write_text(
                json.dumps(
                    {
                        "audioSha256": episode["audioSha256"],
                        "sampleRate": CLIP_SAMPLE_RATE,
                        "codec": "opus",
                        "bitrate": CLIP_BITRATE,
                        "clips": clips,
                        "madeAt": datetime.now(timezone.utc).isoformat(),
                    },
                    indent=2,
                )
            )
            print(f"{folder.name}: full download moved to {trash(audio)}")
    return export_entry(folder, episode, review)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--export", type=Path, default=DEFAULT_EXPORT)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="cut clips, trash downloads and write the export",
    )
    args = parser.parse_args(argv)
    entries = [
        entry
        for folder in sorted(p for p in args.root.iterdir() if p.is_dir())
        if (entry := finish_show(folder, args.apply)) is not None
    ]
    pending = sum(1 for p in args.root.iterdir() if p.is_dir()) - len(entries)
    print(f"{len(entries)} confirmed, {pending} still to review")
    if args.apply:
        args.export.write_text(
            json.dumps({"version": 1, "shows": entries}, indent=2) + "\n"
        )
        print(f"wrote {args.export}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
