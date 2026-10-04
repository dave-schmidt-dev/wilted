"""Acquire an ad-corpus input without touching the owner's library.

A corpus case needs the aligned speech-to-text the detector consumed, keyed by
the hash of the downloaded audio. The preparation cache that normally holds it
is a 32-entry working set, so inputs the library has since evicted (or never
held) are re-created here: fetch the episode's public audio into a scratch
directory, hash it the way the app's download coordinator does, run the
worker's own transcription and alignment against a scratch cache, and copy the
one cache entry into a snapshot directory that `ad_corpus.py --adopt` can pin.

`wilted_worker` has no standalone entry point, so this drives the same
functions `wilted_pipeline.run` calls, in the same order, and stops before
anything that edits audio or calls the language model.

Safety contract, enforced rather than promised:

* Every directory this module writes (scratch, cache, snapshot) is resolved
  through symlinks and `..`, then refused when it is, or is inside, the
  owner's `~/Library/Application Support/Wilted` tree or the preparation cache.
* Scratch is a `mkdtemp` directory under `$TMPDIR` and is removed on every exit
  path, including an interrupt.
* Speech-to-text goes through the resident speech daemon exactly as a
  preparation does; the daemon is its admission control. Only the language
  model load takes the shared GPU flock (see `ad_corpus.replay_spans`), and
  this module never loads it.
* Nothing here writes audio, transcript text or cue text into the repository.
  The returned record carries hashes, counts and durations only.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import shutil
import signal
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.request
from pathlib import Path

import ad_corpus

try:  # feeds are public but untrusted input
    from defusedxml import ElementTree as ET
except ImportError:  # pragma: no cover - the stdlib parser is the fallback
    import xml.etree.ElementTree as ET

LIBRARY_ROOT = Path.home() / "Library" / "Application Support" / "Wilted"
USER_AGENT = "wilted-ad-corpus-acquire/1 (+local research; no credentials)"
CHUNK = 1 << 20
PROGRESS_EVERY_BYTES = 8 << 20
HEARTBEAT_SECONDS = 30.0
ITUNES = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"


class RefusedOutputPath(ValueError):
    """An output path would land in the owner's library or preparation cache."""


def protected_roots() -> list[Path]:
    """The trees this module must never write into."""
    return [LIBRARY_ROOT, ad_corpus.DEFAULT_ALIGNED_CACHE, ad_corpus.DEFAULT_AD_CORPUS_INPUTS]


def _key(path: Path) -> str:
    # APFS is case- and normalisation-insensitive by default.
    return unicodedata.normalize("NFC", str(path)).casefold()


def _deepest_existing(path: Path) -> Path:
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return probe


def resolved(path: Path | str) -> Path:
    """Real path with symlinks and `..` resolved, whether or not it exists yet."""
    return Path(os.path.realpath(os.path.expanduser(str(path))))


def _inside(candidate: Path, root: Path) -> bool:
    resolved_root = resolved(root)
    text, root_text = _key(candidate), _key(resolved_root)
    if text == root_text or text.startswith(root_text + os.sep):
        return True
    # Same inode as the root: catches a spelling the string comparison cannot.
    if resolved_root.exists():
        return any(ancestor.exists() and os.path.samefile(ancestor, resolved_root)
                   for ancestor in [candidate, *candidate.parents])
    return False


def check_output_path(path: Path | str, *, roots: list[Path] | None = None) -> Path:
    """Return the resolved path, or raise `RefusedOutputPath` for a protected one."""
    candidate = resolved(path)
    for root in (protected_roots() if roots is None else roots):
        if _inside(candidate, Path(root)):
            raise RefusedOutputPath(f"refusing to write under the owner's library or preparation cache: {candidate}")
    return candidate


@contextlib.contextmanager
def scratch_directory(prefix: str = "ad-corpus-acquire.", *, roots: list[Path] | None = None):
    """A `mkdtemp` directory under `$TMPDIR`, checked, and removed on every exit."""
    path = Path(tempfile.mkdtemp(prefix=prefix))
    try:
        check_output_path(path, roots=roots)
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


@contextlib.contextmanager
def _terminate_as_exit():
    """Turn SIGTERM into SystemExit so `finally` blocks (scratch removal) run."""
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous = signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


