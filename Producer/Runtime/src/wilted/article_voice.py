"""Generate private Wilted article audio with an explicitly selected local voice."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import io
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Iterator


_VOICE_FILES = {
    "casey-kasem": "casey-reference.wav",
    "wolfman-jack": "wolfman-reference.wav",
    "paul-harvey": "paul-harvey-reference.wav",
    "rod-serling": "rod-serling-reference.wav",
}
_MODEL_RELATIVE_PATH = Path("Documents/Projects/chatterbox/models/chatterbox-turbo-8bit")
_REFERENCES_RELATIVE_PATH = Path("Documents/Projects/chatterbox/reference-audio/prepared")
_MAX_TEXT_BYTES = 2 * 1024 * 1024
_MAX_OUTPUT_BYTES = 250 * 1024 * 1024
_active_encoder: subprocess.Popen[bytes] | None = None


class ArticleVoiceError(Exception):
    """A safe, user-facing narration failure code."""

    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _paths(home: Path, voice_id: str) -> tuple[Path, Path]:
    filename = _VOICE_FILES.get(voice_id)
    if filename is None:
        raise ArticleVoiceError("unsupported_voice")
    model = home / _MODEL_RELATIVE_PATH
    reference_root = home / _REFERENCES_RELATIVE_PATH
    reference = reference_root / filename
    if not model.is_dir() or not (model / "model.safetensors").is_file() or not (model / "config.json").is_file():
        raise ArticleVoiceError("missing_model")
    try:
        resolved_root = reference_root.resolve(strict=True)
        resolved_reference = reference.resolve(strict=True)
    except OSError as error:
        raise ArticleVoiceError("missing_voice") from error
    if resolved_root not in resolved_reference.parents or not resolved_reference.is_file():
        raise ArticleVoiceError("missing_voice")
    return model, resolved_reference


def voice_availability(home: Path, voice_id: str) -> bool:
    """Return whether the exact local model and approved reference are present."""
    _paths(home, voice_id)
    return True


@contextlib.contextmanager
def _gpu_admission(
    model_path: Path,
    lock_path: Path | None,
    progress: Callable[[str, float | None], None],
):
    """Use Wilted's daemon-draining GPU gate, with a fixture-only lock seam."""
    if lock_path is None:
        from wilted_worker.gpu_admission import prepare_ad_model_lock

        def gate_progress(_stage: str, _detail: str) -> None:
            progress("loading", None)

        with prepare_ad_model_lock(str(model_path), aligned_stt=False, progress=gate_progress):
            yield
        return

    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _load_model(model_path: Path) -> Any:
    from mlx_audio.tts.utils import load_model

    return load_model(model_path)


def _quiet_segments(
    generated: Iterable[Any], progress: Callable[[str, float | None], None]
) -> Iterator[Any]:
    iterator = iter(generated)
    while True:
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                segment = next(iterator)
            except StopIteration:
                return
        progress("synthesizing", None)
        yield segment


