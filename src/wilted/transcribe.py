"""Transcript ingestion — three-tier sourcing for podcast episodes.

Tier 1: RSS podcast:transcript tag (VTT, SRT, Podcasting 2.0 JSON)
Tier 2: Publisher website transcript via trafilatura
Tier 3: Local transcription via speech-stack's isolated GPU worker (parakeet)

Usage:
    from wilted.transcribe import get_transcript, TranscriptSegment
    segments = get_transcript(item_id=42, feed_xml=xml, guid="ep-1")
"""

from __future__ import annotations

import json
import logging
import os
import re
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path
from urllib.request import Request, urlopen

import trafilatura  # noqa: TCH002 — used at runtime in extract_transcript_from_url

try:
    # Bind ``isolated`` at module scope so tier-3 reaches speech-stack's isolated
    # GPU worker and tests can patch ``wilted.transcribe.isolated.run``. Guarded so a
    # missing speech-stack doesn't break the import-time surface of tiers 1/2 —
    # transcribe_audio re-checks and raises a clear TranscriptionError instead.
    from speech_stack import isolated
except ImportError:  # pragma: no cover — speech-stack is a hard dependency in practice
    isolated = None  # type: ignore[assignment]

try:
    # The resident speech daemon client, used only when WILTED_STT_BACKEND=daemon.
    # Same guard as ``isolated`` (both live in speech-stack); tests patch
    # ``wilted.transcribe.client.stt_path`` / ``client.evict``. The isolated spawn
    # path never touches this, so a missing daemon client can never affect the
    # default (frozen) behavior.
    from speech_stack import client
except ImportError:  # pragma: no cover — speech-stack is a hard dependency in practice
    client = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)


class TranscriptionError(RuntimeError):
    """Raised when all transcript sourcing tiers fail."""


class TranscriptionTimeout(TranscriptionError):
    """Tier-3 worker exceeded its wall-clock timeout (``isolated.Timeout``)."""


class TranscriptionAborted(TranscriptionError):
    """Tier-3 worker died via a hard GPU crash — SIGABRT (Metal fault) or SIGSEGV.

    Maps both ``isolated.GpuAborted`` and ``isolated.GpuSegfault``.
    """


class TranscriptionWorkerError(TranscriptionError):
    """Tier-3 worker raised a caught exception / produced no result (``isolated.WorkerError``)."""


@dataclass
class TranscriptSegment:
    """A segment of transcript with timestamps."""

    start_s: float
    end_s: float
    text: str


# ---------------------------------------------------------------------------
# Timestamp parsing helpers
# ---------------------------------------------------------------------------

_VTT_TS_RE = re.compile(r"(?:(\d+):)?(\d{2}):(\d{2})[.,](\d{3})")


def _parse_ts(ts: str) -> float:
    """Parse a VTT/SRT timestamp (HH:MM:SS.mmm or MM:SS.mmm) to seconds."""
    m = _VTT_TS_RE.match(ts.strip())
    if not m:
        raise ValueError(f"Invalid timestamp: {ts!r}")
    hours = int(m.group(1) or 0)
    minutes = int(m.group(2))
    seconds = int(m.group(3))
    millis = int(m.group(4))
    return hours * 3600 + minutes * 60 + seconds + millis / 1000


# ---------------------------------------------------------------------------
# Tier 1: Format parsers
# ---------------------------------------------------------------------------


def parse_vtt(content: str) -> list[TranscriptSegment]:
    """Parse WebVTT format into transcript segments.

    Args:
        content: Raw WebVTT file content.

    Returns:
        List of TranscriptSegment with start/end times and text.
    """
    segments: list[TranscriptSegment] = []
    lines = content.splitlines()
    i = 0

    # Skip WEBVTT header and any metadata
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith("WEBVTT"):
            i += 1
            continue
        if line == "" or line.startswith("NOTE"):
            i += 1
            # Skip multi-line NOTE blocks
            if line.startswith("NOTE"):
                while i < len(lines) and lines[i].strip() != "":
                    i += 1
            continue
        break

    while i < len(lines):
        line = lines[i].strip()

        # Skip blank lines and NOTE blocks
        if line == "":
            i += 1
            continue
        if line.startswith("NOTE"):
            i += 1
            while i < len(lines) and lines[i].strip() != "":
                i += 1
            continue

        # Check if this line is a timestamp line (contains -->)
        if "-->" in line:
            ts_line = line
        else:
            # Could be a cue identifier; check next line for timestamp
            i += 1
            if i < len(lines) and "-->" in lines[i]:
                ts_line = lines[i].strip()
            else:
                continue

        parts = ts_line.split("-->")
        if len(parts) != 2:
            i += 1
            continue

        start = _parse_ts(parts[0].strip())
        # End timestamp may have position/alignment metadata after it
        end_raw = parts[1].strip().split()[0]
        end = _parse_ts(end_raw)

        # Collect cue text (all lines until blank or next cue)
        i += 1
        text_lines: list[str] = []
        while i < len(lines) and lines[i].strip() != "":
            text_lines.append(lines[i].strip())
            i += 1

        text = " ".join(text_lines)
        if text:
            segments.append(TranscriptSegment(start_s=start, end_s=end, text=text))

    return segments


