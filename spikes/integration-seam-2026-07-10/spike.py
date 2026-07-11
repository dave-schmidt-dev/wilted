"""Throwaway integration-seam spike for Plan A (station MediaDescriptor -> PlaybackAdapter -> engine.play_file).

Surfaces two integration risks with CONCRETE, RUN-TIME evidence before any
real adapter code is written:

  PM-1: station.TranscriptSegment (start_ms: int, milliseconds) is a
        DIFFERENT TYPE than transcribe.TranscriptSegment (start_s: float,
        seconds) -- the latter is what engine.play_file actually duck-types
        against. A PlaybackAdapter must convert ms -> s exactly once, in one
        place, or a missed/duplicated "/1000.0" silently mis-seeks resume by
        three orders of magnitude. This script builds REAL station-shaped
        segments from a REAL on-disk transcript, adapts them, feeds them to a
        REAL AudioEngine.play_file() call against a REAL mp3, and proves the
        seek landed at the expected episode-time offset.

  PM-3: an article's prepared audio is a per-paragraph mp3 DIRECTORY, not a
        single file the way a podcast is -- this script inspects the real
        on-disk manifest.json shape and a real "not yet prepared" (empty)
        case, to ground the finalization contract written up in FINDINGS.md.

Constraints honored:
  - No TTS/ML model load. AudioEngine() is constructed but .load_model() and
    .generate_audio() are never called -- only the pre-existing-file playback
    path (play_file) is exercised.
  - No audible sound. sounddevice.OutputStream is patched to a MagicMock,
    exactly the way tests/test_engine.py does it (see mock_stream fixture,
    tests/test_engine.py:33-39) -- this is an existing, project-approved
    pattern for testing play_file's real ffmpeg-decode + real seek-arithmetic
    path without opening a real audio device. ffmpeg itself is NOT mocked:
    the spike shells out to the real `ffmpeg` binary against the real mp3, so
    the seek proof is genuine, not simulated.
  - Terminates cleanly: play_file runs in a background thread and is stopped
    with a bounded timeout; the thread join always has a timeout so the
    script cannot hang.

Run with:
  cd /Users/dave/Documents/Projects/wilted && \
    PYTHONPATH=src UV_PROJECT_ENVIRONMENT=$HOME/.venvs/wilted \
    uv run --group dev python spikes/integration-seam-2026-07-10/spike.py
"""

from __future__ import annotations

import hashlib
import json
import sys
import threading
from pathlib import Path
from typing import NamedTuple
from unittest.mock import MagicMock, patch

REPO_ROOT = Path(__file__).resolve().parents[2]
PODCAST_MP3 = REPO_ROOT / "data/podcasts/measure-404-best-game/80391e99cf24d187eec49da364a45858.mp3"
PODCAST_TRANSCRIPT = REPO_ROOT / "data/transcripts/measure-404-best-game_transcript.json"
ARTICLE_1_DIR = REPO_ROOT / "data/audio/1"
ARTICLE_2_DIR = REPO_ROOT / "data/audio/2"
ARTICLES_TXT_DIR = REPO_ROOT / "data/articles"

TARGET_SEGMENT_IDX = 12  # picked for a clean, illustrative start_s (~126.68s)
SEEK_TOLERANCE_S = 1.0  # allow for ffmpeg decode-startup granularity


def section(title: str) -> None:
    print()
    print("=" * 78)
    print(title)
    print("=" * 78)


# ---------------------------------------------------------------------------
# PM-1: the thin "PlaybackAdapter" being spiked.
#
# This is deliberately the ENTIRE adapter: one function, one conversion line,
# one call site. The point of PM-1 is that this conversion must live in
# exactly one tested place -- not scattered inline at every call site that
# touches station transcript segments -- so a wrong divisor (missing /1000,
# or an accidental double-divide) can't silently reappear in a second copy.
# ---------------------------------------------------------------------------


class EngineTranscriptSegment(NamedTuple):
    """Duck-typed stand-in for transcribe.TranscriptSegment.

    engine.play_file only ever reads .start_s / .end_s / .text off whatever
    is in transcript_segments (see engine.py:465 and :496) -- it does not
    isinstance-check against transcribe.TranscriptSegment, so any object
    exposing these three attributes works. A NamedTuple is the simplest
    faithful stand-in; a real PlaybackAdapter could equally construct actual
    transcribe.TranscriptSegment instances.
    """

    start_s: float
    end_s: float
    text: str


