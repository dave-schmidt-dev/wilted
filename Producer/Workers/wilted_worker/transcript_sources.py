"""Worker module split from wilted_pipeline.py."""
from __future__ import annotations
import contextlib
import difflib
import errno
import fcntl
import html
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from . import cue_timing as _worker_cue_timing
from . import reporting as _worker_reporting
from .constants import ALIGNED_STT_CACHE_MAXIMUM_ENTRIES, ALIGNED_STT_CACHE_SCHEMA_VERSION, ALIGNED_STT_MODEL, MINIMUM_PROSE_WORDS, PUBLISHED_TRANSCRIPT_GAP_FLOOR_S, PUBLISHED_TRANSCRIPT_GAP_FRACTION, TIMED_MEDIA_TYPES
from .cue_timing import CachedAlignedSegment, in_time_order

CUE_MARKUP_PATTERN = re.compile(r"<[^>]*>")

CUE_VOICE_PATTERN = re.compile(r"^\s*<v(?:\.[^\s>]+)*\s+([^>]+)>")

MAXIMUM_SPEAKER_BYTES = 128

@dataclass(frozen=True)
class CueSegment:
    """A published-transcript segment with the speaker kept alongside the text.

    The archived parsers return their own segment type, which has nowhere to
    put a name.  This mirrors the attribute names the rest of the pipeline
    reads (`text`, `start_s`, `end_s`) so it can stand in for one, and adds the
    field the cue contract gained at transcript schema version three.
    """

    text: str
    start_s: float
    end_s: float
    speaker: str | None = None

def extract_cue_speaker(text: str) -> str | None:
    """Return the voice-span name opening this cue, if it has one."""
    match = CUE_VOICE_PATTERN.match(text)
    if not match:
        return None
    # The name is markup-free by construction but not entity-free: a publisher
    # writes "Ben &amp; Jerry" the same way inside a voice span as anywhere else.
    name = html.unescape(match.group(1)).strip()
    if not name or len(name.encode("utf-8")) > MAXIMUM_SPEAKER_BYTES:
        return None
    return name

def strip_cue_markup(segments):
    """Return segments whose text is the spoken words alone, speaker preserved.

    Cues that hold nothing but markup are dropped rather than emitted empty:
    the Swift cue contract rejects empty text, and a blank cue would stall the
    reader on a line with nothing to read.  A cue that was only a voice tag
    loses its name with it -- there is no text for the name to belong to.
    """
    cleaned = []
    for segment in segments:
        # The name has to come out before the markup does, for the obvious
        # reason: stripping is what destroys it.
        speaker = extract_cue_speaker(segment.text)
        # Order matters here too.  A literal "<" inside a cue payload has to be
        # written "&lt;", so unescaping first would manufacture markup out of
        # words somebody actually said and then strip them.
        text = CUE_MARKUP_PATTERN.sub("", segment.text)
        text = html.unescape(text)
        text = re.sub(r"\s+", " ", text).strip()
        if not text:
            continue
        cleaned.append(CueSegment(
            text=text,
            start_s=float(segment.start_s),
            end_s=float(segment.end_s),
            speaker=speaker,
        ))
    return cleaned

def parse_published_transcript(body: str, media_type: str, url: str):
    """Parse a transcript the feed published, or return None if unusable."""
    from wilted import transcribe

    parsers = {
        "vtt": transcribe.parse_vtt,
        "srt": transcribe.parse_srt,
        "podcast-json": transcribe.parse_podcast_json,
    }
    kind = TIMED_MEDIA_TYPES.get(media_type.strip().lower())
    if kind is None:
        # The type attribute is advisory and publishers get it wrong. Falling
        # back to the extension recovers a real transcript that would
        # otherwise be thrown away for a typo.
        lowered = url.lower()
        for extension, guess in ((".vtt", "vtt"), (".srt", "srt"), (".json", "podcast-json")):
            if lowered.endswith(extension):
                kind = guess
                break
    if kind is None:
        return None
    try:
        segments = parsers[kind](body) or None
    except Exception as error:  # noqa: BLE001 - a bad transcript is not a failed episode
        _worker_reporting.progress("transcript.published.unparseable", f"{kind}: {error}")
        return None
    if segments and kind in ("vtt", "srt"):
        # Only the timed-text formats carry cue markup.  A Podcasting 2.0 JSON
        # transcript's body is plain text, where "<" is a character somebody
        # typed and stripping it would delete their words.
        marked = sum(1 for segment in segments if "<" in segment.text or "&" in segment.text)
        segments = strip_cue_markup(segments) or None
        if marked:
            _worker_reporting.progress("transcript.published.markup-stripped", f"{kind}: {marked} cues")
    return segments