def log(message: str) -> None:
    print(f"ad-corpus-acquire: {message}", file=sys.stderr, flush=True)


def _open(url: str):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": USER_AGENT}), timeout=120)


def fetch_feed(url: str) -> bytes:
    log(f"fetching feed {url}")
    with _open(url) as response:
        return response.read()


def _seconds(text: str | None) -> float | None:
    if not text:
        return None
    try:
        parts = [float(piece) for piece in text.strip().split(":")]
    except ValueError:
        return None
    total = 0.0
    for piece in parts:
        total = total * 60 + piece
    return total


def feed_episodes(feed_xml: bytes) -> list[dict]:
    """Episodes of an RSS feed that carry an enclosure, newest first as listed."""
    episodes = []
    for item in ET.fromstring(feed_xml).iter("item"):
        enclosure = item.find("enclosure")
        if enclosure is None or not enclosure.get("url"):
            continue
        episodes.append({
            "title": (item.findtext("title") or "").strip(),
            "guid": (item.findtext("guid") or "").strip(),
            "published": (item.findtext("pubDate") or "").strip(),
            "declaredDurationSeconds": _seconds(item.findtext(f"{ITUNES}duration")),
            "enclosureURL": enclosure.get("url"),
        })
    return episodes


def select_episode(episodes: list[dict], *, title: str | None = None, nth: int = 0,
                   duration_near: float | None = None, tolerance: float = 3.0) -> dict:
    """Pick one episode by title substring or declared duration, else raise LookupError."""
    pool = episodes
    if title is not None:
        pool = [e for e in pool if title.casefold() in e["title"].casefold()]
    if duration_near is not None:
        pool = [e for e in pool if e["declaredDurationSeconds"] is not None
                and abs(e["declaredDurationSeconds"] - duration_near) <= tolerance]
    if len(pool) <= nth:
        raise LookupError(f"no episode matches title={title!r} duration_near={duration_near!r} nth={nth}")
    return pool[nth]


def fetch_audio(url: str, destination: Path, *, roots: list[Path] | None = None) -> dict:
    """Stream `url` to `destination`, hashing the bytes as the app's downloader does."""
    check_output_path(destination, roots=roots)
    hasher = hashlib.sha256()
    received = 0
    next_report = PROGRESS_EVERY_BYTES
    started = time.monotonic()
    with _open(url) as response, open(destination, "wb") as handle:
        declared = response.headers.get("Content-Length")
        log(f"downloading audio ({declared or 'unknown'} bytes declared)")
        while chunk := response.read(CHUNK):
            handle.write(chunk)
            hasher.update(chunk)
            received += len(chunk)
            if received >= next_report:
                log(f"downloaded {received >> 20} MiB in {time.monotonic() - started:.0f}s")
                next_report += PROGRESS_EVERY_BYTES
    if received == 0:
        raise RuntimeError("download returned no bytes")
    if declared and declared.isdigit() and int(declared) != received:
        raise RuntimeError(f"declared {declared} bytes, received {received}")
    return {"sourceHash": "sha256:" + hasher.hexdigest(), "byteCount": received}


def _heartbeat(label: str, stop: threading.Event) -> None:
    started = time.monotonic()
    while not stop.wait(HEARTBEAT_SECONDS):
        log(f"{label} still running, {time.monotonic() - started:.0f}s elapsed")


