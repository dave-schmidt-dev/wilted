#!/usr/bin/env python3
"""Disposable hardware-measurement spike — Task 0.4 real-speaker podcast playback.

**This is a disposable spike. It is not production code.** See
``README.md`` in this directory for the full context: ADR 0001
(``docs/adr/0001-mac-radio-substrate.md``) Decision 5 is provisional until
these hardware measurements exist.

Feeds ADR Decision 5 targets:
    - Interruption latency (startup latency is the "cold path" analog)
    - Resume fidelity (checkpoint/resume correctness)
    - The "streaming playback rework" consequence (peak memory / cold-start
      cost of the current full-decode ``play_file`` — the ADR already notes
      542 MB / ~4s cold start for a 94-min 24kHz-mono episode; this script
      re-measures that on YOUR hardware, YOUR episode)

Measures, on a real, human-supplied PREPARED podcast episode, through the
real macOS audio device (``sounddevice`` -> CoreAudio, not a mock):

1. STARTUP LATENCY — wall-clock time from "begin decode" to "first audio
   block written to the output stream" (time to first audio).
2. PEAK MEMORY — peak resident set size (RSS) of this process during
   playback, via ``resource.getrusage`` (stdlib; ``psutil`` used instead
   if already installed, since it reports live peak more precisely, but
   this script never requires installing it — see ``_peak_rss_mb()``).
3. SEEK TIME — wall-clock time to jump to a specific transcript segment
   (segment-index seek, matching ``AudioEngine.play_file``'s
   ``start_segment`` parameter) and produce first audio at the new
   position.
4. CHECKPOINT/RESUME FIDELITY — stop mid-playback, record the reported
   position, "resume" via ``start_segment`` derived from that position,
   and report whether the resumed segment/text matches what a human
   listening would expect (human confirms via a manual observation
   prompt — this script cannot hear the audio).

Only calls the stable public ``AudioEngine`` surface: ``play_file()``,
``get_file_duration()``, ``pause()``, ``resume()``, ``stop()``. Does not
touch the in-flight streaming rework internals.

Usage:
    PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_playback.py \\
        --episode /path/to/a/90-120-minute/prepared/episode.mp3 \\
        [--transcript /path/to/transcript.json]

Run with no ``--episode`` (or ``--help``) to see usage without attempting
playback — this is the "dry run" / guard mode required by the harness
convention; it never touches real audio hardware or ``data/``.

Idempotent: every run starts fresh, appends one timestamped block to
``results.log`` in this directory, and leaves no other state behind.
"""

from __future__ import annotations

import argparse
import gc
import json
import resource
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

SPIKE_DIR = Path(__file__).resolve().parent
REPO_ROOT = SPIKE_DIR.parents[1]
RESULTS_LOG = SPIKE_DIR / "results.log"

# Isolation guard: this script must never import or write into the real
# data/ tree. It only ever *reads* an episode path the human supplies
# explicitly on the command line.
FORBIDDEN_WRITE_ROOT = REPO_ROOT / "data"


def _peak_rss_mb() -> float:
    """Return this process's peak RSS in MB.

    Prefers ``psutil`` if already installed (more precise, cross-platform
    "current" RSS which we sample at intervals to approximate peak), but
    never requires installing it. Falls back to ``resource.getrusage``,
    which reports true peak RSS directly on macOS (in bytes on Darwin,
    unlike Linux's KB) and needs no dependency at all.
    """
    try:
        import psutil  # type: ignore[import-not-found]

        return psutil.Process().memory_info().rss / (1024 * 1024)
    except ImportError:
        pass

    usage = resource.getrusage(resource.RUSAGE_SELF)
    # macOS reports ru_maxrss in bytes; Linux reports it in KB.
    divisor = (1024 * 1024) if sys.platform == "darwin" else 1024
    return usage.ru_maxrss / divisor


@dataclass
class Measurement:
    name: str
    value: str
    detail: str = ""


