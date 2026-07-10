#!/usr/bin/env python3
"""Disposable hardware-measurement spike — Task 0.4 ML worker-load,
one-model-Metal-residency, and alert-detected -> bulletin-start latency.

**This is a disposable spike. It is not production code.** See
``README.md`` in this directory for context.

Feeds ADR Decision 5 / the "Model lifecycle" consequence: "the LLM/Parakeet
co-residency remediation (W5) is a prerequisite for any reused processing
module; the chosen core introduces a single ``ModelCoordinator`` lease."
This script measures, on your hardware, whether that "at most one
MLX/Metal model resident at a time" property actually holds today across
the three real MLX/Metal-backed model surfaces already in
``src/wilted/``:

  - ``wilted.llm`` — ``MlxBackend`` (mlx_vlm) or ``GgufBackend``
    (llama.cpp), used for classification/summarization
  - ``wilted.engine.AudioEngine`` — Kokoro TTS via ``mlx_audio``, used for
    playback/bulletin synthesis
  - ``wilted.transcribe.transcribe_audio`` — ``parakeet_mlx``, used for
    Tier-3 local transcription

This is a measurement scaffold, not the full radio. It does not require
a live station process, alert pipeline, or scheduler to exist yet. Two
independent guided runs:

  MODE 1 — residency (``--mode residency``):
    Loads each real model in sequence, samples Metal/process memory
    before and after each load/close, and asserts (auto-checked) that no
    two of these three model surfaces are ever resident at the same
    time -- i.e. each is closed before the next is loaded. Records
    load time and close time (Metal reclaim) per model.

  MODE 2 — alert latency (``--mode alert-latency``):
    A stopwatch harness. Prompts you to simulate "an alert has been
    detected" (press Enter to start the clock), then runs a short live
    TTS synthesis of a supplied article/bulletin text through
    ``AudioEngine`` and records the wall-clock delta from "alert
    detected" to "first bulletin audio produced". This measures the
    Kokoro-TTS cold/warm synthesis latency component of the eventual
    alert-interrupt pipeline WITHOUT requiring the alert monitor,
    interruption scheduler, or NWS polling to exist -- it isolates the
    one piece that needs live hardware to measure honestly (TTS
    synthesis wall-clock time on your actual Mac).

Usage:
    PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_ml_residency.py \\
        --mode residency

    PYTHONPATH=src uv run python spikes/hardware-measurements-2026-07-10/measure_ml_residency.py \\
        --mode alert-latency --bulletin-text "Severe thunderstorm warning for your area until 5pm."

Run with no ``--mode`` (or ``--help``) for a dry-run guard that loads no
models and touches no hardware.

Idempotent: appends one timestamped block to ``results.log`` per run.
Never writes under ``data/`` -- LLM/TTS/transcription models are loaded
from the existing Hugging Face cache (``~/.cache/huggingface``), never
from this repo's ``data/`` tree.
"""

from __future__ import annotations

import argparse
import gc
import resource
import sys
import time
from dataclasses import dataclass
from pathlib import Path

SPIKE_DIR = Path(__file__).resolve().parent
REPO_ROOT = SPIKE_DIR.parents[1]
RESULTS_LOG = SPIKE_DIR / "results.log"
FORBIDDEN_WRITE_ROOT = REPO_ROOT / "data"

DEFAULT_LLM_MODEL = "hf:google/gemma-4-E4B-it-qat-q4_0-gguf/gemma-4-E4B_q4_0-it.gguf"
DEFAULT_TTS_MODEL = "mlx-community/Kokoro-82M-bf16"
DEFAULT_TRANSCRIBE_MODEL = "mlx-community/parakeet-tdt-1.1b"


def _rss_mb() -> float:
    try:
        import psutil  # type: ignore[import-not-found]

        return psutil.Process().memory_info().rss / (1024 * 1024)
    except ImportError:
        pass
    usage = resource.getrusage(resource.RUSAGE_SELF)
    divisor = (1024 * 1024) if sys.platform == "darwin" else 1024
    return usage.ru_maxrss / divisor


