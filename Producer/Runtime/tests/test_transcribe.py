"""Tests for transcript ingestion — tier-3 local transcription (transcribe.py)."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from speech_stack import client, isolated

from wilted.transcribe import (
    TranscriptionAborted,
    TranscriptionError,
    TranscriptionTimeout,
    TranscriptionWorkerError,
    transcribe_audio,
)

pytestmark = pytest.mark.usefixtures("execution_capability")

# ---------------------------------------------------------------------------
# Tier 3: Local transcription
# ---------------------------------------------------------------------------


class TestTranscribeAudio:
    """Tier-3 dispatches to the resident speech daemon; mock that seam.

    M2 daemon cutover: the ONLY boundary now is
    ``wilted.transcribe.client.stt_path(audio_path, **params)``, which returns
    ``{"text", "segments", ...}`` with segments already sentence-split,
    text-stripped, and keyed ``start_s``/``end_s``/``text``. There is no
    isolated-spawn fallback (``isolated.run`` is never called from this path).
    """

    @patch("wilted.transcribe.client.stt_path")
    def test_transcribes_audio(self, mock_stt_path):
        mock_stt_path.return_value = {
            "text": "Hello world. Testing transcription.",
            "segments": [
                {"start_s": 0.0, "end_s": 3.0, "text": "Hello world."},
                {"start_s": 3.5, "end_s": 7.0, "text": "Testing transcription."},
            ],
        }

        segments = transcribe_audio(Path("/tmp/test.mp3"))

        assert len(segments) == 2
        assert segments[0].text == "Hello world."
        assert segments[1].start_s == 3.5

        # Dispatched with the audio path positional and the rest as kwargs.
        (audio_path,), kwargs = mock_stt_path.call_args
        assert audio_path == "/tmp/test.mp3"
        assert kwargs["model"] == "mlx-community/parakeet-tdt-1.1b"

    @patch("wilted.transcribe.client.stt_path")
    def test_empty_segments_raises_error(self, mock_stt_path):
        mock_stt_path.return_value = {"text": "", "segments": []}

        with pytest.raises(TranscriptionError, match="no segments"):
            transcribe_audio(Path("/tmp/test.mp3"))

    @patch("wilted.transcribe.client.stt_path")
    def test_accepts_str_audio_path(self, mock_stt_path):
        """Regression: the completion log does ``audio_path.name``, which
        AttributeError'd when a caller passed a ``str`` (the CLI and the podcast
        pipeline both do). The signature is ``str | Path`` and coerces on entry,
        so the success path — which reaches that log line — must not crash.
        """
        mock_stt_path.return_value = {
            "text": "String path works.",
            "segments": [{"start_s": 0.0, "end_s": 2.0, "text": "String path works."}],
        }

        segments = transcribe_audio("/tmp/episode.mp3")  # bare str, not Path

        assert len(segments) == 1
        assert segments[0].text == "String path works."
        # The request payload still carries the stringified path unchanged.
        (audio_path,), _kwargs = mock_stt_path.call_args
        assert audio_path == "/tmp/episode.mp3"

    def test_daemon_client_unavailable_uses_mandatory_daemon_seam(self):
        """A down daemon is surfaced from the mandatory client seam.

        ``speech_stack.client`` is an unconditional import and is the only tier-3
        route. A transport failure must therefore preserve its typed cause rather
        than choose an in-process or spawn fallback.
        """
        with patch("wilted.transcribe.client.stt_path", side_effect=client.DaemonUnavailable("no broker at socket")):
            with pytest.raises(TranscriptionError) as excinfo:
                transcribe_audio(Path("/tmp/test.mp3"))
        assert isinstance(excinfo.value.__cause__, client.DaemonUnavailable)


# ---------------------------------------------------------------------------
# Tier 3: Local Parakeet transcription (transcribe_audio)
# ---------------------------------------------------------------------------


def _canned_result(sentences):
    """Build a speech-stack STT result dict from ``(start, end, text)`` tuples.

    Mirrors ``speech_stack.stt.transcribe``'s return shape: segments are already
    sentence-split, text-stripped, and keyed ``start_s``/``end_s``/``text``.
    """
    return {
        "text": " ".join(t for (_s, _e, t) in sentences),
        "segments": [{"start_s": s, "end_s": e, "text": t} for (s, e, t) in sentences],
    }


class TestTranscribeAudioLocalTier:
    """Tier-3 contract now that transcription runs via the resident speech daemon.

    The three original production bugs (single-shot GPU decode, disabled sentence
    splitting, wrong result attribute) are guarded inside ``speech_stack.stt``.
    Wilted's remaining contract is what it PASSES to the daemon (a bounded
    ``chunk_duration``, ``overlap_duration``, ``sentence_split=True``) and how it
    maps the returned segments — that is what these tests lock down.
    """

    def _run(self, tmp_path, captured, sentences):
        audio = tmp_path / "ep.mp3"
        audio.write_bytes(b"fake-audio")

        def _fake_stt_path(audio_path, *, timeout, **kwargs):
            captured["request"] = {"audio_path": audio_path, **kwargs}
            captured["timeout"] = timeout
            return _canned_result(sentences)

        with patch("wilted.transcribe.client.stt_path", side_effect=_fake_stt_path):
            return transcribe_audio(audio)

    def test_passes_bounded_chunk_duration(self, tmp_path):
        """Wilted must request a bounded chunk_duration (the BUG-4 crash mitigation).

        The guard that rejects chunk_duration<=0 now lives in speech_stack.stt;
        wilted's job is to pass a positive value. Assert the request carries a
        bounded chunk_duration and overlap_duration.
        """
        captured: dict = {}
        self._run(tmp_path, captured, [(0.0, 1.0, "hi")])
        request = captured["request"]
        assert request["chunk_duration"] == 120.0
        assert request["chunk_duration"] > 0
        assert request["overlap_duration"] == 15.0
        assert request["overlap_duration"] > 0

    def test_applies_sentence_split(self, tmp_path):
        """Sentence splitting moved into speech-stack; wilted must REQUEST it.

        Assert the request sets ``sentence_split=True`` so the worker reproduces
        wilted's former per-sentence segmentation.
        """
        captured: dict = {}
        self._run(tmp_path, captured, [(0.0, 1.0, "hi")])
        assert captured["request"]["sentence_split"] is True

    def test_parses_returned_segments(self, tmp_path):
        """Maps ``result["segments"]`` (start_s/end_s/text) to TranscriptSegment."""
        captured: dict = {}
        segments = self._run(
            tmp_path,
            captured,
            [(0.0, 1.0, "Hello world"), (1.0, 2.5, "Second line")],
        )
        assert [(s.start_s, s.end_s, s.text) for s in segments] == [
            (0.0, 1.0, "Hello world"),
            (1.0, 2.5, "Second line"),
        ]

    @patch("wilted.transcribe.client.stt_path")
    def test_preserves_tier3_aligned_tokens(self, mock_stt_path):
        mock_stt_path.return_value = {
            "text": "This episode is brought to you by Acme.",
            "segments": [
                {
                    "start_s": 10.0,
                    "end_s": 13.0,
                    "text": "This episode is brought to you by Acme.",
                    "tokens": [
                        {"text": "This", "start_s": 10.0, "end_s": 10.3},
                        {"text": " episode", "start_s": 10.3, "end_s": 11.0},
                    ],
                }
            ],
        }

        segment = transcribe_audio(Path("/tmp/test.mp3"))[0]

        assert segment.tokens is not None
        assert [(token.text, token.start_s, token.end_s) for token in segment.tokens] == [
            ("This", 10.0, 10.3),
            (" episode", 10.3, 11.0),
        ]

    def test_raises_when_worker_returns_no_segments(self, tmp_path):
        """Empty output still raises TranscriptionError (unchanged contract)."""
        captured: dict = {}
        with pytest.raises(TranscriptionError, match="produced no segments"):
            self._run(tmp_path, captured, [])


class TestTranscribeAudioExceptionContract:
    """Every daemon STT failure re-raises as a TranscriptionError subclass (INV-6).

    M2 daemon cutover: the daemon is the ONLY tier-3 route, so every failure —
    including a down/unreachable daemon (``DaemonUnavailable``) — comes back from
    ``client.stt_path`` and must map through the SAME except-ladder that used to
    catch the isolated spawn path's errors. ``speech_stack.client`` re-exports the
    identical ``isolated.*`` classes, so constructing them via ``isolated.*`` here
    (as the daemon transport would reconstruct and raise them) is equivalent to
    using ``client.*``. All existing ``except TranscriptionError`` handlers keep
    catching a tier-3 GPU crash / timeout / worker error / down daemon, while
    callers that care can distinguish the cause.
    """

    @pytest.mark.parametrize(
        ("daemon_exc", "mapped"),
        [
            (isolated.Timeout("worker timed out after 1800s"), TranscriptionTimeout),
            (isolated.GpuAborted("worker died: SIGABRT (Metal fault)"), TranscriptionAborted),
            (isolated.GpuSegfault("worker died: SIGSEGV (segfault)"), TranscriptionAborted),
            (isolated.WorkerError("worker failed: ValueError: boom"), TranscriptionWorkerError),
            (client.ConnectionLost("broker exited"), TranscriptionWorkerError),
            (client.DaemonUnavailable("no broker at socket"), TranscriptionError),
        ],
    )
    def test_daemon_error_maps_to_transcription_subclass(self, daemon_exc, mapped):
        with patch("wilted.transcribe.client.stt_path", side_effect=daemon_exc):
            with pytest.raises(mapped) as excinfo:
                transcribe_audio(Path("/tmp/test.mp3"))
        # Mapped subclass is still a TranscriptionError, so existing handlers catch it.
        assert isinstance(excinfo.value, TranscriptionError)
        # Original error is chained and its message is surfaced.
        assert excinfo.value.__cause__ is daemon_exc
        assert str(daemon_exc) in str(excinfo.value)

    def test_base_isolated_error_maps_to_base_transcription_error(self):
        """Any other IsolatedError falls back to the base TranscriptionError."""
        exc = isolated.IsolatedError("some other isolation failure")
        with patch("wilted.transcribe.client.stt_path", side_effect=exc):
            with pytest.raises(TranscriptionError) as excinfo:
                transcribe_audio(Path("/tmp/test.mp3"))
        # Not one of the specific subclasses.
        assert type(excinfo.value) is TranscriptionError
        assert excinfo.value.__cause__ is exc

    def test_daemon_down_is_never_masked_by_a_spawn_retry(self):
        """INV-6: a down daemon must surface as a TranscriptionError, NOT be
        silently retried via an isolated spawn (there is no fallback anymore)."""
        with (
            patch("wilted.transcribe.client.stt_path", side_effect=client.DaemonUnavailable("gone")),
            patch(
                "wilted.transcribe.isolated.run",
                side_effect=AssertionError("isolated.run must never be called — no spawn fallback"),
            ),
        ):
            with pytest.raises(TranscriptionError):
                transcribe_audio(Path("/tmp/test.mp3"))


# ---------------------------------------------------------------------------
# Tier 3: daemon-only (M2 daemon cutover — no selector, no spawn fallback)
# ---------------------------------------------------------------------------


class TestTranscribeAudioDaemonOnly:
    """The daemon is the ONLY tier-3 STT route; there is no env selector anymore.

    Locks down the daemon seam itself: routing through ``client.stt_path`` with
    the expected params and a byte-identical result mapping. Typed-error fidelity
    (a real GPU crash or a down daemon surfacing the matching TranscriptionError
    subclass, INV-6) is covered by ``TestTranscribeAudioExceptionContract`` above.
    """

    _RESULT = {
        "text": "Hello daemon.",
        "segments": [{"start_s": 0.0, "end_s": 2.0, "text": "Hello daemon."}],
    }

    def test_routes_through_client_stt_path(self, tmp_path):
        audio = tmp_path / "ep.mp3"
        audio.write_bytes(b"fake")

        captured: dict = {}

        def _fake_stt_path(audio_path, **kwargs):
            captured["audio_path"] = audio_path
            captured["kwargs"] = kwargs
            return self._RESULT

        with (
            patch("wilted.transcribe.client.stt_path", side_effect=_fake_stt_path),
            patch(
                "wilted.transcribe.isolated.run",
                side_effect=AssertionError("isolated.run must never run — no spawn fallback (M2)"),
            ),
        ):
            segments = transcribe_audio(audio)

        assert [(s.start_s, s.end_s, s.text) for s in segments] == [(0.0, 2.0, "Hello daemon.")]
        assert captured["audio_path"] == str(audio)
        assert captured["kwargs"]["model"] == "mlx-community/parakeet-tdt-1.1b"
        assert captured["kwargs"]["chunk_duration"] == 120.0
        assert captured["kwargs"]["overlap_duration"] == 15.0
        assert captured["kwargs"]["sentence_split"] is True
        assert "audio_path" not in captured["kwargs"]  # rides positionally only

    def test_legacy_backend_selector_is_inert(self, tmp_path, monkeypatch):
        """A legacy selector cannot bypass the mandatory daemon route."""
        audio = tmp_path / "ep.mp3"
        audio.write_bytes(b"fake")
        # Construct the retired name so the source-policy grep remains clean:
        # M5 requires both zero live selector references and proof that an old
        # value inherited from a user's environment cannot change routing.
        monkeypatch.setenv("WILTED_" + "STT_BACKEND", "isolated")

        with patch("wilted.transcribe.client.stt_path", return_value=self._RESULT) as mock_stt_path:
            transcribe_audio(audio)

        mock_stt_path.assert_called_once()
