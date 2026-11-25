from __future__ import annotations

import contextlib
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

from wilted.article_voice import ArticleVoiceError, _read_text, _write_m4a_stream, synthesize, voice_availability


class Samples:
    shape = (24_000,)

    def tolist(self) -> list[float]:
        return [0.0] * self.shape[0]


class FakeModel:
    def __init__(self, text: str, reference: str) -> None:
        self.text = text
        self.reference = reference

    def generate(self, text: str, *, ref_audio: str):
        self.text = text
        self.reference = ref_audio
        yield SimpleNamespace(audio=Samples(), sample_rate=24_000)


def configured_home(tmp_path: Path) -> tuple[Path, Path, Path]:
    home = tmp_path / "home"
    model = home / "Documents/Projects/chatterbox/models/chatterbox-turbo-8bit"
    references = home / "Documents/Projects/chatterbox/reference-audio/prepared"
    model.mkdir(parents=True)
    references.mkdir(parents=True)
    (model / "model.safetensors").write_bytes(b"model fixture")
    (model / "config.json").write_text("{}", encoding="utf-8")
    (references / "casey-reference.wav").write_bytes(b"voice fixture")
    return home, model, references


def test_availability_reports_only_explicit_supported_voice(tmp_path: Path) -> None:
    home, _, _ = configured_home(tmp_path)

    assert voice_availability(home, "casey-kasem")
    with pytest.raises(ArticleVoiceError, match="unsupported_voice"):
        voice_availability(home, "af-heart")
    with pytest.raises(ArticleVoiceError, match="missing_voice"):
        voice_availability(home, "wolfman-jack")


@pytest.mark.parametrize("system_alias", [False, True])
def test_synthesis_uses_local_voice_and_atomically_writes_private_audio(tmp_path: Path, system_alias: bool) -> None:
    home, model_path, references = configured_home(tmp_path)
    lock = tmp_path / "gpu.lock"
    output = tmp_path / "private" / "story.m4a"
    if system_alias:
        canonical = output.resolve()
        if sys.platform != "darwin" or not canonical.is_relative_to("/private/var"):
            pytest.skip("requires the macOS system temporary directory")
        output = Path("/var") / canonical.relative_to("/private/var")
    observed: dict[str, object] = {}

    def load(path: Path) -> FakeModel:
        observed["model_path"] = path
        return FakeModel("", "")

    def write(path: Path, segments, progress) -> tuple[int, int]:
        segment = next(iter(segments))
        observed["sample_rate"] = segment.sample_rate
        observed["samples"] = segment.audio
        progress("synthesizing", None)
        path.write_bytes(b"M4A!" + b"\x00" * 80)
        return segment.sample_rate, 1_000

    events: list[tuple[str, float | None]] = []
    sample_rate, duration_ms = synthesize(
        "  Article   text. ",
        "casey-kasem",
        output,
        home=home,
        lock_path=lock,
        model_loader=load,
        audio_writer=write,
        progress=lambda stage, fraction: events.append((stage, fraction)),
    )

    assert sample_rate == 24_000
    assert duration_ms == 1_000
    assert observed["model_path"] == model_path
    assert observed["sample_rate"] == 24_000
    assert output.read_bytes().startswith(b"M4A!")
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    assert lock.exists()
    assert ("loading", 0.05) in events
    assert ("synthesizing", 0.1) in events
    assert ("ready", 1.0) in events
    assert str(references / "casey-reference.wav") not in repr(events)


def test_synthesis_uses_daemon_draining_gpu_gate_and_hides_gate_details(monkeypatch, tmp_path: Path) -> None:
    home, model_path, _ = configured_home(tmp_path)
    observed: dict[str, object] = {}
    gate_module = ModuleType("wilted_worker.gpu_admission")

    @contextlib.contextmanager
    def prepare(model: str, *, aligned_stt: bool, progress):
        observed["model"] = model
        observed["aligned_stt"] = aligned_stt
        progress("ads.model.wait", "private article text must not escape")
        yield

    gate_module.prepare_ad_model_lock = prepare
    worker_package = ModuleType("wilted_worker")
    worker_package.__path__ = []
    monkeypatch.setitem(sys.modules, "wilted_worker", worker_package)
    monkeypatch.setitem(sys.modules, "wilted_worker.gpu_admission", gate_module)
    events: list[tuple[str, float | None]] = []

    def write(path: Path, segments, _progress) -> tuple[int, int]:
        next(iter(segments))
        path.write_bytes(b"M4A!" + b"\x00" * 80)
        return 44_100, 1_000

    synthesize(
        "private article body",
        "casey-kasem",
        tmp_path / "story.m4a",
        home=home,
        model_loader=lambda _path: FakeModel("", ""),
        audio_writer=write,
        progress=lambda stage, fraction: events.append((stage, fraction)),
    )

    assert observed == {"model": str(model_path), "aligned_stt": False}
    assert ("loading", None) in events
    assert "private article text must not escape" not in repr(events)


def test_failed_synthesis_keeps_previous_complete_file(tmp_path: Path) -> None:
    home, _, _ = configured_home(tmp_path)
    output = tmp_path / "story.m4a"
    output.write_bytes(b"previous-complete-audio")

    class FailingModel:
        def generate(self, text: str, *, ref_audio: str):
            raise RuntimeError("private article text must not be logged")

    with pytest.raises(ArticleVoiceError, match="synthesis_failed"):
        synthesize(
            "private article body",
            "casey-kasem",
            output,
            home=home,
            lock_path=tmp_path / "gpu.lock",
            model_loader=lambda _path: FailingModel(),
            audio_writer=lambda *_: pytest.fail("audio must not be written after synthesis fails"),
        )

    assert output.read_bytes() == b"previous-complete-audio"
    assert not list(tmp_path.glob(".story.m4a.*.wav"))


