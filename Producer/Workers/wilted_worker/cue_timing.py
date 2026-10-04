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
from . import reporting as _worker_reporting
from .constants import ALIGNED_TIMING_TAIL_ALLOWANCE_S, NOMINATED_SECONDS_FLOOR, NOMINATED_SHARE_FLOOR, RENDER_DURATION_TOLERANCE_S, RENDER_PROGRESS_INTERVAL_S, RENDER_TIMEOUT_S
from .reporting import WorkerError

@dataclass(frozen=True)
class KeepInterval:
    """One span of the original audio that survives the cut."""

    start_s: float
    end_s: float
    output_start_s: float

    @property
    def duration_s(self) -> float:
        return self.end_s - self.start_s

@dataclass(frozen=True)
class CachedAlignedSegment:
    """The detector-compatible shape reconstructed from an aligned STT cache."""

    text: str
    start_s: float
    end_s: float

def build_keep_map(keep_segments: list[tuple[float, float]]) -> list[KeepInterval]:
    """Turn ffmpeg's keep spans into a map from original time to output time."""
    intervals: list[KeepInterval] = []
    output = 0.0
    for start, end in keep_segments:
        if end <= start:
            continue
        intervals.append(KeepInterval(start_s=start, end_s=end, output_start_s=output))
        output += end - start
    return intervals

def serialize_keep_map(keeps: list[KeepInterval]) -> list[dict]:
    """Round one self-consistent original-to-output map for the Swift contract."""
    serialized: list[dict] = []
    output = 0.0
    for keep in keeps:
        start, end = round(keep.start_s, 3), round(keep.end_s, 3)
        serialized.append({
            "startSeconds": start,
            "endSeconds": end,
            "outputStartSeconds": round(output, 3),
        })
        output += end - start
    return serialized

def effective_removed_intervals(keeps: list[KeepInterval], total_seconds: float) -> list[tuple[float, float]]:
    """Return the exact complement of the rendered keep map."""
    removed: list[tuple[float, float]] = []
    cursor = 0.0
    for keep in keeps:
        if keep.start_s > cursor:
            removed.append((cursor, keep.start_s))
        cursor = keep.end_s
    if cursor < total_seconds:
        removed.append((cursor, total_seconds))
    return removed

def build_effective_cut_map(detections, total_seconds: float) -> tuple[list[tuple[float, float]], list[KeepInterval]]:
    """Validate and union the exact nominated cuts, then return their complement.

    The archive helper pads every nomination by half a second on each side and
    then merges across whatever is left between two of them, so a short
    programme interstitial that both neighbours were correctly nominated
    *around* disappears with them. A v2 render owns its whole map instead:
    overlapping nominations are unioned, every positive programme gap survives
    at its true length, and the only slack allowed is the small tail overrun an
    aligned transcript legitimately reports past the encoder's last frame.
    """
    if not (total_seconds > 0 and total_seconds < float("inf")):
        raise WorkerError("cut-unsafe", "source duration is not finite and positive")
    cuts: list[tuple[float, float]] = []
    for ad in detections:
        try:
            start, end = float(ad.start_s), float(ad.end_s)
        except (AttributeError, TypeError, ValueError) as error:
            raise WorkerError("cut-unsafe", "ad analysis returned malformed timing") from error
        if not (start >= 0 and start < end and start < float("inf") and end < float("inf")):
            raise WorkerError("cut-unsafe", "ad analysis returned non-finite or invalid timing")
        if start >= total_seconds or end > total_seconds + ALIGNED_TIMING_TAIL_ALLOWANCE_S:
            raise WorkerError("cut-unsafe", "ad analysis returned timing outside the source audio")
        cuts.append((start, min(end, total_seconds)))
    cuts.sort()
    merged: list[tuple[float, float]] = []
    for start, end in cuts:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    keeps: list[tuple[float, float]] = []
    cursor = 0.0
    for start, end in merged:
        if start > cursor:
            keeps.append((cursor, start))
        cursor = max(cursor, end)
    if cursor < total_seconds:
        keeps.append((cursor, total_seconds))
    return merged, build_keep_map(keeps)