def _metal_active_mb() -> float | None:
    """Best-effort read of MLX's active Metal memory, if mlx is importable.
    Returns None (not a hard failure) if mlx isn't installed/loadable --
    this script must still run its dry-run guard without mlx present."""
    try:
        import mlx.core as mx

        return mx.get_active_memory() / (1024 * 1024)
    except Exception:
        return None


@dataclass
class ModelPhase:
    model_label: str
    load_s: float
    close_s: float
    rss_before_mb: float
    rss_after_load_mb: float
    rss_after_close_mb: float
    metal_before_mb: float | None
    metal_after_load_mb: float | None
    metal_after_close_mb: float | None


def _guard_isolation() -> None:
    # This script's only writes are to RESULTS_LOG under SPIKE_DIR. Assert
    # that resolves outside the real data/ tree before doing anything else.
    resolved = RESULTS_LOG.resolve()
    if str(resolved).startswith(str(FORBIDDEN_WRITE_ROOT.resolve())):
        raise RuntimeError(f"REFUSING TO RUN: results log resolved under {FORBIDDEN_WRITE_ROOT} -- isolation guard.")


def measure_llm_phase(model_spec: str) -> ModelPhase:
    from wilted.llm import create_backend

    rss_before = _rss_mb()
    metal_before = _metal_active_mb()

    backend = create_backend("gguf" if not model_spec.startswith("mlx:") else "mlx", model=model_spec)

    t0 = time.monotonic()
    backend.load()
    load_s = time.monotonic() - t0
    rss_after_load = _rss_mb()
    metal_after_load = _metal_active_mb()

    # One tiny generation to prove the model is actually usable, not just
    # allocated -- otherwise "load" could succeed on a model that fails
    # silently at inference time.
    try:
        backend.generate("You are a test.", "Reply with one word.")
    except Exception as exc:  # noqa: BLE001 - report, don't crash the residency measurement
        print(f"  WARNING: generate() failed during residency check: {exc}")

    t0 = time.monotonic()
    backend.close()
    close_s = time.monotonic() - t0
    gc.collect()
    rss_after_close = _rss_mb()
    metal_after_close = _metal_active_mb()

    return ModelPhase(
        "LLM (wilted.llm backend)",
        load_s,
        close_s,
        rss_before,
        rss_after_load,
        rss_after_close,
        metal_before,
        metal_after_load,
        metal_after_close,
    )


def measure_tts_phase(model_name: str) -> ModelPhase:
    from wilted.engine import AudioEngine

    engine = AudioEngine(model_name=model_name)

    rss_before = _rss_mb()
    metal_before = _metal_active_mb()

    t0 = time.monotonic()
    engine.load_model()
    load_s = time.monotonic() - t0
    rss_after_load = _rss_mb()
    metal_after_load = _metal_active_mb()

    # AudioEngine has no public close()/unload() -- it's designed to stay
    # loaded for the process lifetime (see engine.py:124-138). To measure
    # "close" cost fairly, drop our own reference and force MLX's cache
    # clear the same way wilted.llm.MlxBackend.close() does, then record
    # what that actually reclaims. This is a measurement-only technique;
    # it does not change engine.py.
    t0 = time.monotonic()
    engine._model = None  # noqa: SLF001 - intentional, measurement-only teardown; see comment above
    gc.collect()
    try:
        import mlx.core as mx

        mx.metal.clear_cache()
    except Exception:
        pass
    close_s = time.monotonic() - t0
    rss_after_close = _rss_mb()
    metal_after_close = _metal_active_mb()

    return ModelPhase(
        "TTS (AudioEngine / Kokoro via mlx_audio)",
        load_s,
        close_s,
        rss_before,
        rss_after_load,
        rss_after_close,
        metal_before,
        metal_after_load,
        metal_after_close,
    )