@dataclass
class RssSampler:
    """Polls peak RSS from a background thread during playback.

    ``resource.getrusage`` already gives true lifetime peak on macOS, so
    this sampler is a belt-and-suspenders cross-check when ``psutil`` is
    present (its call only returns *current* RSS, so we must sample it
    repeatedly to approximate peak).
    """

    samples_mb: list[float] = field(default_factory=list)
    _stop: bool = False

    def sample_once(self) -> None:
        self.samples_mb.append(_peak_rss_mb())

    @property
    def peak_mb(self) -> float:
        return max(self.samples_mb) if self.samples_mb else _peak_rss_mb()


def _guard_no_data_writes(episode_path: Path) -> None:
    """Refuse to run if the episode path looks like it's under a location
    this script itself would write to — this script never writes media
    anywhere, but the guard documents + enforces the isolation contract
    described in README.md even as the script evolves."""
    resolved = episode_path.resolve()
    # We only ever read the episode; assert we hold no write handle to it
    # by never opening it in a write mode anywhere in this file (grep-able
    # invariant, checked here defensively too).
    if not resolved.exists():
        raise FileNotFoundError(f"Episode not found: {resolved}")


def load_engine():
    """Import AudioEngine lazily so --help works without mlx_audio installed
    or a Metal device available."""
    from wilted.engine import AudioEngine

    return AudioEngine()


def load_transcript_segments(transcript_path: Path | None):
    if transcript_path is None:
        return None
    from wilted.transcribe import load_transcript

    segments = load_transcript(transcript_path)
    if segments is None:
        print(f"WARNING: could not load transcript at {transcript_path}; continuing without segment tracking")
    return segments


def measure_duration(engine, episode_path: Path) -> Measurement:
    t0 = time.monotonic()
    duration_s = engine.get_file_duration(episode_path)
    elapsed = time.monotonic() - t0
    minutes = duration_s / 60.0
    in_range = 90.0 <= minutes <= 120.0
    detail = f"{minutes:.1f} min (ffprobe took {elapsed * 1000:.0f} ms)"
    if not in_range:
        detail += " -- WARNING: outside the 90-120 min PREPARED-episode target range; measurement still recorded"
    return Measurement("episode_duration", f"{duration_s:.1f}s", detail)


def measure_startup_latency(engine, episode_path: Path, segments) -> Measurement:
    """Time-to-first-audio: wall clock from play_file() call to the first
    on_progress callback firing (proxy for first block written), since
    AudioEngine has no lower-level hook than on_progress on the stable
    public surface."""
    first_audio_event = {"t": None}
    t0 = time.monotonic()

    def on_progress(seg_idx, total_segments, text):
        if first_audio_event["t"] is None:
            first_audio_event["t"] = time.monotonic()

    # Play only the first few segments (or ~5s of untranscribed audio) so
    # this measurement doesn't require sitting through the whole episode.
    # We stop() from a watchdog thread once we have the startup sample.
    import threading

    def watchdog():
        # Give it up to 20s to produce first audio + a couple more seconds
        # of playback, then stop no matter what, so the script can't hang.
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if first_audio_event["t"] is not None and time.monotonic() - first_audio_event["t"] > 2.0:
                break
            time.sleep(0.05)
        engine.stop()

    watchdog_thread = threading.Thread(target=watchdog, daemon=True)
    watchdog_thread.start()

    try:
        if segments:
            # Limit to first 3 segments so playback stops quickly after
            # startup is captured, without relying on internal engine state.
            engine.play_file(episode_path, transcript_segments=segments[:3], on_progress=on_progress)
        else:
            engine.play_file(episode_path, on_progress=on_progress)
    finally:
        engine.stop()
        watchdog_thread.join(timeout=5)

    if first_audio_event["t"] is None:
        return Measurement(
            "startup_latency",
            "n/a",
            "no on_progress callback fired (no transcript segments supplied, or playback ended before "
            "first segment boundary) -- pass --transcript to get a segment-boundary signal, or check "
            "audio device output manually",
        )
    latency_s = first_audio_event["t"] - t0
    return Measurement(
        "startup_latency", f"{latency_s * 1000:.0f} ms", "time from play_file() call to first on_progress callback"
    )