def transcribe_into_cache(audio: Path, source_hash: str, scratch: Path) -> dict:
    """Run the worker's transcription + alignment, caching under `scratch` only."""
    sources = ad_corpus.runtime_sources()
    if not (sources / "wilted" / "ads.py").is_file():
        raise RuntimeError(f"no Wilted runtime source under {sources}; set WILTED_PIPELINE_PYTHONPATH")
    sys.path.insert(0, str(sources))
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from wilted.execution_capability import execution_capability_scope  # noqa: PLC0415
    from wilted_worker import cue_timing, transcript_sources  # noqa: PLC0415
    from wilted_worker.constants import ALIGNED_STT_MODEL  # noqa: PLC0415

    check_output_path(scratch)
    duration = cue_timing.probe_duration(audio)
    request = {"sourceHash": source_hash, "alignedTranscriptModel": ALIGNED_STT_MODEL, "workDir": str(scratch)}
    stop = threading.Event()
    beat = threading.Thread(target=_heartbeat, args=("transcription", stop), daemon=True)
    log(f"transcribing {duration:.0f}s of audio with {ALIGNED_STT_MODEL} via the speech daemon")
    beat.start()
    try:
        with execution_capability_scope(owner_id="wilted-ad-corpus-acquire", data_dir=scratch):
            segments = transcript_sources.transcribe_with_daemon(audio, ALIGNED_STT_MODEL)
    finally:
        stop.set()
    segments = cue_timing.validate_aligned_segments(segments, duration)
    transcript_sources._store_cached_aligned_segments(request, source_hash, ALIGNED_STT_MODEL, segments)
    cache_directory = transcript_sources._aligned_cache_directory(request)
    entry = transcript_sources._aligned_cache_path(cache_directory, source_hash, ALIGNED_STT_MODEL)
    if not entry.is_file():
        raise RuntimeError("the worker did not store the aligned transcript")
    return {"durationSeconds": duration, "segmentCount": len(segments), "model": ALIGNED_STT_MODEL,
            "transcriptEndSeconds": float(segments[-1].end_s), "entry": entry}


def acquire(enclosure_url: str, snapshot_dir: Path, *, fetch=fetch_audio, transcribe=transcribe_into_cache,
            roots: list[Path] | None = None) -> dict:
    """Fetch, hash, transcribe and snapshot one episode; scratch never survives.

    Returns a record of hashes, counts and durations. The snapshot directory
    receives exactly one file, the worker's own cache entry.
    """
    destination = check_output_path(snapshot_dir, roots=roots)
    with _terminate_as_exit(), scratch_directory(roots=roots) as scratch:
        audio = scratch / "audio.bin"
        downloaded = fetch(enclosure_url, audio)
        result = transcribe(audio, downloaded["sourceHash"], scratch)
        destination.mkdir(parents=True, exist_ok=True)
        copied = destination / result["entry"].name
        shutil.copyfile(result["entry"], copied)
        record = {
            "sourceHash": downloaded["sourceHash"], "byteCount": downloaded["byteCount"],
            "durationSeconds": result["durationSeconds"], "segmentCount": result["segmentCount"],
            "transcriptEndSeconds": result["transcriptEndSeconds"], "sttModel": result["model"],
            "snapshotEntry": copied.name,
            "snapshotEntrySha256": hashlib.sha256(copied.read_bytes()).hexdigest(),
        }
    log(f"scratch removed; acquired {record['sourceHash']}")
    return record


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed", required=True, help="public RSS feed URL (no credentials)")
    parser.add_argument("--match-title", default=None, help="case-insensitive title substring")
    parser.add_argument("--duration-near", type=float, default=None, help="declared duration in seconds")
    parser.add_argument("--tolerance", type=float, default=3.0)
    parser.add_argument("--nth", type=int, default=0, help="index among matches, 0 = first listed")
    parser.add_argument("--snapshot-dir", type=Path, required=True)
    parser.add_argument("--record", type=Path, default=None, help="write the JSON record here")
    parser.add_argument("--list", action="store_true", help="print matching episodes (titles only) and stop")
    args = parser.parse_args(argv)

    try:
        episodes = feed_episodes(fetch_feed(args.feed))
        episode = select_episode(episodes, title=args.match_title, nth=args.nth,
                                 duration_near=args.duration_near, tolerance=args.tolerance)
        if args.list:
            for e in episodes:
                if (args.match_title is None or args.match_title.casefold() in e["title"].casefold()):
                    print(f"{e['published']} | {e['declaredDurationSeconds']} | {e['title']}")
            return 0
        log(f"selected: {episode['title']} ({episode['published']})")
        record = acquire(episode["enclosureURL"], args.snapshot_dir)
        record.update({k: episode[k] for k in ("title", "guid", "published", "declaredDurationSeconds")})
        record["feed"] = args.feed
    except RefusedOutputPath as refusal:
        log(f"REFUSED: {refusal}")
        return 3
    except Exception as error:  # noqa: BLE001 - reported as a stop reason, not a traceback
        log(f"STOP: {type(error).__name__}: {error}")
        return 1
    payload = json.dumps(record, indent=2, sort_keys=True)
    if args.record is not None:
        target = check_output_path(args.record)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(payload + "\n", encoding="utf-8")
    print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