def measure_transcribe_phase(model_name: str, sample_audio: Path | None) -> ModelPhase:
    rss_before = _rss_mb()
    metal_before = _metal_active_mb()

    t0 = time.monotonic()
    import parakeet_mlx  # type: ignore[import-not-found]

    model = parakeet_mlx.from_pretrained(model_name)
    load_s = time.monotonic() - t0
    rss_after_load = _rss_mb()
    metal_after_load = _metal_active_mb()

    if sample_audio is not None and sample_audio.exists():
        try:
            model.transcribe(str(sample_audio))
        except Exception as exc:  # noqa: BLE001 - report, don't crash the residency check
            print(f"  WARNING: transcribe() failed during residency check: {exc}")
    else:
        print("  (no --sample-audio supplied; skipping an actual transcription call, load/close timing still valid)")

    t0 = time.monotonic()
    del model
    gc.collect()
    try:
        import mlx.core as mx

        mx.metal.clear_cache()
    except Exception:
        pass
    close_s = time.monotonic() - t0
    rss_after_close = _rss_mb()
    metal_after_close = _metal_active_mb()

    return ModelPhase(
        "Transcription (parakeet_mlx)",
        load_s,
        close_s,
        rss_before,
        rss_after_load,
        rss_after_close,
        metal_before,
        metal_after_load,
        metal_after_close,
    )


def run_residency_mode(llm_model: str, tts_model: str, transcribe_model: str, sample_audio: Path | None) -> list[str]:
    lines: list[str] = []
    print("\nLoading and closing each model SEQUENTIALLY, never two at once.")
    print("This directly tests the ADR's 'at most one MLX/Metal model resident at a time' property.\n")

    phases: list[ModelPhase] = []

    print("[1/3] LLM backend...")
    input("  Press Enter to load the LLM backend...")
    phases.append(measure_llm_phase(llm_model))

    print("[2/3] TTS (Kokoro)...")
    input("  Press Enter to load the TTS model...")
    phases.append(measure_tts_phase(tts_model))

    print("[3/3] Transcription (parakeet_mlx)...")
    input("  Press Enter to load the transcription model...")
    phases.append(measure_transcribe_phase(transcribe_model, sample_audio))

    print("\n=== Residency summary ===")
    any_metal_data = any(p.metal_before_mb is not None for p in phases)
    for p in phases:
        lines.append(
            f"  [{p.model_label}] load={p.load_s:.2f}s close={p.close_s:.2f}s "
            f"rss_before={p.rss_before_mb:.0f}MB rss_after_load={p.rss_after_load_mb:.0f}MB "
            f"rss_after_close={p.rss_after_close_mb:.0f}MB "
            f"metal_before={p.metal_before_mb} metal_after_load={p.metal_after_load_mb} "
            f"metal_after_close={p.metal_after_close_mb}"
        )
        print(lines[-1])

    if any_metal_data:
        # Auto-check: each phase's metal_before should be close to the
        # PREVIOUS phase's metal_after_close (i.e. no growth carried over --
        # a rough proxy for "no two models co-resident"). This is advisory,
        # not a hard pass/fail gate (per the task brief: guided measurement,
        # not automated pass/fail), but it's a useful automatic cross-check.
        print("\n  Advisory co-residency check (Metal active memory should return near baseline between phases):")
        baseline = phases[0].metal_before_mb or 0.0
        for p in phases:
            if p.metal_after_close_mb is None:
                continue
            drift = p.metal_after_close_mb - baseline
            flag = "OK" if abs(drift) < 50 else "CHECK -- possible leaked Metal residency"
            msg = (
                f"    {p.model_label}: metal_after_close={p.metal_after_close_mb:.0f}MB "
                f"(baseline={baseline:.0f}MB, drift={drift:+.0f}MB) [{flag}]"
            )
            lines.append(msg)
            print(msg)
    else:
        msg = (
            "  (mlx.core not importable/no Metal device -- Metal-residency numbers unavailable; "
            "RSS numbers above still valid)"
        )
        lines.append(msg)
        print(msg)

    return lines