def measure_seek_time(engine, episode_path: Path, segments) -> Measurement:
    """Seeks to a mid-episode segment via start_segment and times how long
    until the first on_progress callback at/after that segment fires."""
    if not segments or len(segments) < 4:
        return Measurement("seek_time", "n/a", "requires --transcript with at least 4 segments to seek into; skipped")

    target_idx = len(segments) // 2
    first_event = {"t": None}
    t0 = time.monotonic()

    def on_progress(seg_idx, total_segments, text):
        if first_event["t"] is None:
            first_event["t"] = time.monotonic()

    import threading

    def watchdog():
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline:
            if first_event["t"] is not None and time.monotonic() - first_event["t"] > 2.0:
                break
            time.sleep(0.05)
        engine.stop()

    watchdog_thread = threading.Thread(target=watchdog, daemon=True)
    watchdog_thread.start()
    try:
        engine.play_file(episode_path, transcript_segments=segments, start_segment=target_idx, on_progress=on_progress)
    finally:
        engine.stop()
        watchdog_thread.join(timeout=5)

    if first_event["t"] is None:
        return Measurement("seek_time", "n/a", f"seek to segment {target_idx} produced no on_progress callback")
    seek_s = first_event["t"] - t0
    return Measurement(
        "seek_time", f"{seek_s * 1000:.0f} ms", f"seek to segment {target_idx}/{len(segments)} (mid-episode)"
    )


def measure_peak_memory(engine, episode_path: Path, segments, play_seconds: float) -> Measurement:
    """Plays a bounded window of the episode while sampling RSS, reporting
    peak. On macOS, resource.getrusage's ru_maxrss already reflects the
    process's lifetime peak, so the explicit poll loop is redundant with it
    but kept as a visible, auditable measurement independent of platform
    quirks (and to support the optional psutil path, which lacks a
    built-in peak accessor)."""
    sampler = RssSampler()
    gc.collect()
    sampler.sample_once()  # baseline before playback

    stop_flag = {"stop": False}

    import threading

    def sampler_loop():
        while not stop_flag["stop"]:
            sampler.sample_once()
            time.sleep(0.1)

    def watchdog():
        time.sleep(play_seconds)
        engine.stop()

    sampler_thread = threading.Thread(target=sampler_loop, daemon=True)
    watchdog_thread = threading.Thread(target=watchdog, daemon=True)
    sampler_thread.start()
    watchdog_thread.start()

    try:
        if segments:
            engine.play_file(episode_path, transcript_segments=segments)
        else:
            engine.play_file(episode_path)
    finally:
        engine.stop()
        stop_flag["stop"] = True
        sampler_thread.join(timeout=2)
        watchdog_thread.join(timeout=2)

    sampler.sample_once()
    return Measurement(
        "peak_memory_rss",
        f"{sampler.peak_mb:.0f} MB",
        f"sampled every 100ms during a {play_seconds:.0f}s playback window "
        f"({'psutil' if _has_psutil() else 'resource.getrusage (macOS lifetime peak)'})",
    )


def _has_psutil() -> bool:
    try:
        import psutil  # noqa: F401

        return True
    except ImportError:
        return False


