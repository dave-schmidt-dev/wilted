"""Transcript ingestion — local transcription via the resident speech-stack daemon (parakeet).

Transcription dispatches to ``speech_stack.client.stt_path``, which routes the
request to the daemon's resident parakeet model over its persistent GPU worker.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

# Hard dependency: wilted's launch venv installs speech-stack as an editable
# dependency. ``client`` is the ONLY tier-3 STT route; ``isolated`` supplies the
# identical typed error classes that the daemon transport reconstructs and raises.
# Tests patch ``wilted.transcribe.client.stt_path``.
from speech_stack import client, isolated

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
class TranscriptToken:
    """One aligned transcript token with second-resolution timing."""

    text: str
    start_s: float
    end_s: float


@dataclass
class TranscriptSegment:
    """A segment of transcript with timestamps and optional aligned tokens."""

    start_s: float
    end_s: float
    text: str
    tokens: tuple[TranscriptToken, ...] | None = None


# ---------------------------------------------------------------------------
# Tier 3: Local transcription via the resident speech daemon
# ---------------------------------------------------------------------------


# Wall-clock ceiling for one STT transcription run. Matches speech-stack's
# default (1800s); env-overridable via WILTED_TRANSCRIBE_TIMEOUT_S.
_TRANSCRIBE_TIMEOUT_S = 1800.0


def _run_stt_via_daemon(request: dict, timeout: float) -> dict:
    """Transcribe ``request`` via the resident speech daemon.

    Routes the request params through ``speech_stack.client.stt_path``; the
    daemon's result dict is byte-identical to what the pre-cutover isolated
    spawn-per-call path returned (Phase 2 parity), so :func:`transcribe_audio`'s
    segment construction is unchanged.

    The daemon is the ONLY tier-3 STT route (M2 daemon cutover) — there is no
    isolated-spawn fallback. Every typed error (``DaemonUnavailable`` / ``Timeout``
    / ``GpuAborted`` / ``GpuSegfault`` / ``WorkerError`` — all the SAME classes
    ``speech_stack.client`` re-exports from ``isolated``) propagates unchanged to
    :func:`transcribe_audio`'s existing ``except`` ladder and surfaces as the
    matching ``TranscriptionError`` subclass. A genuine GPU crash or a down daemon
    is therefore NEVER masked by a silent spawn retry (INV-6).
    """
    # Everything except the positional audio_path rides as **params, exactly
    # mirroring the dict the pre-cutover isolated path forwarded to stt.transcribe
    # (model binds to stt_path's keyword; the rest — chunk/overlap/sentence_split/
    # budget/decoding/… — pass through). Extra keys the model ignores are
    # swallowed by stt.transcribe(**_).
    params = {k: v for k, v in request.items() if k != "audio_path"}
    return client.stt_path(request["audio_path"], timeout=timeout, **params)


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
    """Transcribe an audio file via the resident speech-stack daemon.

    Rather than importing parakeet in-process, it dispatches to
    ``speech_stack.client.stt_path(...)``, which routes the request to the
    daemon's resident model over its persistent GPU worker. A Metal fault
    (SIGABRT) or segfault in the model kills only the daemon's worker — this
    process survives and gets a typed error instead of dying.

    The daemon is the ONLY tier-3 STT route (M2 daemon cutover) — there is no
    isolated-spawn fallback. A down daemon surfaces as a typed
    ``TranscriptionError`` (see Raises below) rather than being silently retried
    via a spawned child process.

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
            ``Path``; callers pass either, so it is coerced to ``Path`` on entry.
        model_name: HuggingFace model name for parakeet.
        chunk_duration: Seconds of audio decoded per GPU chunk (default 120s).
        overlap_duration: Seconds of overlap between adjacent chunks (default 15s).

    Returns:
        List of TranscriptSegment from model output.

    Raises:
        TranscriptionTimeout: The worker exceeded its wall-clock timeout.
        TranscriptionAborted: The worker died via a hard GPU crash (SIGABRT/SIGSEGV).
        TranscriptionWorkerError: The worker raised a caught exception / no result.
        TranscriptionError: The daemon or its transport is unavailable
            (``DaemonUnavailable`` — for example, a down/rolled-back daemon), another
            isolation error occurred, or transcription produced no segments.
        ExecutionCapabilityError: When called without PipelineRunner authority.
    """
    from wilted.execution_capability import require_execution_capability

    require_execution_capability()

    # Accept str or Path from any caller (native pipeline, tests). Coerce once
    # so the request payload and the completion log agree on the type.
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

    # The daemon is the ONLY tier-3 STT route (M2 daemon cutover). The typed-error
    # mapping below matches the pre-cutover isolated-spawn contract exactly:
    # speech_stack.client re-exports the SAME isolated error classes, so a real GPU
    # crash or a down daemon surfaces the same TranscriptionError subclass it always
    # did (INV-6).
    try:
        result = _run_stt_via_daemon(request, timeout)
    except isolated.Timeout as e:
        raise TranscriptionTimeout(f"Transcription timed out: {e}") from e
    except (isolated.GpuAborted, isolated.GpuSegfault) as e:
        raise TranscriptionAborted(f"Transcription crashed on GPU: {e}") from e
    except (isolated.WorkerError, client.ConnectionLost) as e:
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
            tokens=_parse_aligned_tokens(seg.get("tokens")),
        )
        for seg in result.get("segments", [])
    ]

    if not segments:
        raise TranscriptionError("Transcription produced no segments")

    logger.info("Transcribed %d segments from %s", len(segments), audio_path.name)
    return segments


def _parse_aligned_tokens(raw_tokens: object) -> tuple[TranscriptToken, ...] | None:
    """Decode optional aligned tokens from a daemon result."""
    if raw_tokens is None:
        return None
    if not isinstance(raw_tokens, list):
        raise TypeError("transcript tokens must be a list")
    return tuple(
        TranscriptToken(
            text=str(token["text"]),
            start_s=float(token["start_s"]),
            end_s=float(token["end_s"]),
        )
        for token in raw_tokens
    )
