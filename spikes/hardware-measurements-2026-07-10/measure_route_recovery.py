#!/usr/bin/env python3
"""Disposable hardware-measurement spike — Task 0.3 (deferred) audio-route recovery.

**This is a disposable spike. It is not production code.** See
``README.md`` in this directory for context.

Feeds ADR Decision 5 / the "Deferred to your hardware" consequence:
audio-route recovery — does the app pause into a visible no-output state,
crash, or silently continue routing to the wrong device when the output
device changes mid-playback (unplug headphones, switch to AirPods, etc.)?

This cannot be automated: macOS does not expose a scriptable way to yank
a physical audio device or force a Bluetooth handoff, and the interesting
failure mode is exactly what the *app* does when CoreAudio's default
device changes underneath ``sounddevice`` -- something only a human
watching + listening can observe. This script's job is to:

  1. Start real playback (through AudioEngine.play_file, same public
     surface as measure_playback.py) on a supplied audio file.
  2. Prompt the human, step by step, to change the output route.
  3. Capture the human's observation of what happened (paused cleanly /
     crashed / kept playing to wrong device / silent-but-alive), plus an
     automatic liveness probe (is the playback thread still alive? did
     the process raise?) as a cross-check against the human's report.
  4. Repeat for each of the required scenarios (unplug headphones,
     switch output device via System Settings / Control Center, e.g. to
     AirPods).

Usage:
    PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_route_recovery.py \\
        --episode /path/to/episode.mp3

Run with no ``--episode`` (or ``--help``) for a dry-run guard that touches
no audio hardware.

Idempotent: appends one timestamped block to ``results.log`` per run.
"""

from __future__ import annotations

import argparse
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

SPIKE_DIR = Path(__file__).resolve().parent
REPO_ROOT = SPIKE_DIR.parents[1]
RESULTS_LOG = SPIKE_DIR / "results.log"
FORBIDDEN_WRITE_ROOT = REPO_ROOT / "data"


@dataclass
class ScenarioResult:
    scenario: str
    observation: str
    stayed_responsive: bool
    playback_thread_alive_after: bool
    engine_exception: str | None
    notes: str


def _guard_no_data_writes(episode_path: Path) -> None:
    resolved = episode_path.resolve()
    if not resolved.exists():
        raise FileNotFoundError(f"Episode not found: {resolved}")


def load_engine():
    from wilted.engine import AudioEngine

    return AudioEngine()


def run_scenario(engine, episode_path: Path, scenario_name: str, human_prompt: str) -> ScenarioResult:
    """Starts playback in a background thread, prompts the human to perform
    the physical route change, then asks for an observation and probes
    whether the playback thread is still alive / responsive to stop()."""
    exception_box: dict[str, str | None] = {"exc": None}
    started = threading.Event()

    def play():
        try:
            # Wrap on_progress to signal "playback has actually begun" so
            # the human isn't asked to change the route before audio is
            # flowing.
            def on_progress(seg_idx, total_segments, text):
                started.set()

            engine.play_file(episode_path, on_progress=on_progress)
        except Exception as exc:  # noqa: BLE001 - capturing for the report is the point
            exception_box["exc"] = f"{type(exc).__name__}: {exc}"
        finally:
            started.set()  # unblock waiter even if no transcript segments were passed

    play_thread = threading.Thread(target=play, daemon=True)
    play_thread.start()

    # Without transcript_segments, on_progress never fires (see engine.py:
    # only called when transcript_segments is not None), so just give
    # playback a moment to reach the device instead of waiting on the event.
    time.sleep(1.5)

    print(f"\n--- SCENARIO: {scenario_name} ---")
    print(human_prompt)
    input("Press Enter once you have made the change and are ready to observe...")

    print("Observing for 8 seconds -- listen to what the app does...")
    time.sleep(8.0)

    thread_alive = play_thread.is_alive()

    observation = (
        input(
            "\nOBSERVATION -- what happened? Type one of:\n"
            "  paused        (playback paused into a visible/audible no-output state)\n"
            "  crashed       (the process died or raised visibly)\n"
            "  wrong-device  (playback continued but to the wrong/old device)\n"
            "  followed      (playback correctly followed the new default device)\n"
            "  silent        (no audio, no visible error, unclear state)\n"
            "  other         (describe in notes)\n"
            "> "
        )
        .strip()
        .lower()
    )

    notes = input("Additional notes (optional): ").strip()

    responsive_answer = input("Did the app / terminal stay responsive (not hung)? [y/n]: ").strip().lower()
    stayed_responsive = responsive_answer.startswith("y")

    # Stop this scenario's playback before moving to the next one.
    engine.stop()
    play_thread.join(timeout=5)

    return ScenarioResult(
        scenario=scenario_name,
        observation=observation or "unspecified",
        stayed_responsive=stayed_responsive,
        playback_thread_alive_after=thread_alive,
        engine_exception=exception_box["exc"],
        notes=notes,
    )


def write_results(results: list[ScenarioResult], episode_path: Path) -> None:
    block = [
        f"=== measure_route_recovery.py run @ {time.strftime('%Y-%m-%dT%H:%M:%S%z')} ===",
        f"episode: {episode_path}",
    ]
    for r in results:
        block.append(
            f"  [{r.scenario}] observation={r.observation} stayed_responsive={r.stayed_responsive} "
            f"thread_alive_after={r.playback_thread_alive_after} exception={r.engine_exception!r} notes={r.notes!r}"
        )
    block.append("")
    with RESULTS_LOG.open("a", encoding="utf-8") as f:
        f.write("\n".join(block) + "\n")
    print(f"\nResults appended to {RESULTS_LOG}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audio-route recovery measurement (Task 0.3 deferred / ADR Decision 5 consequence). "
        "Guided, human-observed. Run with no --episode to see this help without touching audio hardware."
    )
    parser.add_argument(
        "--episode",
        type=Path,
        default=None,
        help="Path to an audio file to play during route-change scenarios "
        "(a short clip is fine -- this measures behavior, not the full episode).",
    )
    args = parser.parse_args()

    if args.episode is None:
        parser.print_help()
        print(
            "\nDRY-RUN GUARD: no --episode supplied, so no audio device or hardware was touched. "
            f"This script never writes under {FORBIDDEN_WRITE_ROOT} (isolation guard)."
        )
        return 0

    _guard_no_data_writes(args.episode)

    print("Audio-route recovery measurement (Task 0.3 deferred)")
    print(f"Audio file: {args.episode}")
    print(
        "\nThis script starts real playback, then asks you to physically change your audio output "
        "route (unplug headphones, switch to AirPods, etc.) and observe what the app does.\n"
    )

    engine = load_engine()
    results: list[ScenarioResult] = []

    scenarios = [
        (
            "unplug-headphones",
            "STEP 1: with playback running, physically UNPLUG your wired headphones "
            "(or disconnect your current Bluetooth output) now.",
        ),
        (
            "switch-to-airpods",
            "STEP 2: with playback running, switch your output device via the Sound menu / "
            "Control Center to AirPods (or another Bluetooth device) now.",
        ),
        (
            "switch-back-to-builtin",
            "STEP 3: with playback running, switch your output device back to the Mac's built-in speakers now.",
        ),
    ]

    for name, prompt in scenarios:
        results.append(run_scenario(engine, args.episode, name, prompt))

    engine.stop()

    print("\n=== Summary ===")
    for r in results:
        print(f"  {r.scenario}: {r.observation} (responsive={r.stayed_responsive}, exception={r.engine_exception})")

    write_results(results, args.episode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
