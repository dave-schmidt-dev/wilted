"""Fetch one recent episode per subscribed feed and transcribe it for the ad gold set.

The gold set is the owner-confirmed answer key for ad detection: Opus proposes
each episode's ad breaks from its transcript, the owner confirms them in
`ad_gold_review.py`, and `ad_gold_finish.py` keeps only padded clips around the
confirmed breaks. Labels are times in the audio, so any future speech-to-text
model or detector can be scored against them.

This step reads the library read-only for each feed's newest episode, downloads
its enclosure, and writes per show under the gold root:

- `episode.json`: show, title, ids, enclosure, audio hash and duration.
- `audio.<ext>`: the downloaded file, kept until the owner confirms the show.
- `transcript.json`: parakeet v3 segments and word timings.
- `transcript.txt`: one `[seconds] text` line per segment, the labeller's input.

Everything lands outside the repository; podcast audio and prose never enter it.
Re-running skips any show whose files are already complete.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

WILTED_SUPPORT = Path.home() / "Library" / "Application Support" / "Wilted"
DEFAULT_LIBRARY = WILTED_SUPPORT / "library.sqlite"
DEFAULT_ROOT = WILTED_SUPPORT / "adcorpus-inputs" / "gold"
REPO_ROOT = Path(__file__).resolve().parents[2]
# Core Data stores dates as seconds since 2001-01-01.
CORE_DATA_EPOCH = 978307200
MINIMUM_SECONDS = 300
USER_AGENT = "Wilted"

_LATEST_EPISODES = """
with ranked as (
  select e.ZFEEDID feed, e.ZID id, e.ZTITLE title, e.ZDURATIONSECONDS duration,
         e.ZENCLOSUREURL url, e.ZENCLOSUREMEDIATYPE media_type, e.ZPUBLISHEDTIME published,
         row_number() over (partition by e.ZFEEDID order by e.ZPUBLISHEDTIME desc) rank
  from ZPODCASTEPISODERECORD e
  where e.ZENCLOSUREURL is not null and coalesce(e.ZDURATIONSECONDS, ?) >= ?)
select coalesce(s.ZDISPLAYNAME, f.ZTITLE) show, r.id, r.title, r.duration, r.url, r.media_type, r.published
from ZPODCASTSUBSCRIPTIONRECORD s
join ZPODCASTFEEDRECORD f on f.ZID = s.ZFEEDID
join ranked r on r.feed = s.ZFEEDID and r.rank = 1
where s.ZENABLED = 1
order by show
"""


def slug(show: str) -> str:
    """A folder name for a show: lowercase ASCII words joined by hyphens."""
    words = re.findall(r"[a-z0-9]+", show.lower().replace("'", "").replace("’", ""))
    return "-".join(words) or "show"


def latest_episodes(library: Path) -> list[dict]:
    """The newest episode of at least five minutes for every enabled subscription.

    Retired episodes count: retention retires old episodes, and a feed whose
    episodes are all retired still has a newest one worth labelling.
    """
    uri = f"file:{library}?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        rows = connection.execute(
            _LATEST_EPISODES, (MINIMUM_SECONDS, MINIMUM_SECONDS)
        ).fetchall()
    episodes = []
    for show, episode_id, title, duration, url, media_type, published in rows:
        published_at = None
        if published is not None:
            published_at = datetime.fromtimestamp(
                published + CORE_DATA_EPOCH, timezone.utc
            ).isoformat()
        episodes.append(
            {
                "show": show,
                "slug": slug(show),
                "episodeID": episode_id,
                "title": title,
                "feedDurationSeconds": duration,
                "enclosureURL": url,
                "mediaType": media_type,
                "publishedAt": published_at,
            }
        )
    return episodes


def audio_extension(url: str, media_type: str | None) -> str:
    """The file extension for an enclosure, from its path or else its media type."""
    path = url.split("?", 1)[0].lower()
    for extension in ("mp3", "m4a", "aac", "mp4", "ogg", "opus", "wav"):
        if path.endswith("." + extension):
            return extension
    return {"audio/mp4": "m4a", "audio/x-m4a": "m4a", "audio/aac": "aac"}.get(
        media_type or "", "mp3"
    )


def words_from_segments(segments) -> list[list]:
    """Word timings `[start, end, text]` from the aligned tokens of each segment.

    A token that begins with whitespace starts a word; the rest continue it.
    A segment without tokens contributes its words spread evenly over its span.
    """
    words: list[list] = []
    for segment in segments:
        tokens = getattr(segment, "tokens", None)
        if not tokens:
            parts = segment.text.split()
            step = (segment.end_s - segment.start_s) / max(len(parts), 1)
            words.extend(
                [
                    round(segment.start_s + i * step, 2),
                    round(segment.start_s + (i + 1) * step, 2),
                    part,
                ]
                for i, part in enumerate(parts)
            )
            continue
        current: list | None = None
        for token in tokens:
            if current is None or token.text[:1].isspace():
                if current is not None and current[2].strip():
                    words.append(current)
                current = [
                    round(token.start_s, 2),
                    round(token.end_s, 2),
                    token.text.strip(),
                ]
            else:
                current[1] = round(token.end_s, 2)
                current[2] += token.text
        if current is not None and current[2].strip():
            words.append(current)
    return words


def labeller_text(segments: list[dict]) -> str:
    """One `[seconds] text` line per segment for the labeller to read."""
    return "".join(
        f"[{segment['start_s']:.1f}] {segment['text']}\n" for segment in segments
    )


def sha256(path: Path) -> str:
    """Hex SHA-256 of a file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def duration_seconds(path: Path) -> float:
    """The audio duration ffprobe reports."""
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            str(path),
        ],
        text=True,
    )
    return round(float(output.strip()), 2)