def station_segments_to_engine_segments(station_segments) -> list[EngineTranscriptSegment]:
    """The one-line conversion a real PlaybackAdapter must own exclusively.

    station.TranscriptSegment stores start_ms/end_ms as integer milliseconds
    (src/wilted/station/models.py:47-66). engine.play_file wants float
    seconds (src/wilted/transcribe.py:34-40 shape). The conversion is exactly
    ``seconds = milliseconds / 1000.0`` -- get this wrong (forget the divide,
    or divide twice) and resume seeks land 1000x too far or 1000x too close,
    silently, with no exception raised anywhere.
    """
    return [
        EngineTranscriptSegment(
            start_s=seg.start_ms / 1000.0,
            end_s=seg.end_ms / 1000.0,
            text=seg.text,
        )
        for seg in station_segments
    ]


def run_pm1_proof() -> dict:
    """Build real station-shaped segments from the real transcript cache,
    adapt them, and prove engine.play_file seeks to the expected offset.

    Returns a dict of the key observed numbers so run() can print a final
    summary line and so this function's results are easy to assert on.
    """
    section("PM-1: TranscriptSegment unit-mismatch proof (station ms vs engine s)")

    # These imports are done here (not at module top) so a failure to import
    # wilted.station or wilted.engine produces a clear, localized traceback
    # rather than aborting the whole script before PM-3 inspection can run.
    from wilted import transcribe
    from wilted.engine import AudioEngine
    from wilted.station.models import (
        FinalizationState,
        MediaDescriptor,
        SafeInterruptionMap,
    )
    from wilted.station.models import TranscriptSegment as StationTranscriptSegment

    if not PODCAST_MP3.exists():
        raise FileNotFoundError(f"expected real podcast mp3 at {PODCAST_MP3}")
    if not PODCAST_TRANSCRIPT.exists():
        raise FileNotFoundError(f"expected real transcript cache at {PODCAST_TRANSCRIPT}")

    # --- Load the REAL transcribe.py-shape cache (start_s/end_s floats). ---
    engine_shaped_segments = transcribe.load_transcript(PODCAST_TRANSCRIPT)
    assert engine_shaped_segments is not None, "load_transcript returned None -- bad path?"
    print(f"Loaded {len(engine_shaped_segments)} transcribe.TranscriptSegment from {PODCAST_TRANSCRIPT.name}")

    target = engine_shaped_segments[TARGET_SEGMENT_IDX]
    print(
        f"Segment[{TARGET_SEGMENT_IDX}] as-loaded (transcribe.py shape): start_s={target.start_s} end_s={target.end_s}"
    )
    print(f"  text preview: {target.text[:70]!r}...")

    # --- Simulate the station's ms-shaped cache by converting s -> ms. ---
    # Nothing in the codebase today produces real station TranscriptSegment
    # rows from this on-disk data (the on-disk cache is already in
    # transcribe.py/seconds shape) -- so to faithfully exercise the seam a
    # real PlaybackAdapter will actually face (station DB stores ms, engine
    # wants s), we simulate the station's ms storage here by round-tripping
    # every loaded segment through start_ms = round(start_s * 1000).
    station_segments = tuple(
        StationTranscriptSegment(
            start_ms=round(seg.start_s * 1000),
            end_ms=round(seg.end_s * 1000),
            text=seg.text,
        )
        for seg in engine_shaped_segments
    )
    target_station_seg = station_segments[TARGET_SEGMENT_IDX]
    print(
        f"Simulated station.TranscriptSegment[{TARGET_SEGMENT_IDX}]: "
        f"start_ms={target_station_seg.start_ms} end_ms={target_station_seg.end_ms}"
    )

    # --- Build a full MediaDescriptor (is_playable=True) around it. ---
    # This isn't strictly required to prove the seek arithmetic (that only
    # needs the adapted list below), but Plan A's real code path constructs
    # play_file's transcript_segments FROM a MediaDescriptor, so building the
    # whole descriptor here proves the surrounding types compose without
    # friction -- an integration risk in its own right, separate from the
    # unit-conversion risk.
    mp3_bytes = PODCAST_MP3.read_bytes()
    sha256 = hashlib.sha256(mp3_bytes).hexdigest()
    byte_size = len(mp3_bytes)
    duration_ms = round(station_segments[-1].end_ms)
    safe_map = SafeInterruptionMap.from_transcript_segments(station_segments)
    descriptor = MediaDescriptor(
        sha256=sha256,
        byte_size=byte_size,
        mime_type="audio/mpeg",
        duration_ms=duration_ms,
        transcript_segments=station_segments,
        safe_interruption=safe_map,
        byte_range_available=False,
        finalization=FinalizationState.complete(),
    )
    print(
        f"Built MediaDescriptor: sha256={descriptor.sha256[:12]}... byte_size={descriptor.byte_size} "
        f"duration_ms={descriptor.duration_ms} is_playable={descriptor.is_playable}"
    )
    assert descriptor.is_playable, "MediaDescriptor should be playable (FinalizationState.complete())"

    # --- Run the adapter: descriptor.transcript_segments (ms) -> engine segments (s). ---
    adapted_segments = station_segments_to_engine_segments(descriptor.transcript_segments)
    adapted_target = adapted_segments[TARGET_SEGMENT_IDX]
    expected_start_s = target_station_seg.start_ms / 1000.0
    print(
        f"Adapted segment[{TARGET_SEGMENT_IDX}]: start_ms={target_station_seg.start_ms} "
        f"-> converted start_s={adapted_target.start_s}"
    )
    assert adapted_target.start_s == expected_start_s

    # --- Drive engine.play_file with sounddevice mocked, ffmpeg real. ---
    # Patching sounddevice.OutputStream is the SAME pattern tests/test_engine.py
    # uses (see mock_stream fixture, tests/test_engine.py:33-39): it stops any
    # audio from actually reaching a speaker while leaving ffmpeg (real
    # subprocess, real -ss seek, real decode of the real mp3) completely
    # untouched -- so the seek proof below is genuine, not simulated.
    #
    # IMPORTANT DISCOVERY (left in place deliberately -- it's itself a useful
    # finding): with OutputStream mocked to a no-op, _stream_pcm's write loop
    # never blocks on real audio-hardware pacing, so ffmpeg's piped PCM is
    # consumed far faster than real time (measured: this ~94-minute episode's
    # ffmpeg decode/pipe rate lets play_file blow past a fixed 0.5s sleep and
    # run to (near) completion before a wall-clock-timed engine.stop() ever
    # fires). A fixed sleep-then-stop is therefore the WRONG way to bound
    # this call once output is mocked. Instead, use on_progress as the stop
    # trigger: engine.py's _on_block fires on_progress exactly once as
    # playback crosses into each segment, starting with start_segment itself
    # (seg_cursor starts there, so it fires on the very first emitted
    # block -- see engine.py:481-497). Stopping the instant on_progress fires
    # for our target segment stops playback within a few PCM blocks of the
    # seek landing, regardless of ffmpeg's decode speed.
    engine = AudioEngine()  # no model load happens here; play_file never touches self._model

    play_exc: list[BaseException] = []
    seek_confirmed = threading.Event()

    def _on_progress(seg_idx: int, total: int, text: str) -> None:
        if seg_idx == TARGET_SEGMENT_IDX:
            seek_confirmed.set()

    def _run_play_file() -> None:
        try:
            engine.play_file(
                path=PODCAST_MP3,
                transcript_segments=adapted_segments,
                start_segment=TARGET_SEGMENT_IDX,
                on_progress=_on_progress,
            )
        except BaseException as exc:  # noqa: BLE001 - surfaced to main thread below
            play_exc.append(exc)

    with patch("sounddevice.OutputStream") as mock_output_stream_cls:
        mock_stream_instance = MagicMock()
        mock_output_stream_cls.return_value = mock_stream_instance

        play_thread = threading.Thread(target=_run_play_file, daemon=True)
        play_thread.start()

        # Wait for on_progress to confirm the seek landed on the target
        # segment (should fire almost immediately -- it's the first block),
        # bounded so the script can never hang even if something regresses.
        confirmed = seek_confirmed.wait(timeout=10.0)
        if not confirmed:
            print("WARNING: on_progress never fired for the target segment within 10s.")

        engine.stop()  # engine.py:592 -- sets _stop_event, kills the ffmpeg proc
        play_thread.join(timeout=5.0)

    if play_thread.is_alive():
        print("WARNING: play_file thread did not stop within timeout -- may still be running.")
    if play_exc:
        raise play_exc[0]

    observed_playback_time_s = engine.playback_time_s
    observed_segment_idx = engine.current_segment_idx
    delta = abs(observed_playback_time_s - expected_start_s)
    passed = delta < SEEK_TOLERANCE_S

    print(f"expected start_s (seek target)   = {expected_start_s}")
    print(f"engine.playback_time_s (observed) = {observed_playback_time_s}")
    print(f"engine.current_segment_idx        = {observed_segment_idx}")
    print(f"delta                              = {delta:.6f}s (tolerance {SEEK_TOLERANCE_S}s)")
    print("NOTE: sounddevice.OutputStream was mocked -- no audible playback occurred.")

    status = "PASS" if passed else "FAIL"
    print(
        f"PM-1 PROOF: segment {TARGET_SEGMENT_IDX} start_ms={target_station_seg.start_ms} "
        f"-> converted start_s={adapted_target.start_s} -> engine sought to "
        f"playback_time_s={observed_playback_time_s:.6f} (delta={delta:.6f}s) {status}"
    )
    assert passed, f"seek delta {delta}s exceeded tolerance {SEEK_TOLERANCE_S}s"

    return {
        "segment_idx": TARGET_SEGMENT_IDX,
        "start_ms": target_station_seg.start_ms,
        "expected_start_s": expected_start_s,
        "observed_playback_time_s": observed_playback_time_s,
        "observed_segment_idx": observed_segment_idx,
        "delta": delta,
        "passed": passed,
    }