def serialize_ad_audit(audit) -> dict:
    """Publish the detector evidence a caller needs in order to trust a result.

    Without it, "the detector examined every window and found no
    advertisements" and "the detector never reached the model" serialise to the
    same JSON. The request counts and unresolved identifiers below are what
    tell those two apart, so they travel with every completed analysis.
    """
    return {
        "classifierRequests": int(audit.classifier_requests),
        "classifierValidRequests": int(audit.classifier_valid_requests),
        "classifierInvalidRequests": int(audit.classifier_invalid_requests),
        "exhaustedSingletonLineages": int(audit.exhausted_singleton_lineages),
        "modelRequests": int(audit.model_requests),
        "modelFailures": int(audit.model_failures),
        "experimentalRequests": int(audit.experimental_requests),
        "unresolvedIds": [int(value) for value in audit.unresolved_ids],
        "candidates": [
            {"kind": candidate.kind,
             "ids": [int(value) for value in candidate.ids],
             "detail": candidate.detail}
            for candidate in audit.candidates
        ],
        "declinedCommercialEvidenceSeeds": [
            {
                "status": "declined",
                "reason": seed.reason,
                "ids": [int(value) for value in seed.ids],
                "startSeconds": float(seed.start_s),
                "endSeconds": float(seed.end_s),
            }
            for seed in audit.declined_commercial_evidence_seeds
        ],
        "incompleteError": audit.incomplete_error,
        "nearEmpty": audit.near_empty,
    }

def _near_empty_nominations(detections, total_seconds) -> str | None:
    """Name a run whose nominations are too small to trust, or ``None``.

    An empty nomination set is not near-empty: that is the shape of a
    genuinely ad-free episode, and the audit's request and failure counts are
    what separate a clean empty run from a backend that never answered. What
    this catches is a run that returned *something*, but so little that it is
    equally likely to be a broken backend's trace. The thresholds are the
    floors above; this is diagnostic only and never changes a cut.
    """
    if not detections or not 0 < float(total_seconds) < float("inf"):
        return None
    nominated_seconds = sum(float(ad.end_s) - float(ad.start_s) for ad in detections)
    nominated_share = nominated_seconds / float(total_seconds)
    if nominated_seconds < NOMINATED_SECONDS_FLOOR and nominated_share < NOMINATED_SHARE_FLOOR:
        return (
            f"nominations total {nominated_seconds:.1f}s "
            f"({nominated_share:.2%} of the episode), under both the "
            f"{NOMINATED_SECONDS_FLOOR:.0f}s and {NOMINATED_SHARE_FLOOR:.1%} floors"
        )
    return None

def validate_aligned_segments(segments, total_seconds: float) -> list:
    """Fail closed when detector timing is not finite and audio-aligned."""
    if not isinstance(total_seconds, (int, float)) or not float(total_seconds) > 0 or not float(total_seconds) < float("inf"):
        raise WorkerError("aligned-timing-invalid", "audio duration is not finite and positive")
    if not segments:
        raise WorkerError("aligned-timing-unavailable", "aligned speech-to-text returned no timed segments")
    # Deliberately not sorted. Sorting here would make the ordering check
    # below vacuous, and the live path already hands over time-ordered
    # segments; a cache that does not is corrupt, and quietly repairing it
    # would aim real cuts using timing nothing has vouched for.
    ordered = list(segments)
    previous_start = -1.0
    for segment in ordered:
        try:
            start, end = float(segment.start_s), float(segment.end_s)
        except (AttributeError, TypeError, ValueError) as error:
            raise WorkerError("aligned-timing-invalid", "aligned speech-to-text has malformed timestamps") from error
        if not (start >= 0 and start < end and start < float("inf") and end < float("inf")):
            raise WorkerError("aligned-timing-invalid", "aligned speech-to-text has non-finite or unordered timestamps")
        if (start < previous_start or start >= total_seconds
                or end > total_seconds + ALIGNED_TIMING_TAIL_ALLOWANCE_S):
            raise WorkerError("aligned-timing-invalid", "aligned speech-to-text does not fit the downloaded audio")
        previous_start = start
    return ordered