def published_transcript_matches_audio(segments, audio_path: Path) -> bool:
    """Return whether a published transcript's timing describes this audio.

    The measurement is emitted either way. A single accepted episode says
    nothing about where the threshold belongs, so every preparation records
    what it saw and the journal becomes the evidence a later adjustment needs.
    """
    try:
        audio_seconds = _worker_cue_timing.probe_duration(audio_path)
    except Exception as error:  # noqa: BLE001 - the guard checks the transcript, not the episode
        # A transcript that cannot be checked is still the best timing there
        # is. Failing the episode because ffprobe was unavailable would trade
        # a possible misalignment for a certain loss.
        _worker_reporting.progress("transcript.published.unverified", f"{type(error).__name__}: {error}")
        return True
    transcript_seconds = max((float(segment.end_s) for segment in segments), default=0.0)
    gap = audio_seconds - transcript_seconds
    tolerance = max(PUBLISHED_TRANSCRIPT_GAP_FLOOR_S, PUBLISHED_TRANSCRIPT_GAP_FRACTION * audio_seconds)
    detail = (f"audio {audio_seconds:.1f}s, transcript ends {transcript_seconds:.1f}s, "
              f"gap {gap:.1f}s, tolerance {tolerance:.1f}s")
    if gap > tolerance:
        _worker_reporting.progress("transcript.published.misaligned", detail)
        return False
    _worker_reporting.progress("transcript.published.aligned", detail)
    return True

def extract_prose(html: str) -> str | None:
    """Pull readable prose out of an episode page, or None if it is show notes.

    The result carries no timing and is never presented as if it did. The
    previous pipeline estimated timestamps here at 150 words per minute; that
    number is a guess about a page, not a measurement of audio, and it cannot
    drive a reading position or an audio cut.
    """
    import trafilatura

    try:
        text = trafilatura.extract(html)
    except Exception:  # noqa: BLE001
        return None
    if not text:
        return None
    return text if len(text.split()) >= MINIMUM_PROSE_WORDS else None

def _aligned_cache_directory(request: dict) -> Path | None:
    """Return this request's private aligned-STT cache directory, when keyed."""
    source_hash = request.get("sourceHash")
    model = request.get("alignedTranscriptModel")
    if not isinstance(source_hash, str) or not source_hash or not isinstance(model, str) or not model:
        return None
    return Path(request.get("workDir") or tempfile.gettempdir()) / "wilted-pipeline" / "aligned-stt-cache"

def _aligned_cache_path(cache_directory: Path, source_hash: str, model: str) -> Path:
    """Give one opaque, filesystem-safe path to a source hash/model pair."""
    digest = sha256(f"{ALIGNED_STT_CACHE_SCHEMA_VERSION}\0{source_hash}\0{model}".encode()).hexdigest()
    return cache_directory / f"{digest}.json"

def _discard_aligned_cache_entry(path: Path) -> None:
    """Best-effort cleanup for one cache artifact, including an interrupted directory."""
    try:
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)
    except OSError:
        pass

def _decode_cached_aligned_segments(payload: object, *, source_hash: str | None = None,
                                    model: str | None = None) -> list[CachedAlignedSegment]:
    """Validate a cache record and rebuild precisely the attributes ads needs."""
    if not isinstance(payload, dict) or payload.get("schemaVersion") != ALIGNED_STT_CACHE_SCHEMA_VERSION:
        raise ValueError("unsupported cache schema")
    if not isinstance(payload.get("sourceHash"), str) or not payload["sourceHash"]:
        raise ValueError("missing source hash")
    if not isinstance(payload.get("model"), str) or not payload["model"]:
        raise ValueError("missing model")
    if source_hash is not None and payload["sourceHash"] != source_hash:
        raise ValueError("source hash does not match cache key")
    if model is not None and payload["model"] != model:
        raise ValueError("model does not match cache key")
    raw_segments = payload.get("segments")
    if not isinstance(raw_segments, list):
        raise ValueError("missing segments")
    segments: list[CachedAlignedSegment] = []
    previous_start = -1.0
    for raw in raw_segments:
        if not isinstance(raw, dict) or not isinstance(raw.get("text"), str) or not raw["text"].strip():
            raise ValueError("invalid cached segment text")
        start, end = raw.get("start_s"), raw.get("end_s")
        if type(start) not in (int, float) or type(end) not in (int, float):
            raise ValueError("invalid cached segment timing")
        start, end = float(start), float(end)
        if not start >= 0 or not start < end or not start < float("inf") or not end < float("inf"):
            raise ValueError("invalid cached segment timing")
        if start < previous_start:
            raise ValueError("out-of-order cached segments")
        segments.append(CachedAlignedSegment(text=raw["text"], start_s=start, end_s=end))
        previous_start = start
    return segments