def parse_srt(content: str) -> list[TranscriptSegment]:
    """Parse SubRip (SRT) format into transcript segments.

    Args:
        content: Raw SRT file content.

    Returns:
        List of TranscriptSegment with start/end times and text.
    """
    segments: list[TranscriptSegment] = []
    blocks = re.split(r"\n\s*\n", content.strip())

    for block in blocks:
        lines = block.strip().splitlines()
        if len(lines) < 2:
            continue

        # Find the timestamp line (contains -->)
        ts_idx = None
        for idx, line in enumerate(lines):
            if "-->" in line:
                ts_idx = idx
                break

        if ts_idx is None:
            continue

        ts_line = lines[ts_idx]
        parts = ts_line.split("-->")
        if len(parts) != 2:
            continue

        start = _parse_ts(parts[0].strip())
        end = _parse_ts(parts[1].strip())

        text_lines = lines[ts_idx + 1 :]
        text = " ".join(line.strip() for line in text_lines if line.strip())
        if text:
            segments.append(TranscriptSegment(start_s=start, end_s=end, text=text))

    return segments


def parse_podcast_json(content: str) -> list[TranscriptSegment]:
    """Parse Podcasting 2.0 JSON transcript format.

    Supports both the segments-wrapper format:
        {"segments": [{"startTime": ..., "endTime": ..., "body": ...}]}
    and the flat array format:
        [{"startTime": ..., "endTime": ..., "body": ...}]

    Args:
        content: Raw JSON string.

    Returns:
        List of TranscriptSegment.
    """
    data = json.loads(content)

    if isinstance(data, dict):
        items = data.get("segments", [])
    elif isinstance(data, list):
        items = data
    else:
        return []

    segments: list[TranscriptSegment] = []
    for item in items:
        start = float(item.get("startTime", 0))
        end = float(item.get("endTime", 0))
        body = str(item.get("body", "")).strip()
        if body:
            segments.append(TranscriptSegment(start_s=start, end_s=end, text=body))

    return segments


# ---------------------------------------------------------------------------
# Tier 1: RSS podcast:transcript tag
# ---------------------------------------------------------------------------

_PODCAST_NS = "https://podcastindex.org/namespace/1.0"

# Map MIME types and extensions to parser functions
_FORMAT_PARSERS = {
    "text/vtt": parse_vtt,
    "application/x-subrip": parse_srt,
    "text/srt": parse_srt,
    "application/json": parse_podcast_json,
}

_EXT_PARSERS = {
    ".vtt": parse_vtt,
    ".srt": parse_srt,
    ".json": parse_podcast_json,
}