def _render_codec_arguments(output_path: Path) -> list[str]:
    """Choose a compatible audio codec for the original MP3 or M4A/AAC container."""
    suffix = output_path.suffix.lower()
    if suffix == ".mp3":
        return ["-c:a", "libmp3lame"]
    if suffix in {".m4a", ".aac"}:
        return ["-c:a", "aac"] + (["-movflags", "+faststart"] if suffix == ".m4a" else [])
    raise WorkerError("cut-container-unsupported", f"accurate ad removal does not support {suffix or 'this audio container'}")

def _terminate_render(process) -> None:
    """Never leave an ffmpeg child running after its wait has ended."""
    if process.poll() is not None:
        return
    for stop in (process.terminate, process.kill):
        try:
            stop()
            process.wait(timeout=2)
            return
        except (subprocess.TimeoutExpired, OSError):
            continue

def _run_render_with_progress(command: list[str], *, timeout_s: float) -> None:
    """Wait for ffmpeg with a heartbeat and a bound instead of in silence.

    A full episode re-encodes for minutes while the caller holds the shared
    admission slot. `subprocess.run` reports none of that and would wait on a
    wedged encoder indefinitely, so the wait is polled, reported every second,
    and cut off once it exceeds its limit.
    """
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    started = time.monotonic()
    stderr = ""
    try:
        while True:
            remaining = timeout_s - (time.monotonic() - started)
            if remaining <= 0:
                raise WorkerError("cut-render-timeout", f"ffmpeg exceeded its {timeout_s:.0f}s limit")
            try:
                _, stderr = process.communicate(timeout=min(RENDER_PROGRESS_INTERVAL_S, remaining))
            except subprocess.TimeoutExpired:
                _worker_reporting.progress("ads.cut.render.progress", f"ffmpeg running for {time.monotonic() - started:.0f}s")
                continue
            break
    except BaseException:
        _terminate_render(process)
        raise
    if process.returncode != 0:
        raise WorkerError("cut-render-failed", f"ffmpeg exited {process.returncode}: {(stderr or '').strip()[-2048:]}")

def render_keep_segments(audio_path: Path, output_path: Path, keeps: list[KeepInterval], *,
                         timeout_s: float = RENDER_TIMEOUT_S) -> None:
    """Accurately re-encode every keep interval into an atomic replacement."""
    if audio_path.resolve() == output_path.resolve():
        raise WorkerError("cut-output-alias", "prepared output must not replace its input in place")
    if not keeps:
        raise WorkerError("cut-unsafe", "no meaningful programme audio remains after ad detection")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(f".{output_path.stem}.rendering-{os.getpid()}{output_path.suffix}")
    temporary.unlink(missing_ok=True)
    filters = []
    labels = []
    for index, keep in enumerate(keeps):
        if not (keep.start_s >= 0 and keep.end_s > keep.start_s):
            raise WorkerError("cut-unsafe", "render map contains an empty or invalid keep interval")
        label = f"k{index}"
        filters.append(f"[0:a]atrim=start={keep.start_s:.6f}:end={keep.end_s:.6f},asetpts=PTS-STARTPTS[{label}]")
        labels.append(f"[{label}]")
    filters.append("".join(labels) + f"concat=n={len(labels)}:v=0:a=1[outc]")
    # libmp3lame's FLTP path rejects any frame with
    # linesize < 4 * FFALIGN(nb_samples, 8); concat's output frames routinely
    # fail that check at non-frame-aligned trim points, so resample once more
    # to force fully-padded frames before the encoder ever sees them.
    filters.append("[outc]aresample[outa]")
    command = ["ffmpeg", "-y", "-v", "error", "-i", str(audio_path), "-filter_complex", ";".join(filters),
               "-map", "[outa]", *_render_codec_arguments(output_path), str(temporary)]
    _worker_reporting.progress("ads.cut.render", f"accurately re-encoding {len(keeps)} kept intervals")
    try:
        _run_render_with_progress(command, timeout_s=timeout_s)
        if not temporary.is_file() or temporary.stat().st_size == 0:
            raise WorkerError("cut-output-empty", "ffmpeg produced no playable audio")
        measured = probe_duration(temporary)
        declared = sum(keep.duration_s for keep in keeps)
        if not (measured > 0 and measured < float("inf") and abs(measured - declared) <= RENDER_DURATION_TOLERANCE_S):
            raise WorkerError("cut-duration-mismatch", f"rendered {measured:.3f}s but keep map declares {declared:.3f}s")
        os.replace(temporary, output_path)
    except WorkerError:
        raise
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise WorkerError("cut-render-failed", f"accurate ffmpeg render failed: {type(error).__name__}: {error}") from error
    finally:
        temporary.unlink(missing_ok=True)