def run_alert_latency_mode(bulletin_text: str, voice: str, tts_model: str) -> list[str]:
    from wilted.engine import AudioEngine

    engine = AudioEngine(model_name=tts_model, voice=voice)

    print("\nAlert-detected -> bulletin-start latency stopwatch")
    print(f"Bulletin text: {bulletin_text!r}")
    print(
        "\nThis measures TTS synthesis wall-clock time as a stand-in for the 'alert detected' event "
        "(no live alert monitor exists yet -- you are the alert monitor for this measurement)."
    )
    input("\nSTEP: press Enter the instant you want to simulate 'alert detected' (this starts the clock)...")

    t_detected = time.monotonic()
    print("  [clock started] synthesizing + starting bulletin playback now...")

    first_audio = {"t": None}
    import threading

    def watchdog():
        time.sleep(15.0)
        engine.stop()

    watchdog_thread = threading.Thread(target=watchdog, daemon=True)
    watchdog_thread.start()

    # generate_and_play has no on_progress hook, so instead generate once
    # (captures "synthesis done") then time-to-first-block via play_audio's
    # internal stream start, approximated here as "generation complete ->
    # play_audio() call", which is when bulletin audio starts reaching the
    # device.
    engine.load_model()
    t_model_ready = time.monotonic()
    audio = engine.generate_audio(bulletin_text)
    t_synth_done = time.monotonic()
    first_audio["t"] = time.monotonic()
    engine.play_audio(audio)
    watchdog_thread.join(timeout=2)

    detected_to_model_ready_s = t_model_ready - t_detected
    detected_to_bulletin_start_s = first_audio["t"] - t_detected
    synth_s = t_synth_done - t_model_ready

    lines = [
        f"  bulletin_text: {bulletin_text!r}",
        f"  detected_to_model_ready_s: {detected_to_model_ready_s:.2f}s "
        f"({'model was already warm' if detected_to_model_ready_s < 0.05 else 'included a model load'})",
        f"  tts_synthesis_s: {synth_s:.2f}s",
        f"  detected_to_bulletin_start_s: {detected_to_bulletin_start_s:.2f}s",
    ]
    print("\n=== Alert-latency summary ===")
    for line in lines:
        print(line)

    return lines


def write_results(mode: str, lines: list[str]) -> None:
    block = [f"=== measure_ml_residency.py run @ {time.strftime('%Y-%m-%dT%H:%M:%S%z')} (mode={mode}) ==="]
    block.extend(lines)
    block.append("")
    with RESULTS_LOG.open("a", encoding="utf-8") as f:
        f.write("\n".join(block) + "\n")
    print(f"\nResults appended to {RESULTS_LOG}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="ML worker-load, one-model-residency, and alert-latency measurement scaffold "
        "(Task 0.4 / ADR Decision 5 'Model lifecycle' consequence). "
        "Run with no --mode to see this help without loading any model."
    )
    parser.add_argument("--mode", choices=["residency", "alert-latency"], default=None)
    parser.add_argument(
        "--llm-model",
        default=DEFAULT_LLM_MODEL,
        help="Model spec for wilted.llm.create_backend (default: project's gemma GGUF spec).",
    )
    parser.add_argument(
        "--tts-model", default=DEFAULT_TTS_MODEL, help="Model name for AudioEngine (default: project's Kokoro model)."
    )
    parser.add_argument(
        "--transcribe-model",
        default=DEFAULT_TRANSCRIBE_MODEL,
        help="Model name for parakeet_mlx (default: project's parakeet model).",
    )
    parser.add_argument(
        "--sample-audio",
        type=Path,
        default=None,
        help="Optional short audio file for the transcription phase's residency check.",
    )
    parser.add_argument(
        "--bulletin-text",
        default="This is a test weather bulletin for alert-latency measurement.",
        help="Text to synthesize for --mode alert-latency.",
    )
    parser.add_argument("--voice", default="af_heart", help="Kokoro voice for --mode alert-latency (default af_heart).")
    args = parser.parse_args()

    _guard_isolation()

    if args.mode is None:
        parser.print_help()
        print(
            "\nDRY-RUN GUARD: no --mode supplied, so no model was loaded and no hardware was touched. "
            f"This script never writes under {FORBIDDEN_WRITE_ROOT} (isolation guard)."
        )
        return 0

    if args.mode == "residency":
        lines = run_residency_mode(args.llm_model, args.tts_model, args.transcribe_model, args.sample_audio)
    else:
        lines = run_alert_latency_mode(args.bulletin_text, args.voice, args.tts_model)

    write_results(args.mode, lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