def test_output_rejects_user_symlinks_before_creating_directories(tmp_path: Path) -> None:
    home, _, _ = configured_home(tmp_path)
    target = tmp_path / "elsewhere"
    target.mkdir()
    alias = tmp_path / "alias"
    alias.symlink_to(target, target_is_directory=True)
    with pytest.raises(ArticleVoiceError, match="invalid_output"):
        synthesize("text", "casey-kasem", alias / "new" / "story.m4a", home=home)
    assert not (target / "new").exists()


def test_text_input_rejects_symlink_and_large_file(tmp_path: Path) -> None:
    text = tmp_path / "article.txt"
    text.write_text("article", encoding="utf-8")
    assert _read_text(text) == "article"

    alias = tmp_path / "alias.txt"
    alias.symlink_to(text)
    with pytest.raises(ArticleVoiceError, match="invalid_article_text"):
        _read_text(alias)


def test_cli_reports_unreadable_input_without_disclosing_its_path(tmp_path: Path) -> None:
    page = tmp_path / "private-story"
    argv = [
        "synthesize", "--text-file", str(page), "--output", str(tmp_path / "voice.m4a"),
        "--voice-id", "casey-kasem",
    ]
    for contents in [None, b"\xff"]:
        if contents is not None:
            page.write_bytes(contents)
        result = subprocess.run([sys.executable, "-m", "wilted.article_voice", *argv],
                                capture_output=True, text=True, timeout=10, check=False)
        assert result.returncode == 3
        assert result.stdout.strip() == '{"event":"error","code":"invalid_article_text"}'
        assert not result.stderr


def test_synthesis_rejects_oversized_article_before_model_load(tmp_path: Path) -> None:
    home, _, _ = configured_home(tmp_path)
    calls = 0

    def load(_path: Path) -> FakeModel:
        nonlocal calls
        calls += 1
        return FakeModel("", "")

    with pytest.raises(ArticleVoiceError, match="invalid_article_text"):
        synthesize(
            "x" * (2 * 1024 * 1024 + 1),
            "casey-kasem",
            tmp_path / "story.m4a",
            home=home,
            lock_path=tmp_path / "gpu.lock",
            model_loader=load,
        )
    assert calls == 0


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is required by the local article media path")
def test_encoder_streams_segments_to_bounded_m4a(tmp_path: Path) -> None:
    output = tmp_path / "story.m4a"
    segment = SimpleNamespace(audio=[0.0] * 2_400, sample_rate=24_000)
    events: list[tuple[str, float | None]] = []

    sample_rate, duration_ms = _write_m4a_stream(
        output,
        [segment],
        lambda stage, fraction: events.append((stage, fraction)),
    )

    content = output.read_bytes()
    assert content[4:8] == b"ftyp"
    assert sample_rate == segment.sample_rate
    assert 80 <= duration_ms <= 120
    assert output.stat().st_size < 100_000
    assert events == []


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg is required by the local article media path")
def test_short_narration_uses_podcast_loudness_target_and_peak_ceiling(monkeypatch, tmp_path: Path) -> None:
    worker_directory = Path(__file__).parents[2] / "Workers"
    monkeypatch.syspath_prepend(str(worker_directory))
    from wilted_worker import cue_timing, loudness

    home, _, _ = configured_home(tmp_path)
    output = tmp_path / "private" / "story.m4a"

    def quiet_audio(path: Path, segments, _progress) -> tuple[int, int]:
        next(iter(segments))
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
             "-af", "volume=-35dB", "-ar", "24000", "-c:a", "aac", "-b:a", "96k",
             "-movflags", "+faststart", str(path)],
            check=True, timeout=30,
        )
        return 24_000, 8_000

    synthesize(
        "Short bulletin",
        "casey-kasem",
        output,
        home=home,
        lock_path=tmp_path / "gpu.lock",
        model_loader=lambda _path: FakeModel("", ""),
        audio_writer=quiet_audio,
        normalize_loudness=True,
    )

    integrated, true_peak = loudness.measure(output)
    assert abs(integrated - loudness.TARGET_I) <= 1.0
    assert true_peak <= loudness.TARGET_TP + 0.1
    assert abs(cue_timing.probe_duration(output) - 8.0) <= 0.05
    assert loudness._probe_sample_rate(output) == 24_000
    assert stat.S_IMODE(output.stat().st_mode) == 0o600


def test_requested_loudness_failure_does_not_publish_audio(tmp_path: Path) -> None:
    home, _, _ = configured_home(tmp_path)
    output = tmp_path / "story.m4a"
    output.write_bytes(b"previous complete audio")

    def write(path: Path, segments, _progress) -> tuple[int, int]:
        next(iter(segments))
        path.write_bytes(b"M4A!" + b"\x00" * 80)
        return 24_000, 1_000

    with pytest.raises(ArticleVoiceError, match="loudness_normalization_failed"):
        synthesize(
            "Short bulletin",
            "casey-kasem",
            output,
            home=home,
            lock_path=tmp_path / "gpu.lock",
            model_loader=lambda _path: FakeModel("", ""),
            audio_writer=write,
            normalize_loudness=True,
            loudness_normalizer=lambda *_: (None, "loudness-measure-failed"),
        )

    assert output.read_bytes() == b"previous complete audio"