def fetch_transcript_from_rss(feed_xml: str, guid: str) -> list[TranscriptSegment] | None:
    """Fetch a transcript URL from the RSS podcast:transcript tag.

    Parses the feed XML, finds the item matching the given GUID, and fetches
    the transcript if a podcast:transcript tag is present.

    Args:
        feed_xml: Raw RSS/Atom feed XML string.
        guid: The GUID of the episode to find.

    Returns:
        List of TranscriptSegment if found and parseable, None otherwise.
    """
    try:
        root = ET.fromstring(feed_xml)
    except ET.ParseError:
        logger.warning("Failed to parse feed XML for transcript lookup")
        return None

    # Search for items across RSS <item> and Atom <entry>
    ns = {"podcast": _PODCAST_NS}
    items = root.findall(".//item") + root.findall(".//{http://www.w3.org/2005/Atom}entry")

    for item in items:
        # Check GUID (RSS) or id (Atom)
        guid_el = item.find("guid")
        if guid_el is None:
            guid_el = item.find("{http://www.w3.org/2005/Atom}id")
        if guid_el is None or (guid_el.text or "").strip() != guid:
            continue

        # Found the matching item — look for podcast:transcript
        transcript_el = item.find("podcast:transcript", ns)
        if transcript_el is None:
            logger.debug("Item %s has no podcast:transcript tag", guid)
            return None

        url = transcript_el.get("url")
        if not url:
            return None

        content_type = (transcript_el.get("type") or "").strip().lower()

        # Determine parser
        parser = _FORMAT_PARSERS.get(content_type)
        if parser is None:
            # Fallback: detect from URL extension
            for ext, p in _EXT_PARSERS.items():
                if url.lower().endswith(ext):
                    parser = p
                    break

        if parser is None:
            logger.warning("Unknown transcript format type=%r url=%s", content_type, url)
            return None

        # Fetch the transcript
        try:
            import wilted

            req = Request(url, headers={"User-Agent": f"Wilted/{wilted.__version__}"})
            with urlopen(req, timeout=30) as resp:  # noqa: S310
                body = resp.read().decode("utf-8", errors="replace")
        except Exception:
            logger.warning("Failed to fetch transcript from %s", url, exc_info=True)
            return None

        segments = parser(body)
        if segments:
            logger.info("Fetched %d transcript segments from RSS for %s", len(segments), guid)
            return segments

        return None

    logger.debug("GUID %s not found in feed XML", guid)
    return None


# ---------------------------------------------------------------------------
# Tier 2: Publisher website transcript
# ---------------------------------------------------------------------------

_WPM_ESTIMATE = 150


def extract_transcript_from_url(url: str, min_words: int = 500) -> list[TranscriptSegment] | None:
    """Extract a transcript from the episode's web page.

    Uses trafilatura to fetch and extract main content. If the extracted text
    has enough words (>= min_words), it is treated as a transcript and split
    into paragraph-based segments with synthetic timestamps estimated at
    ~150 WPM.

    Args:
        url: The episode web page URL.
        min_words: Minimum word count to accept as transcript (not show notes).

    Returns:
        List of TranscriptSegment with synthetic timestamps, or None.
    """
    try:
        html = trafilatura.fetch_url(url)
        if not html:
            return None

        text = trafilatura.extract(html)
        if not text:
            return None
    except Exception:
        logger.warning("Failed to extract text from %s", url, exc_info=True)
        return None

    words = text.split()
    if len(words) < min_words:
        logger.debug(
            "Page text too short (%d words < %d min) — likely show notes",
            len(words),
            min_words,
        )
        return None

    # Split into paragraphs and assign synthetic timestamps
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    if not paragraphs:
        paragraphs = [text]

    segments: list[TranscriptSegment] = []
    current_time = 0.0

    for para in paragraphs:
        word_count = len(para.split())
        duration = (word_count / _WPM_ESTIMATE) * 60  # seconds
        if duration < 0.1:
            duration = 0.1  # minimum segment duration
        segments.append(
            TranscriptSegment(
                start_s=round(current_time, 3),
                end_s=round(current_time + duration, 3),
                text=para,
            )
        )
        current_time += duration

    logger.info("Extracted %d segments from web page %s", len(segments), url)
    return segments


# ---------------------------------------------------------------------------
# Tier 3: Local transcription via speech-stack's isolated GPU worker
# ---------------------------------------------------------------------------


# Wall-clock ceiling for one isolated transcription run. Matches speech-stt's
# default (1800s); env-overridable via WILTED_TRANSCRIBE_TIMEOUT_S.
_TRANSCRIBE_TIMEOUT_S = 1800.0

# ---------------------------------------------------------------------------
# Tier-3 STT backend selection (additive, behind WILTED_STT_BACKEND)
# ---------------------------------------------------------------------------
#
# Default preserves today's isolated spawn-per-call behavior byte-for-byte;
# ``WILTED_STT_BACKEND=daemon`` routes tier-3 STT through the resident speech-stack
# daemon (``speech_stack.client``) with an automatic isolated-spawn fallback when no
# broker is listening. Rollback is a single env unset — the daemon route is purely
# additive and the isolated path is never modified.
_STT_BACKEND_ENV = "WILTED_STT_BACKEND"

# Log the chosen backend exactly once per process, at first tier-3 use (CR-5
# visibility). Module-level so the line is emitted once regardless of how many
# episodes a run transcribes; tests reset it to re-observe the log.
_stt_backend_logged = False


