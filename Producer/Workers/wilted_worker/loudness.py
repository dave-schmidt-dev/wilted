"""Measured, opt-in integrated-loudness normalization for prepared episodes."""
from __future__ import annotations

import json
import math
import os
import re
import subprocess
from pathlib import Path

from . import cue_timing as _cue
from . import reporting
from .constants import RENDER_TIMEOUT_S
from .reporting import WorkerError

TARGET_I = -16.0
TARGET_TP = -1.5
VOICE_LEVEL_FILTER = "dynaudnorm=f=500:g=3:p=0.95:m=30:r=0.1,alimiter=limit=0.5:attack=5:release=50:level=0"
_JSON_OBJECT = re.compile(r"\{[^{}]*\}", re.DOTALL)


def measure(path: Path, *, filter_chain: str | None = None) -> tuple[float, float]:
    """Return ffmpeg loudnorm's measured integrated LUFS and true peak dBTP."""
    analysis = ",".join(part for part in (filter_chain,
                                            f"loudnorm=I={TARGET_I}:TP={TARGET_TP}:LRA=11:print_format=json")
                          if part)
    command = ["ffmpeg", "-hide_banner", "-nostats", "-v", "info", "-i", str(path), "-map", "0:a:0",
               "-af", analysis, "-f", "null", "-"]
    stderr = _cue._run_render_with_progress(command, timeout_s=RENDER_TIMEOUT_S, stage="audio.loudness.measure.progress")
    match = _JSON_OBJECT.search(stderr)
    if not match:
        raise WorkerError("loudness-measure-failed", "ffmpeg returned no loudness measurement")
    try:
        data = json.loads(match.group(0))
        integrated, peak = float(data["input_i"]), float(data["input_tp"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise WorkerError("loudness-measure-failed", "ffmpeg returned invalid loudness measurements") from error
    if not (math.isfinite(integrated) and math.isfinite(peak)):
        raise WorkerError("loudness-measure-failed", "audio has no measurable integrated loudness")
    return integrated, peak


def normalize(audio_path: Path, output_path: Path) -> tuple[dict[str, float] | None, str | None]:
    """Normalize a render, preserving its timeline and reporting before/after metrics."""
    temporary: Path | None = None
    try:
        if not audio_path.is_file() or audio_path.stat().st_size == 0:
            raise WorkerError("loudness-input-invalid", "audio to normalize is missing or empty")
        _cue._render_codec_arguments(output_path)
        before_duration = _cue.probe_duration(audio_path)
        before_i, before_tp = measure(audio_path)
        leveled_i, leveled_tp = measure(audio_path, filter_chain=VOICE_LEVEL_FILTER)
    except (WorkerError, OSError, subprocess.SubprocessError) as error:
        reason = error.code if isinstance(error, WorkerError) else type(error).__name__
        return None, reason
    gain = min(TARGET_I - leveled_i, TARGET_TP - leveled_tp)
    if not math.isfinite(gain):
        raise WorkerError("loudness-measure-failed", "normalization gain is not finite")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(f".{output_path.stem}.leveling-{os.getpid()}{output_path.suffix}")
    temporary.unlink(missing_ok=True)
    command = ["ffmpeg", "-y", "-v", "error", "-i", str(audio_path), "-map", "0:a:0",
               "-af", f"{VOICE_LEVEL_FILTER},volume={gain:.6f}dB",
               *_cue._render_codec_arguments(output_path), str(temporary)]
    reporting.progress("audio.loudness.render", f"normalizing to {TARGET_I:g} LUFS")
    try:
        _cue._run_render_with_progress(command, timeout_s=RENDER_TIMEOUT_S,
                                       stage="audio.loudness.render.progress")
        if not temporary.is_file() or temporary.stat().st_size == 0:
            raise WorkerError("loudness-output-empty", "normalization produced no playable audio")
        after_i, after_tp = measure(temporary)
        if abs(after_i - TARGET_I) > 1.0 or after_tp > TARGET_TP + 0.1:
            # One measured correction compensates for codec quantization and the
            # first pass's peak-constrained gain calculation.
            correction = min(TARGET_I - after_i, TARGET_TP - after_tp)
            corrected = temporary.with_name(f".{temporary.stem}.corrected{temporary.suffix}")
            command = ["ffmpeg", "-y", "-v", "error", "-i", str(temporary), "-map", "0:a:0",
                       "-af", f"volume={correction:.6f}dB", *_cue._render_codec_arguments(output_path), str(corrected)]
            _cue._run_render_with_progress(command, timeout_s=RENDER_TIMEOUT_S,
                                           stage="audio.loudness.render.progress")
            if not corrected.is_file() or corrected.stat().st_size == 0:
                raise WorkerError("loudness-output-empty", "corrected normalization produced no playable audio")
            corrected_i, corrected_tp = measure(corrected)
            temporary.unlink(missing_ok=True)
            temporary = corrected
            after_i, after_tp = corrected_i, corrected_tp
        after_duration = _cue.probe_duration(temporary)
        if abs(after_duration - before_duration) > 0.05:
            raise WorkerError("loudness-duration-changed", "normalization changed the audio timeline")
        if abs(after_i - TARGET_I) > 1.0 or after_tp > TARGET_TP + 0.1:
            raise WorkerError("loudness-target-unreachable", "audio could not meet loudness and peak targets")
        os.replace(temporary, output_path)
        return {
            "inputIntegratedLufs": round(before_i, 2),
            "inputTruePeakDbtp": round(before_tp, 2),
            "outputIntegratedLufs": round(after_i, 2),
            "outputTruePeakDbtp": round(after_tp, 2),
            "targetIntegratedLufs": TARGET_I,
            "truePeakCeilingDbtp": TARGET_TP,
        }, None
    except (WorkerError, OSError, subprocess.SubprocessError) as error:
        reason = error.code if isinstance(error, WorkerError) else type(error).__name__
        return None, reason
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