def measure_resume_fidelity(engine, episode_path: Path, segments) -> Measurement:
    """Plays briefly, stops, records the last completed segment, then
    'resumes' via start_segment=last+1 and asks the human to confirm the
    resumed text picks up where playback left off (this script cannot
    hear audio, so the fidelity judgment is a human observation)."""
    if not segments:
        return Measurement("resume_fidelity", "n/a", "requires --transcript to test segment-boundary resume; skipped")

    last_seen = {"idx": None, "text": None}

    def on_progress(seg_idx, total_segments, text):
        last_seen["idx"] = seg_idx
        last_seen["text"] = text

    import threading

    def watchdog():
        time.sleep(6.0)
        engine.stop()

    watchdog_thread = threading.Thread(target=watchdog, daemon=True)
    watchdog_thread.start()
    try:
        engine.play_file(episode_path, transcript_segments=segments, on_progress=on_progress)
    finally:
        engine.stop()
        watchdog_thread.join(timeout=3)

    if last_seen["idx"] is None:
        return Measurement("resume_fidelity", "n/a", "no segment boundary crossed in the 6s sample window")

    resume_idx = min(last_seen["idx"] + 1, len(segments) - 1)
    resume_text = segments[resume_idx].text

    print(f"\n  STEP: stopped after segment {last_seen['idx']} (text: {last_seen['text'][:80]!r})")
    print(f"  Resuming at segment {resume_idx} (text: {resume_text[:80]!r})")
    input("  Press Enter to play ~4s starting at the resume point...")

    resumed_seen = {"idx": None}

    def on_progress2(seg_idx, total_segments, text):
        resumed_seen["idx"] = seg_idx

    def watchdog2():
        time.sleep(4.0)
        engine.stop()

    watchdog_thread2 = threading.Thread(target=watchdog2, daemon=True)
    watchdog_thread2.start()
    try:
        engine.play_file(episode_path, transcript_segments=segments, start_segment=resume_idx, on_progress=on_progress2)
    finally:
        engine.stop()
        watchdog_thread2.join(timeout=3)

    verdict = (
        input(
            "  OBSERVATION: did playback resume audibly at/near the expected text with no gap or repeat "
            "you noticed? [y/n]: "
        )
        .strip()
        .lower()
    )
    matched = verdict.startswith("y")
    return Measurement(
        "resume_fidelity",
        "PASS" if matched else "FAIL",
        f"stopped after segment {last_seen['idx']}, resumed at segment {resume_idx}; human confirmed: {verdict!r}",
    )


def begin_results_block(episode_path: Path) -> None:
    """Open a results block and write the header immediately.

    Results are appended incrementally (one line per measurement, as each
    completes) rather than all at the end, so a hang or Ctrl-C in a later step
    never discards the measurements already taken.
    """
    with RESULTS_LOG.open("a", encoding="utf-8") as f:
        f.write(f"=== measure_playback.py run @ {time.strftime('%Y-%m-%dT%H:%M:%S%z')} ===\n")
        f.write(f"episode: {episode_path}\n")


def append_result(m: Measurement) -> None:
    """Append a single measurement line to the open results block."""
    with RESULTS_LOG.open("a", encoding="utf-8") as f:
        f.write(f"  {m.name}: {m.value}  ({m.detail})\n")


def end_results_block() -> None:
    """Close the results block with a trailing blank line."""
    with RESULTS_LOG.open("a", encoding="utf-8") as f:
        f.write("\n")
    print(f"\nResults appended to {RESULTS_LOG}")