def say(message: str) -> None:
    """One timestamped progress line on stdout."""
    print(f"{datetime.now().strftime('%H:%M:%S')} {message}", flush=True)


def download(episode: dict, folder: Path) -> Path:
    """Download the enclosure once; a partial download is replaced on the next run."""
    target = (
        folder
        / f"audio.{audio_extension(episode['enclosureURL'], episode['mediaType'])}"
    )
    if target.exists():
        return target
    partial = target.with_suffix(target.suffix + ".part")
    started = time.monotonic()
    say(f"download {episode['slug']}: {episode['title']}")
    subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--retry",
            "2",
            "--max-time",
            "1800",
            "--user-agent",
            USER_AGENT,
            "--output",
            str(partial),
            episode["enclosureURL"],
        ],
        check=True,
    )
    partial.rename(target)
    say(
        f"downloaded {episode['slug']}: {target.stat().st_size / 1e6:.0f} MB in {time.monotonic() - started:.0f} s"
    )
    return target


def transcribe(audio: Path, folder: Path, model: str) -> None:
    """Transcribe with the app's aligned speech-to-text and write both transcript files."""
    sys.path.insert(0, str(REPO_ROOT / "Producer" / "Runtime" / "src"))
    sys.path.insert(0, str(REPO_ROOT / "Producer" / "Workers"))
    from wilted.execution_capability import execution_capability_scope
    from wilted_worker.transcript_sources import transcribe_with_daemon

    started = time.monotonic()
    say(f"transcribe {folder.name}")
    with execution_capability_scope(owner_id="wilted-ad-gold", data_dir=folder):
        segments = transcribe_with_daemon(audio, model=model)
    record = {
        "model": model,
        "segments": [
            {
                "start_s": round(s.start_s, 2),
                "end_s": round(s.end_s, 2),
                "text": s.text.strip(),
            }
            for s in segments
        ],
        "words": words_from_segments(segments),
    }
    (folder / "transcript.json").write_text(json.dumps(record))
    (folder / "transcript.txt").write_text(labeller_text(record["segments"]))
    say(
        f"transcribed {folder.name}: {len(record['segments'])} segments, {len(record['words'])} words "
        f"in {time.monotonic() - started:.0f} s"
    )


def fetch(episode: dict, root: Path, model: str) -> bool:
    """Download, describe and transcribe one episode. False when it failed."""
    folder = root / episode["slug"]
    folder.mkdir(parents=True, exist_ok=True)
    try:
        audio = download(episode, folder)
        details = folder / "episode.json"
        if not details.exists():
            details.write_text(
                json.dumps(
                    {
                        **episode,
                        "audioFile": audio.name,
                        "audioSha256": sha256(audio),
                        "durationSeconds": duration_seconds(audio),
                        "fetchedAt": datetime.now(timezone.utc).isoformat(),
                    },
                    indent=2,
                )
            )
        if not (folder / "transcript.json").exists():
            transcribe(audio, folder, model)
        return True
    except (subprocess.CalledProcessError, OSError, ValueError, RuntimeError) as error:
        say(f"FAILED {episode['slug']}: {type(error).__name__}: {error}")
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--library", type=Path, default=DEFAULT_LIBRARY)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument(
        "--only", action="append", default=[], help="show slug to fetch (repeatable)"
    )
    parser.add_argument(
        "--list", action="store_true", help="print the chosen episodes and stop"
    )
    args = parser.parse_args(argv)
    sys.path.insert(0, str(REPO_ROOT / "Producer" / "Workers"))
    from wilted_worker.constants import ALIGNED_STT_MODEL

    episodes = [
        e
        for e in latest_episodes(args.library)
        if not args.only or e["slug"] in args.only
    ]
    if args.list:
        for episode in episodes:
            print(
                f"{episode['slug']}\t{episode['publishedAt'][:10] if episode['publishedAt'] else '?'}\t{episode['title']}"
            )
        return 0
    failed = []
    for index, episode in enumerate(episodes, 1):
        say(f"[{index}/{len(episodes)}] {episode['show']}")
        if not fetch(episode, args.root, ALIGNED_STT_MODEL):
            failed.append(episode["slug"])
    say(
        f"done: {len(episodes) - len(failed)} of {len(episodes)} ready"
        + (f"; failed {', '.join(failed)}" if failed else "")
    )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