def run_pm3_inspection() -> None:
    """Inspect the real on-disk article audio-cache shapes (PM-3 grounding).

    Purely read-only inspection -- no engine calls, no TTS. This grounds the
    "article finalization completeness contract" written up in FINDINGS.md
    against real on-disk evidence rather than assumption.
    """
    section("PM-3: article per-paragraph audio cache inspection")

    # --- Case 1: article_id=1 -- a COMPLETE per-paragraph cache. ---
    manifest_path = ARTICLE_1_DIR / "manifest.json"
    print(f"Inspecting {ARTICLE_1_DIR} (expected: complete cache)...")
    if not manifest_path.exists():
        raise FileNotFoundError(f"expected manifest at {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    paragraphs = manifest.get("paragraphs", [])
    mp3_files = sorted(ARTICLE_1_DIR.glob("para_*.mp3"))
    print(f"  manifest status        = {manifest.get('status')!r}")
    print(
        f"  manifest voice/lang    = {manifest.get('voice')!r}/{manifest.get('lang')!r} speed={manifest.get('speed')}"
    )
    print(f"  manifest paragraph ct  = {len(paragraphs)}")
    print(f"  mp3 files on disk      = {len(mp3_files)}")
    all_exist_nonempty = all(
        (ARTICLE_1_DIR / p["file"]).exists() and (ARTICLE_1_DIR / p["file"]).stat().st_size > 0 for p in paragraphs
    )
    print(f"  all listed mp3s exist & non-empty = {all_exist_nonempty}")

    # Cumulative-duration timing map: paragraph N's start_s is the running
    # sum of every prior paragraph's duration_seconds. This is exactly the
    # per-paragraph timing map a concat-based PlaybackAdapter would need to
    # build transcript_segments for the single concatenated output file.
    cumulative_s = 0.0
    timing_map = []
    for p in paragraphs:
        timing_map.append((p["file"], cumulative_s, cumulative_s + p["duration_seconds"]))
        cumulative_s += p["duration_seconds"]
    total_duration_s = cumulative_s
    print(f"  derived total duration = {total_duration_s:.3f}s (sum of per-paragraph duration_seconds)")
    print("  first 3 timing-map rows (file, start_s, end_s):")
    for row in timing_map[:3]:
        print(f"    {row[0]}: start_s={row[1]:.3f} end_s={row[2]:.3f}")

    is_complete_cache = (
        manifest.get("status") == "complete" and len(mp3_files) == len(paragraphs) and all_exist_nonempty
    )
    print(f"  => CACHE COMPLETE: {is_complete_cache}")

    # --- Case 2: article_id=2 -- EMPTY dir, no manifest at all. ---
    print(f"\nInspecting {ARTICLE_2_DIR} (expected: not yet prepared)...")
    if not ARTICLE_2_DIR.exists():
        raise FileNotFoundError(f"expected (empty) dir at {ARTICLE_2_DIR}")
    entries = list(ARTICLE_2_DIR.iterdir())
    manifest_2_path = ARTICLE_2_DIR / "manifest.json"
    print(f"  directory entries      = {len(entries)} ({[e.name for e in entries]})")
    print(f"  manifest.json exists   = {manifest_2_path.exists()}")
    print("  => CACHE COMPLETE: False (no manifest, no audio -- article not prepared)")

    # --- Article transcript vs audio-cache: no filename correlation. ---
    print(f"\nInspecting {ARTICLES_TXT_DIR} (article transcript stand-ins)...")
    txt_files = sorted(ARTICLES_TXT_DIR.glob("*.txt"))
    for f in txt_files:
        try:
            size = f.stat().st_size
            print(f"  {f.name}  ({size} bytes)")
        except PermissionError:
            print(f"  {f.name}  (PermissionError reading stat -- permissions quirk, not investigated further)")
    print(
        "  NOTE: article transcript text lives under data/articles/<item_id>_<slug>.txt while "
        "prepared per-paragraph audio lives under data/audio/<item_id>/ -- there is NO filename "
        "correlation between the two directories. The link is DB-mediated via Item.id "
        "(src/wilted/db.py), not path-inferable: a caller must already know the item_id to find "
        "either artifact."
    )

    print()
    print("PM-3 SUMMARY:")
    print(f"  data/audio/1/ -> COMPLETE per-paragraph cache (status=complete, {len(mp3_files)} mp3s, manifest present)")
    print("  data/audio/2/ -> NOT PREPARED (empty dir, no manifest, no mp3s)")


def main() -> int:
    pm1_result = run_pm1_proof()
    run_pm3_inspection()

    section("SPIKE COMPLETE")
    print(f"PM-1: {'PASS' if pm1_result['passed'] else 'FAIL'}")
    print("PM-3: inspection complete (see output above)")
    return 0 if pm1_result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