def _stt_backend() -> str:
    """Return the selected tier-3 STT backend: ``'daemon'`` or ``'isolated'``.

    Defaults to ``'isolated'`` (today's spawn-per-call path) for any unset or
    unrecognized value, so the daemon route is strictly opt-in.
    """
    raw = (os.environ.get(_STT_BACKEND_ENV) or "").strip().lower()
    return "daemon" if raw == "daemon" else "isolated"


def _log_stt_backend_once(backend: str) -> None:
    """Emit the chosen tier-3 STT backend once per process (CR-5 startup line)."""
    global _stt_backend_logged
    if not _stt_backend_logged:
        _stt_backend_logged = True
        logger.info("Tier-3 STT backend: %s", backend)


def _run_stt_via_daemon(request: dict, timeout: float) -> dict:
    """Transcribe ``request`` via the resident speech daemon (WILTED_STT_BACKEND=daemon).

    Routes the SAME request params through ``speech_stack.client.stt_path``; the
    daemon's result dict is byte-identical to ``isolated.run("stt", ...)`` (Phase 2
    parity), so :func:`transcribe_audio`'s segment construction is unchanged.

    Falls back to the isolated spawn path ONLY on ``client.DaemonUnavailable`` (no
    broker listening — a rolled-back/not-yet-started daemon). Every OTHER typed error
    (``Timeout`` / ``GpuAborted`` / ``GpuSegfault`` / ``WorkerError`` — all the SAME
    classes ``speech_stack.client`` re-exports from ``isolated``) is a real per-item
    failure: it propagates unchanged to :func:`transcribe_audio`'s existing ``except``
    ladder and surfaces as the matching ``TranscriptionError`` subclass. A genuine GPU
    crash is therefore NEVER masked by a silent spawn retry (INV-6).
    """
    if client is None:  # speech-stack present but the daemon client failed to import
        return isolated.run("stt", request, timeout=timeout)
    # Everything except the positional audio_path rides as **params, exactly mirroring
    # the dict isolated.run forwards to stt.transcribe (model binds to stt_path's
    # keyword; the rest — chunk/overlap/sentence_split/budget/decoding/… — pass
    # through). Extra keys the model ignores are swallowed by stt.transcribe(**_).
    params = {k: v for k, v in request.items() if k != "audio_path"}
    try:
        return client.stt_path(request["audio_path"], timeout=timeout, **params)
    except client.DaemonUnavailable:
        logger.info(
            "speech daemon unavailable; falling back to isolated spawn for STT of %s",
            request.get("audio_path"),
        )
        return isolated.run("stt", request, timeout=timeout)


def evict_stt_model() -> None:
    """Hint the speech daemon to drop the resident STT model (PM-5/INV-2 hygiene).

    Called after a batch of tier-3 transcriptions completes and BEFORE a different
    model (the LLM) loads, so parakeet is not left co-resident in the daemon while
    wilted loads the LLM in its own process. Only meaningful on the daemon backend;
    a no-op on the isolated backend (the spawn child already exited after each call)
    and a no-op if the daemon client is unavailable. Best-effort: if the daemon is
    already gone there is nothing resident to drop, so ``DaemonUnavailable`` is
    swallowed rather than surfaced.
    """
    if _stt_backend() != "daemon" or client is None:
        return
    try:
        client.evict("stt")
    except client.DaemonUnavailable:
        logger.debug("speech daemon already gone at evict-hint time; nothing to evict")


def _env_float(name: str, default: float) -> float:
    """Return env ``name`` parsed as a positive float, else ``default`` (never crashes)."""
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError):
        logger.warning("Ignoring invalid %s=%r; using default %g", name, raw, default)
        return default
    if value <= 0:
        logger.warning("Ignoring non-positive %s=%r; using default %g", name, raw, default)
        return default
    return value


def _env_int_or_none(name: str) -> int | None:
    """Return env ``name`` parsed as a positive int, else None (never crashes)."""
    raw = os.environ.get(name)
    if not raw:
        return None
    try:
        value = int(raw)
    except (TypeError, ValueError):
        logger.warning("Ignoring invalid %s=%r; leaving memory cap unset", name, raw)
        return None
    if value <= 0:
        logger.warning("Ignoring non-positive %s=%r; leaving memory cap unset", name, raw)
        return None
    return value