def _cache_record(segments, source_hash: str, model: str) -> dict:
    """Serialize only the stable detector contract, never parser/model internals."""
    record_segments = []
    for segment in segments:
        text = getattr(segment, "text", None)
        start, end = getattr(segment, "start_s", None), getattr(segment, "end_s", None)
        if not isinstance(text, str) or not text.strip() or type(start) not in (int, float) or type(end) not in (int, float):
            raise ValueError("invalid aligned STT segment")
        start, end = float(start), float(end)
        if not start >= 0 or not start < end or not start < float("inf") or not end < float("inf"):
            raise ValueError("invalid aligned STT segment")
        if record_segments and start < record_segments[-1]["start_s"]:
            raise ValueError("out-of-order aligned STT segments")
        record_segments.append({"text": text, "start_s": start, "end_s": end})
    return {
        "schemaVersion": ALIGNED_STT_CACHE_SCHEMA_VERSION,
        "sourceHash": source_hash,
        "model": model,
        "segments": record_segments,
    }

def _prune_aligned_stt_cache(cache_directory: Path) -> None:
    """Remove temporary/corrupt entries and retain the 32 most-recent valid ones."""
    try:
        entries = list(cache_directory.iterdir())
    except OSError:
        return
    valid: list[Path] = []
    for entry in entries:
        if not entry.is_file() or entry.suffix != ".json":
            _discard_aligned_cache_entry(entry)
            continue
        try:
            payload = json.loads(entry.read_text(encoding="utf-8"))
            _decode_cached_aligned_segments(payload)
            if entry != _aligned_cache_path(cache_directory, payload["sourceHash"], payload["model"]):
                raise ValueError("cache file does not match its key")
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            _discard_aligned_cache_entry(entry)
            continue
        valid.append(entry)
    valid.sort(key=lambda entry: entry.stat().st_mtime_ns, reverse=True)
    for entry in valid[ALIGNED_STT_CACHE_MAXIMUM_ENTRIES:]:
        _discard_aligned_cache_entry(entry)

def _load_cached_aligned_segments(request: dict, source_hash: str, model: str) -> list[CachedAlignedSegment] | None:
    """Load a matching cache entry, deleting it before a fresh STT retry if bad."""
    cache_directory = _aligned_cache_directory(request)
    if cache_directory is None:
        return None
    path = _aligned_cache_path(cache_directory, source_hash, model)
    try:
        segments = _decode_cached_aligned_segments(
            json.loads(path.read_text(encoding="utf-8")), source_hash=source_hash, model=model
        )
    except FileNotFoundError:
        return None
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        _discard_aligned_cache_entry(path)
        _prune_aligned_stt_cache(cache_directory)
        _worker_reporting.progress("transcript.stt.cache.invalid", "discarded malformed aligned transcript")
        return None
    try:
        os.utime(path, None)
    except OSError:
        _discard_aligned_cache_entry(path)
        _prune_aligned_stt_cache(cache_directory)
        _worker_reporting.progress("transcript.stt.cache.invalid", "could not refresh aligned transcript recency")
        return None
    _prune_aligned_stt_cache(cache_directory)
    _worker_reporting.progress("transcript.stt.cache.hit", f"{len(segments)} segments")
    return segments

def _store_cached_aligned_segments(request: dict, source_hash: str, model: str, segments) -> None:
    """Atomically persist a completed detector transcript before ad detection."""
    cache_directory = _aligned_cache_directory(request)
    if cache_directory is None:
        return
    temporary_path: Path | None = None
    try:
        record = _cache_record(segments, source_hash, model)
        cache_directory.mkdir(parents=True, exist_ok=True)
        destination = _aligned_cache_path(cache_directory, source_hash, model)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=cache_directory,
                                         prefix=".aligned-stt-", suffix=".tmp", delete=False) as temporary:
            json.dump(record, temporary, separators=(",", ":"), allow_nan=False)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        os.replace(temporary_path, destination)
        with contextlib.suppress(OSError):
            directory_fd = os.open(cache_directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        _prune_aligned_stt_cache(cache_directory)
        _worker_reporting.progress("transcript.stt.cache.saved", f"{len(record['segments'])} segments")
    except (OSError, ValueError, TypeError) as error:
        # A cache is an optimization. It must never turn a completed STT pass
        # into a failed episode, and an interrupted temporary is never retained.
        if temporary_path is not None:
            _discard_aligned_cache_entry(temporary_path)
        _prune_aligned_stt_cache(cache_directory)
        _worker_reporting.progress("transcript.stt.cache.failed", f"{type(error).__name__}: {error}")

def transcribe_with_daemon(audio_path: Path, model: str = ALIGNED_STT_MODEL):
    """Tier three: our own speech-to-text, aligned against this exact audio."""
    from wilted import transcribe

    _worker_reporting.progress("transcript.stt.start", str(audio_path.name))
    segments = in_time_order(transcribe.transcribe_audio(audio_path, model_name=model))
    _worker_reporting.progress("transcript.stt.complete", f"{len(segments)} segments")
    return segments