def remap_cues(cues: list[dict], keeps: list[KeepInterval]) -> list[dict]:
    """Move cue timing onto the cut audio's clock.

    Cutting ads shifts every timestamp after the first cut, so a transcript
    that was synchronised with the download is wrong the moment the file is
    rewritten. The previous pipeline never did this -- its transcript was read,
    not followed -- which is why this is new code rather than a port.

    A cue landing entirely inside a removed span is dropped. A cue straddling a
    boundary keeps its whole text and is bracketed by the surviving audio: the
    text may then include a few words that were cut, which is a smaller error
    than dropping a line of real content or leaving the timing pointing at
    audio that no longer exists.
    """
    if not keeps:
        return []
    remapped: list[dict] = []
    for cue in cues:
        start, end = float(cue["startSeconds"]), float(cue["endSeconds"])
        covered = [k for k in keeps if k.end_s > start and k.start_s < end]
        if not covered:
            continue
        first, last = covered[0], covered[-1]
        new_start = first.output_start_s + max(0.0, start - first.start_s)
        new_end = last.output_start_s + min(last.duration_s, max(0.0, end - last.start_s))
        if new_end < new_start:
            new_end = new_start
        moved = {
            "startSeconds": round(new_start, 3),
            "endSeconds": round(new_end, 3),
            "text": cue["text"],
        }
        # Cutting an advertisement out moves a cue; it does not change who said
        # it.  This dict is rebuilt by hand, so the key has to be carried
        # explicitly or it is dropped without a word.
        if cue.get("speaker"):
            moved["speaker"] = cue["speaker"]
        remapped.append(moved)
    # Cutting can pull two cues onto the same instant. Order is a contract
    # invariant on the Swift side, so it is restored here rather than there.
    remapped.sort(key=lambda c: c["startSeconds"])
    return remapped

def in_time_order(segments):
    """Return the segments in the order every consumer already assumes.

    Speech-to-text runs in 120-second GPU windows with 15 seconds of overlap,
    and stitching those windows can emit a segment that starts before the one
    ahead of it. The display cues never showed it because `segments_to_cues`
    sorts, but the detector is handed this list unsorted and reads it by
    position: which segments fall in a classification window, where a coarse
    run begins and ends, and which segment the opening review calls first all
    depend on the order being time order. The aligned cache is the only thing
    that ever objected, and it objects by declining to save, so every episode
    paid for speech-to-text twice and nothing said why.
    """
    # A tier that found nothing returns None, and "nothing, in order" is still
    # nothing; sorting is not the place to turn that into an empty list.
    if not segments:
        return segments
    return sorted(segments, key=lambda segment: (float(segment.start_s), float(segment.end_s)))

def segments_to_cues(segments) -> list[dict]:
    """Project the previous pipeline's segments onto the cue contract.

    Token-level timing is dropped on purpose: it is input to ad-boundary
    refinement, not durable state, and keeping it would multiply the stored
    transcript several times over for no reading benefit.
    """
    cues: list[dict] = []
    for segment in segments:
        text = (segment.text or "").strip()
        if not text:
            continue
        start = max(0.0, float(segment.start_s))
        end = max(start, float(segment.end_s))
        cue = {"startSeconds": round(start, 3), "endSeconds": round(end, 3), "text": text}
        # Only published transcripts name anyone.  Speech-to-text segments have
        # no such attribute, so this asks rather than assumes.
        speaker = getattr(segment, "speaker", None)
        if speaker:
            cue["speaker"] = speaker
        cues.append(cue)
    cues.sort(key=lambda c: c["startSeconds"])
    return cues

def cues_to_text(cues: list[dict]) -> str:
    return " ".join(cue["text"] for cue in cues).strip()

def probe_duration(audio_path: Path) -> float:
    import subprocess

    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(audio_path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())