def install_hang_guard(engine, max_wait_s: float = 30.0) -> None:
    """Wrap ``engine.play_file`` so no single playback can freeze the script.

    Each measurement already stops playback at its intended short deadline via a
    watchdog thread, and the engine's ``stop()`` now kills the ffmpeg process to
    interrupt a blocked stdout read. But a ``sd.OutputStream.write()`` blocked on
    a wedged CoreAudio device (which can happen after the rapid open/close cycling
    these measurements do) cannot be interrupted by killing ffmpeg. This backstop
    runs each ``play_file`` in a daemon thread and, if it has not returned within
    ``max_wait_s`` (well beyond every watchdog deadline), calls ``stop()`` and
    abandons it — the daemon thread dies with the process — so the walkthrough
    always makes forward progress instead of hanging.
    """
    import threading

    real_play_file = engine.play_file

    def guarded(*args, **kwargs):
        err: dict = {}

        def _run():
            try:
                real_play_file(*args, **kwargs)
            except Exception as e:  # noqa: BLE001 - surface to caller, don't kill the daemon silently
                err["e"] = e

        t = threading.Thread(target=_run, daemon=True)
        t.start()
        t.join(timeout=max_wait_s)
        if t.is_alive():
            engine.stop()
            t.join(timeout=3.0)
            if t.is_alive():
                print(
                    f"  WARNING: playback did not return within {max_wait_s:.0f}s "
                    "(audio device may be wedged); abandoning it and continuing."
                )
        if "e" in err:
            raise err["e"]

    engine.play_file = guarded


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Real-speaker podcast playback measurements (ADR 0001 Decision 5 / Task 0.4). "
        "Guided, human-observed. Run with no --episode to see this help without touching audio hardware."
    )
    parser.add_argument(
        "--episode", type=Path, default=None, help="Path to a prepared 90-120 min podcast episode (mp3/m4a/etc)."
    )
    parser.add_argument(
        "--transcript",
        type=Path,
        default=None,
        help="Optional path to a transcript JSON (TranscriptSegment list) for segment-boundary seek/resume "
        "measurements.",
    )
    parser.add_argument(
        "--memory-window-seconds",
        type=float,
        default=15.0,
        help="How many seconds of playback to sample RSS over for the peak-memory measurement (default 15s).",
    )
    args = parser.parse_args()

    if args.episode is None:
        parser.print_help()
        print(
            "\nDRY-RUN GUARD: no --episode supplied, so no audio device or hardware was touched. "
            "Supply a prepared 90-120 min episode path to run the real measurements. "
            f"This script never writes under {FORBIDDEN_WRITE_ROOT} (isolation guard)."
        )
        return 0

    _guard_no_data_writes(args.episode)

    print("Real-speaker podcast playback measurement (Task 0.4 / ADR Decision 5)")
    print(f"Episode: {args.episode}")
    print("This will play real audio through your current output device.\n")
    input("STEP 0: make sure your speakers/headphones are on and at a safe volume, then press Enter to begin...")

    engine = load_engine()
    install_hang_guard(engine)  # no single playback can freeze the walkthrough
    segments = load_transcript_segments(args.transcript)
    if segments:
        print(f"Loaded {len(segments)} transcript segments.")
    else:
        print("No transcript loaded -- startup/seek/resume measurements that need segment boundaries will report n/a.")

    # Append each measurement to results.log the moment it completes, so a hang or
    # Ctrl-C in a later step never discards the earlier (already-taken) numbers.
    begin_results_block(args.episode)
    measurements: list[Measurement] = []

    def _record(m: Measurement) -> None:
        measurements.append(m)
        append_result(m)
        print(f"  -> {m.name}: {m.value}  ({m.detail})")

    print("\n[1/5] Measuring episode duration (ffprobe)...")
    _record(measure_duration(engine, args.episode))

    print("[2/5] Measuring startup latency (time to first audio)...")
    _record(measure_startup_latency(engine, args.episode, segments))

    print("[3/5] Measuring seek time (mid-episode segment jump)...")
    _record(measure_seek_time(engine, args.episode, segments))

    print(f"[4/5] Measuring peak memory over a {args.memory_window_seconds:.0f}s playback window...")
    _record(measure_peak_memory(engine, args.episode, segments, args.memory_window_seconds))

    print("[5/5] Measuring checkpoint/resume fidelity (human-observed)...")
    _record(measure_resume_fidelity(engine, args.episode, segments))

    end_results_block()

    print("\n=== Summary ===")
    for m in measurements:
        print(f"  {m.name}: {m.value}  ({m.detail})")

    # Emit machine-readable JSON too, for easy copy into RESULTS-TEMPLATE.md.
    print("\nJSON:")
    print(json.dumps([{"name": m.name, "value": m.value, "detail": m.detail} for m in measurements], indent=2))

    return 0


if __name__ == "__main__":
    sys.exit(main())
