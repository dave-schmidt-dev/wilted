"""Transcript ingestion — three-tier sourcing for podcast episodes.

Tier 1: RSS podcast:transcript tag (VTT, SRT, Podcasting 2.0 JSON)
Tier 2: Publisher website transcript via trafilatura
Tier 3: Local transcription model (parakeet_mlx) fallback

Usage:
    from wilted.transcribe import get_transcript, TranscriptSegment
    segments = get_transcript(item_id=42, feed_xml=xml, guid="ep-1")
"""

from __future__ import annotations

import json
import logging
import re
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from typing import TYPE_CHECKING
from urllib.request import Request, urlopen

import trafilatura  # noqa: TCH002 — used at runtime in extract_transcript_from_url

if TYPE_CHECKING:
    from pathlib import Path

logger = logging.getLogger(__name__)


class TranscriptionError(RuntimeError):
    """Raised when all transcript sourcing tiers fail."""


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
            req = Request(url, headers={"User-Agent": "Wilted/0.3"})
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
# Tier 3: Local transcription model
# ---------------------------------------------------------------------------


def transcribe_audio(
    audio_path: Path,
    model_name: str = "mlx-community/parakeet-tdt-1.1b",
) -> list[TranscriptSegment]:
    """Transcribe an audio file using the local parakeet_mlx model.

    This is the fallback tier when no external transcript is available.

    Args:
        audio_path: Path to the audio file (mp3, m4a, etc.).
        model_name: HuggingFace model name for parakeet_mlx.

    Returns:
        List of TranscriptSegment from model output.

    Raises:
        TranscriptionError: If parakeet_mlx is not installed or transcription
            fails.
    """
    try:
        import parakeet_mlx  # type: ignore[import-untyped]
    except ImportError as e:
        raise TranscriptionError("parakeet_mlx is not installed. Install it with: pip install parakeet-mlx") from e

    try:
        model = parakeet_mlx.from_pretrained(model_name)
        result = model.transcribe(str(audio_path))
    except Exception as e:
        raise TranscriptionError(f"Transcription failed: {e}") from e
    finally:
        # Attempt to free model memory
        try:
            del model
        except NameError:
            pass

    segments: list[TranscriptSegment] = []
    # parakeet_mlx returns a result with .segments or similar
    raw_segments = getattr(result, "segments", None)
    if raw_segments is None and isinstance(result, dict):
        raw_segments = result.get("segments", [])
    if raw_segments is None:
        raw_segments = []

    for seg in raw_segments:
        if isinstance(seg, dict):
            start = float(seg.get("start", 0))
            end = float(seg.get("end", 0))
            text = str(seg.get("text", "")).strip()
        else:
            start = float(getattr(seg, "start", 0))
            end = float(getattr(seg, "end", 0))
            text = str(getattr(seg, "text", "")).strip()

        if text:
            segments.append(TranscriptSegment(start_s=start, end_s=end, text=text))

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