def _write_m4a_stream(
    output_path: Path,
    segments: Iterable[Any],
    progress: Callable[[str, float | None], None],
) -> tuple[int, int]:
    global _active_encoder
    import numpy as np

    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise ArticleVoiceError("missing_encoder")
    iterator = iter(segments)
    try:
        first_segment = next(iterator)
    except StopIteration as error:
        raise ArticleVoiceError("invalid_audio") from error
    sample_rate = getattr(first_segment, "sample_rate", None)
    if not isinstance(sample_rate, int) or sample_rate <= 0:
        raise ArticleVoiceError("invalid_audio")
    process = subprocess.Popen(
        [
            ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", str(sample_rate),
            "-ac", "1", "-i", "pipe:0", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
            "-f", "ipod", str(output_path),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    frames = 0
    _active_encoder = process
    try:
        if process.stdin is None:
            raise ArticleVoiceError("missing_encoder")
        frames += _write_segment(first_segment, process, output_path, np)
        for segment in iterator:
            rate = getattr(segment, "sample_rate", None)
            if rate != sample_rate:
                raise ArticleVoiceError("invalid_audio")
            frames += _write_segment(segment, process, output_path, np)
            progress("synthesizing", None)
        process.stdin.close()
        if process.wait() != 0:
            raise ArticleVoiceError("synthesis_failed")
        size = output_path.stat().st_size
        if frames == 0 or size <= 0:
            raise ArticleVoiceError("invalid_audio")
        if size > _MAX_OUTPUT_BYTES:
            raise ArticleVoiceError("audio_too_large")
        return sample_rate, round(frames / sample_rate * 1_000)
    except BaseException:
        if process.poll() is None:
            process.terminate()
        process.wait()
        raise
    finally:
        _active_encoder = None
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()


def _write_segment(segment: Any, process: subprocess.Popen[bytes], output_path: Path, np: Any) -> int:
    if process.stdin is None or process.poll() is not None:
        raise ArticleVoiceError("synthesis_failed")
    samples = getattr(segment, "audio", None)
    if samples is None:
        raise ArticleVoiceError("invalid_audio")
    if hasattr(samples, "tolist") and not hasattr(samples, "__array__"):
        samples = np.asarray(samples.tolist(), dtype="<f4")
    else:
        samples = np.asarray(samples, dtype="<f4")
    samples = samples.reshape(-1)
    if samples.size == 0 or not np.isfinite(samples).all():
        raise ArticleVoiceError("invalid_audio")
    block = np.clip(samples, -1.0, 1.0).astype("<f4", copy=False).tobytes()
    try:
        process.stdin.write(block)
        process.stdin.flush()
    except (BrokenPipeError, OSError) as error:
        raise ArticleVoiceError("synthesis_failed") from error
    frames = len(block) // 4
    del samples, block
    if output_path.exists() and output_path.stat().st_size > _MAX_OUTPUT_BYTES:
        raise ArticleVoiceError("audio_too_large")
    return frames


def synthesize(
    text: str,
    voice_id: str,
    output_path: Path,
    *,
    home: Path | None = None,
    lock_path: Path | None = None,
    model_loader: Callable[[Path], Any] = _load_model,
    audio_writer: Callable[
        [Path, Iterable[Any], Callable[[str, float | None], None]], tuple[int, int]
    ] = _write_m4a_stream,
    normalize_loudness: bool = False,
    loudness_normalizer: Callable[[Path, Path], tuple[dict[str, float] | None, str | None]] | None = None,
    progress: Callable[[str, float | None], None] = lambda _stage, _fraction: None,
) -> tuple[int, int]:
    """Synthesize without printing article text and atomically publish AAC/M4A audio."""
    normalized = " ".join(text.split())
    if not normalized or len(normalized.encode("utf-8")) > _MAX_TEXT_BYTES:
        raise ArticleVoiceError("invalid_article_text")
    local_home = home or Path.home()
    model_path, reference_path = _paths(local_home, voice_id)
    if output_path.is_symlink():
        raise ArticleVoiceError("invalid_output")
    # macOS hands callers its temporary directories through system-owned aliases.
    # Normalize just those prefixes so symlinks beneath them are still rejected.
    output_path = output_path.absolute()
    if sys.platform == "darwin" and output_path.parts[1:2] in (("var",), ("tmp",)):
        output_path = Path("/private").joinpath(*output_path.parts[1:])
    if output_path.parent.resolve() != output_path.parent:
        raise ArticleVoiceError("invalid_output")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    temporary_path: Path | None = None
    try:
        with _gpu_admission(model_path, lock_path, progress):
            progress("loading", 0.05)
            with contextlib.redirect_stdout(io.StringIO()):
                model = model_loader(model_path)
            progress("synthesizing", 0.1)
            generated = model.generate(normalized, ref_audio=str(reference_path))
            segments = _quiet_segments(generated, progress)
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{output_path.name}.", suffix=".m4a", dir=output_path.parent
            )
            os.fchmod(descriptor, 0o600)
            os.close(descriptor)
            temporary_path = Path(temporary_name)
            sample_rate, duration_ms = audio_writer(temporary_path, segments, progress)
            if normalize_loudness:
                normalizer = loudness_normalizer or _normalize_loudness
                descriptor, normalized_name = tempfile.mkstemp(
                    prefix=f".{output_path.name}.levelled.", suffix=".m4a", dir=output_path.parent
                )
                os.fchmod(descriptor, 0o600)
                os.close(descriptor)
                normalized_path = Path(normalized_name)
                normalized_path.unlink()
                try:
                    metrics, _reason = normalizer(temporary_path, normalized_path)
                except BaseException:
                    normalized_path.unlink(missing_ok=True)
                    raise
                if metrics is None or not normalized_path.is_file():
                    normalized_path.unlink(missing_ok=True)
                    raise ArticleVoiceError("loudness_normalization_failed")
                os.chmod(normalized_path, 0o600)
                temporary_path.unlink()
                temporary_path = normalized_path
            progress("saving", 0.95)
            size = temporary_path.stat().st_size
            if size <= 44 or size > _MAX_OUTPUT_BYTES:
                raise ArticleVoiceError("invalid_audio")
            os.replace(temporary_path, output_path)
            temporary_path = None
            progress("ready", 1.0)
            return sample_rate, duration_ms
    except ArticleVoiceError:
        raise
    except (OSError, ValueError, RuntimeError, ImportError) as error:
        raise ArticleVoiceError("synthesis_failed") from error
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def _normalize_loudness(audio_path: Path, output_path: Path) -> tuple[dict[str, float] | None, str | None]:
    """Use the podcast worker's measured loudness target and peak protection."""
    from wilted_worker.loudness import normalize_short

    return normalize_short(audio_path, output_path)


def _read_text(path: Path) -> str:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            status = os.fstat(source.fileno())
            if not stat.S_ISREG(status.st_mode) or status.st_size > _MAX_TEXT_BYTES:
                raise ArticleVoiceError("invalid_article_text")
            data = source.read(_MAX_TEXT_BYTES + 1)
            if len(data) > _MAX_TEXT_BYTES:
                raise ArticleVoiceError("invalid_article_text")
            return data.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise ArticleVoiceError("invalid_article_text") from error


def _emit(event: str, **values: object) -> None:
    print(json.dumps({"event": event, **values}, separators=(",", ":")), flush=True)


def _terminate(signum: int, _frame: Any) -> None:
    active = _active_encoder
    if active is not None and active.poll() is None:
        active.terminate()
        active.wait()
    raise SystemExit(128 + signum)


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="wilted-article-voice")
    subcommands = parser.add_subparsers(dest="command", required=True)
    availability = subcommands.add_parser("availability")
    availability.add_argument("--voice-id", required=True)
    command = subcommands.add_parser("synthesize")
    command.add_argument("--voice-id", required=True)
    command.add_argument("--text-file", type=Path, required=True)
    command.add_argument("--output", type=Path, required=True)
    command.add_argument("--normalize-loudness", action="store_true")
    args = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, _terminate)
    try:
        if args.command == "availability":
            voice_availability(Path.home(), args.voice_id)
            _emit("availability", ready=True)
            return 0
        text = _read_text(args.text_file)
        sample_rate, duration_ms = synthesize(
            text,
            args.voice_id,
            args.output,
            progress=lambda stage, fraction: _emit("progress", stage=stage, fraction=fraction),
            normalize_loudness=args.normalize_loudness,
        )
        _emit("complete", sampleRate=sample_rate, durationMilliseconds=duration_ms)
        return 0
    except ArticleVoiceError as error:
        _emit("error", code=error.code)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