def transcribe_audio(
    audio_path: str | Path,
    model_name: str = "mlx-community/parakeet-tdt-1.1b",
    chunk_duration: float = 120.0,
    overlap_duration: float = 15.0,
) -> list[TranscriptSegment]:
    """Transcribe an audio file via speech-stack's isolated parakeet worker.

    This is the fallback tier when no external transcript is available. Rather
    than importing parakeet in-process, it dispatches to
    ``speech_stack.isolated.run("stt", ...)``, which runs the model in a child
    process behind an exclusive GPU lock. A Metal fault (SIGABRT) or segfault in
    the model therefore kills only that child — this process survives and gets a
    typed error instead of dying.

    Backend (additive, opt-in): ``WILTED_STT_BACKEND=daemon`` instead routes the
    request through the resident speech-stack daemon
    (``speech_stack.client.stt_path``), which reuses a warm parakeet model and
    returns a byte-identical result dict. It falls back to the isolated spawn path
    when no broker is listening (``DaemonUnavailable``); every other typed failure
    surfaces identically to the isolated path. Any other value (or unset) keeps the
    isolated spawn-per-call behavior, so rollback is a single env unset.

    Transcription is chunked: passing a bounded ``chunk_duration`` makes parakeet
    stream fixed GPU windows with ``overlap_duration`` context between them,
    keeping GPU memory bounded regardless of episode length (the primary BUG-4
    crash mitigation, enforced inside ``speech_stack.stt``). Sentence-level
    splitting (``sentence_split=True``) reproduces wilted's former in-process
    segmentation.

    Timeout defaults to ``_TRANSCRIBE_TIMEOUT_S`` (1800s), overridable via
    ``WILTED_TRANSCRIBE_TIMEOUT_S``. An optional GPU memory cap can be set via
    ``WILTED_TRANSCRIBE_MEM_LIMIT`` (int bytes); default None, since chunking is
    the primary crash mitigation.

    Args:
        audio_path: Path to the audio file (mp3, m4a, etc.). Accepts ``str`` or
            ``Path``; the CLI and podcast pipeline pass either, so it is coerced
            to ``Path`` on entry.
        model_name: HuggingFace model name for parakeet.
        chunk_duration: Seconds of audio decoded per GPU chunk (default 120s).
        overlap_duration: Seconds of overlap between adjacent chunks (default 15s).

    Returns:
        List of TranscriptSegment from model output.

    Raises:
        TranscriptionTimeout: The worker exceeded its wall-clock timeout.
        TranscriptionAborted: The worker died via a hard GPU crash (SIGABRT/SIGSEGV).
        TranscriptionWorkerError: The worker raised a caught exception / no result.
        TranscriptionError: speech-stack is unavailable, another isolation error
            occurred, or transcription produced no segments.
    """
    if isolated is None:
        raise TranscriptionError("speech-stack is not installed. Install it as an editable dependency of wilted.")

    # Accept str or Path from any caller (CLI, podcast pipeline, tests). Coerce
    # once so the request payload and the completion log agree on the type.
    audio_path = Path(audio_path)

    timeout = _env_float("WILTED_TRANSCRIBE_TIMEOUT_S", _TRANSCRIBE_TIMEOUT_S)
    memory_limit_bytes = _env_int_or_none("WILTED_TRANSCRIBE_MEM_LIMIT")

    request = {
        "audio_path": str(audio_path),
        "model": model_name,
        "chunk_duration": chunk_duration,
        "overlap_duration": overlap_duration,
        "sentence_split": True,
        "budget_bytes": None,
        "memory_limit_bytes": memory_limit_bytes,
        "decoding": "greedy",
        "beam_size": 5,
        "debug": False,
    }

    # Backend selection (additive). Default is the isolated spawn-per-call path,
    # byte-for-byte unchanged; WILTED_STT_BACKEND=daemon routes through the resident
    # daemon (with an isolated fallback on DaemonUnavailable). The typed-error mapping
    # below is IDENTICAL for both: speech_stack.client re-exports the isolated error
    # classes, so a real GPU crash surfaces the same TranscriptionError subclass
    # whichever backend produced it (INV-6).
    backend = _stt_backend()
    _log_stt_backend_once(backend)

    try:
        if backend == "daemon":
            result = _run_stt_via_daemon(request, timeout)
        else:
            result = isolated.run("stt", request, timeout=timeout)
    except isolated.Timeout as e:
        raise TranscriptionTimeout(f"Transcription timed out: {e}") from e
    except (isolated.GpuAborted, isolated.GpuSegfault) as e:
        raise TranscriptionAborted(f"Transcription crashed on GPU: {e}") from e
    except isolated.WorkerError as e:
        raise TranscriptionWorkerError(f"Transcription worker failed: {e}") from e
    except isolated.IsolatedError as e:
        raise TranscriptionError(f"Transcription failed: {e}") from e

    # speech_stack.stt already returns sentence-split, text-stripped segments as
    # list[{"start_s", "end_s", "text"}] with empties dropped.
    segments = [
        TranscriptSegment(
            start_s=float(seg["start_s"]),
            end_s=float(seg["end_s"]),
            text=str(seg["text"]),
        )
        for seg in result.get("segments", [])
    ]

    if not segments:
        raise TranscriptionError("Transcription produced no segments")

    logger.info("Transcribed %d segments from %s", len(segments), audio_path.name)
    return segments


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------


def get_transcript(
    item_id: int,
    guid: str | None = None,
    feed_xml: str | None = None,
    episode_url: str | None = None,
    audio_path: Path | None = None,
) -> list[TranscriptSegment]:
    """Get a transcript using the three-tier sourcing strategy.

    Tries tiers in order:
      1. RSS podcast:transcript tag
      2. Publisher website transcript
      3. Local transcription model

    Args:
        item_id: Database item ID (for logging).
        guid: Episode GUID for RSS transcript lookup.
        feed_xml: Raw RSS feed XML string.
        episode_url: Episode web page URL for Tier 2.
        audio_path: Path to audio file for Tier 3 fallback.

    Returns:
        List of TranscriptSegment from the first successful tier.

    Raises:
        TranscriptionError: If all tiers fail.
    """
    errors: list[str] = []

    # Tier 1: RSS transcript tag
    if feed_xml and guid:
        try:
            segments = fetch_transcript_from_rss(feed_xml, guid)
            if segments:
                logger.info("Item %d: transcript from RSS (Tier 1)", item_id)
                return segments
            errors.append("RSS: no transcript tag or fetch failed")
        except Exception as e:
            errors.append(f"RSS: {e}")
            logger.debug("Tier 1 failed for item %d: %s", item_id, e)

    # Tier 2: Publisher website
    if episode_url:
        try:
            segments = extract_transcript_from_url(episode_url)
            if segments:
                logger.info("Item %d: transcript from web page (Tier 2)", item_id)
                return segments
            errors.append("Web: text too short or extraction failed")
        except Exception as e:
            errors.append(f"Web: {e}")
            logger.debug("Tier 2 failed for item %d: %s", item_id, e)

    # Tier 3: Local transcription
    if audio_path:
        try:
            segments = transcribe_audio(audio_path)
            logger.info("Item %d: transcript from local model (Tier 3)", item_id)
            return segments
        except TranscriptionError:
            raise
        except Exception as e:
            errors.append(f"Local: {e}")
            logger.debug("Tier 3 failed for item %d: %s", item_id, e)

    raise TranscriptionError(f"All transcript tiers failed for item {item_id}: {'; '.join(errors)}")


# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------


def save_transcript(segments: list[TranscriptSegment], path: Path) -> None:
    """Save transcript segments to a JSON file for caching.

    Args:
        segments: List of TranscriptSegment to persist.
        path: File path to write the JSON cache.
    """
    data = [asdict(seg) for seg in segments]
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    logger.debug("Saved %d transcript segments to %s", len(segments), path)


def load_transcript(path: Path) -> list[TranscriptSegment] | None:
    """Load cached transcript segments from a JSON file.

    Args:
        path: File path to read.

    Returns:
        List of TranscriptSegment if file exists and is valid, None otherwise.
    """
    if not path.exists():
        return None

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return [
            TranscriptSegment(
                start_s=float(item["start_s"]),
                end_s=float(item["end_s"]),
                text=str(item["text"]),
            )
            for item in data
        ]
    except (json.JSONDecodeError, KeyError, TypeError, ValueError):
        logger.warning("Failed to load transcript cache from %s", path)
        return None


def segments_to_text(segments: list[TranscriptSegment]) -> str:
    """Join all segment text into a single plain-text string.

    Args:
        segments: List of TranscriptSegment.

    Returns:
        Concatenated text with segments separated by spaces.
    """
    return " ".join(seg.text for seg in segments)
