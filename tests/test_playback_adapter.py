"""Tests for ``wilted.station_runtime.playback_adapter.MacPlaybackAdapter``.

Deterministic, hardware-free: a small FAKE engine (``_FakeEngine``) stands in
for ``wilted.engine.AudioEngine`` so tests can assert exactly what the
adapter fed it, without touching sounddevice/ffmpeg/a real audio device.

Covers (see Task 3.2):
  - ms -> s conversion is exact and happens in the adapter, not the caller.
  - offset_ms -> start_segment mapping (boundary, mid-segment, zero, empty).
  - resume: play(media, offset_ms=T) drives play_file with the right
    start_segment / seek target.
  - truncated decode (PM-10) does not report ended/complete; full playback
    does.
  - no ``set_resume_position`` call anywhere on the station path.
  - current_offset_ms() reflects playback_time_s * 1000, rounded.
  - pause()/stop() delegate correctly; stop() joins/cleans the stream thread.
"""

from __future__ import annotations

import logging
import threading
import time
import unittest.mock

import pytest

from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    SafeInterruptionMap,
    TranscriptSegment,
)
from wilted.station_runtime import media_store
from wilted.station_runtime.playback_adapter import (
    CompletionReason,
    MacPlaybackAdapter,
    MediaNotAvailableError,
    _start_segment_for_offset,
    _to_engine_segments,
)

# ---------------------------------------------------------------------------
# Shared builders (mirrors tests/test_station_controller.py's patterns)
# ---------------------------------------------------------------------------


def _finalized_media(**overrides) -> MediaDescriptor:
    defaults = dict(
        sha256="a" * 64,
        byte_size=1024,
        mime_type="audio/mpeg",
        duration_ms=60_000,
        transcript_segments=(),
        safe_interruption=SafeInterruptionMap.empty(),
        byte_range_available=False,
        finalization=FinalizationState.complete(),
    )
    defaults.update(overrides)
    return MediaDescriptor(**defaults)


def _segments() -> tuple[TranscriptSegment, ...]:
    """Four segments at clean ms boundaries: 0, 2000, 5000, 9000."""
    return (
        TranscriptSegment(start_ms=0, end_ms=2000, text="seg0"),
        TranscriptSegment(start_ms=2000, end_ms=5000, text="seg1"),
        TranscriptSegment(start_ms=5000, end_ms=9000, text="seg2"),
        TranscriptSegment(start_ms=9000, end_ms=12000, text="seg3"),
    )


def _publish_media(tmp_path, *, sha256: str = "b" * 64, content: bytes = b"fake mp3 bytes") -> str:
    """Publish real bytes into the (isolated_data-redirected) media store."""
    src = tmp_path / "src.bin"
    src.write_bytes(content)
    return media_store.publish_file(src)


# ---------------------------------------------------------------------------
# Fake engine — records calls, lets tests control playback_time_s/duration.
# ---------------------------------------------------------------------------


class _FakeEngine:
    """Deterministic stand-in for ``wilted.engine.AudioEngine``.

    ``play_file`` records its arguments and blocks on ``_release`` (an Event)
    so tests can control exactly when the background thread's call returns,
    then sets ``playback_time_s`` to whatever the test configured before
    releasing. ``get_file_duration`` returns a fixed, test-controlled value.
    """

    def __init__(self, *, file_duration_s: float = 10.0) -> None:
        self.play_file_calls: list[dict] = []
        self.pause_calls = 0
        self.resume_calls = 0
        self.stop_calls = 0
        self.raise_on_duration = False  # make get_file_duration raise (probe failure)
        self._file_duration_s = file_duration_s
        self._release = threading.Event()
        # What playback_time_s should read once play_file "finishes" (i.e.
        # once _release fires). Defaults to matching the file duration (a
        # full, non-truncated playthrough).
        self.final_playback_time_s = file_duration_s
        self.playback_time_s = 0.0
        self._stop_event = threading.Event()
        # Concurrency instrumentation: track how many play_file bodies are
        # live at once so a test can prove the adapter never double-plays.
        self._concurrency_lock = threading.Lock()
        self._active = 0
        self.max_concurrent = 0

    def play_file(self, path, transcript_segments=None, start_segment=0, on_progress=None) -> None:
        # Mirror the real AudioEngine.play_file preamble (engine.py:480): a
        # fresh play_file resets the stop/release state, so a preceding stop()
        # (e.g. a preempt from a new play()) does not instantly abort this new
        # playback. Without this, preempt-then-relaunch could never start.
        self._stop_event.clear()
        self._release.clear()
        with self._concurrency_lock:
            self._active += 1
            self.max_concurrent = max(self.max_concurrent, self._active)
        try:
            self.play_file_calls.append(
                {
                    "path": path,
                    "transcript_segments": transcript_segments,
                    "start_segment": start_segment,
                }
            )
            # Reflect the seek target immediately (mirrors real AudioEngine
            # setting _playback_time_s to the seek time at call start).
            if transcript_segments and start_segment > 0:
                self.playback_time_s = transcript_segments[start_segment].start_s
            # Block until released (by stop() or the test) or a stop is requested.
            while not self._release.is_set() and not self._stop_event.is_set():
                time.sleep(0.005)
            if not self._stop_event.is_set():
                self.playback_time_s = self.final_playback_time_s
        finally:
            with self._concurrency_lock:
                self._active -= 1

    def get_file_duration(self, path) -> float:
        if self.raise_on_duration:
            raise RuntimeError("ffprobe unavailable")
        return self._file_duration_s

    def pause(self) -> None:
        self.pause_calls += 1

    def resume(self) -> None:
        self.resume_calls += 1

    def stop(self) -> None:
        self.stop_calls += 1
        self._stop_event.set()
        self._release.set()

    def release_play_file(self) -> None:
        """Test helper: let a blocked play_file call return normally."""
        self._release.set()


def _wait_until(predicate, *, timeout=5.0, interval=0.01) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


# ---------------------------------------------------------------------------
# ms -> s conversion (PM-1)
# ---------------------------------------------------------------------------


def test_to_engine_segments_converts_ms_to_s_exactly():
    segments = _segments()
    engine_segments = _to_engine_segments(segments)

    assert len(engine_segments) == len(segments)
    for station_seg, engine_seg in zip(segments, engine_segments, strict=True):
        assert engine_seg.start_s == station_seg.start_ms / 1000.0
        assert engine_seg.end_s == station_seg.end_ms / 1000.0
        assert engine_seg.text == station_seg.text


def test_to_engine_segments_empty_input():
    assert _to_engine_segments(()) == []


def test_play_feeds_engine_converted_segments(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256, transcript_segments=_segments())
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    call = engine.play_file_calls[0]
    fed_segments = call["transcript_segments"]
    assert len(fed_segments) == 4
    assert fed_segments[1].start_s == 2.0
    assert fed_segments[2].start_s == 5.0

    adapter.stop()


# ---------------------------------------------------------------------------
# offset_ms -> start_segment mapping
# ---------------------------------------------------------------------------


def test_start_segment_for_offset_zero_returns_zero():
    assert _start_segment_for_offset(_segments(), 0) == 0


def test_start_segment_for_offset_empty_segments_returns_zero():
    assert _start_segment_for_offset((), 5000) == 0


def test_start_segment_for_offset_exact_boundary():
    # offset 5000 lands exactly on segment 2's start_ms -> index 2.
    assert _start_segment_for_offset(_segments(), 5000) == 2


def test_start_segment_for_offset_between_boundaries():
    # offset 6500 is between segment 2 (start 5000) and segment 3 (start
    # 9000) -> the LAST segment whose start_ms <= offset_ms is segment 2.
    assert _start_segment_for_offset(_segments(), 6500) == 2


def test_start_segment_for_offset_before_first_boundary():
    # offset 500 is before segment 1's start (2000) -> segment 0.
    assert _start_segment_for_offset(_segments(), 500) == 0


def test_start_segment_for_offset_at_last_segment():
    assert _start_segment_for_offset(_segments(), 11_000) == 3


def test_start_segment_for_offset_past_end():
    # Offset beyond the last segment's start still snaps to the last segment.
    assert _start_segment_for_offset(_segments(), 999_999) == 3


# ---------------------------------------------------------------------------
# Resume: play(media, offset_ms=T) drives play_file with the right seek.
# ---------------------------------------------------------------------------


def test_play_resume_mid_segment_seeks_to_containing_segment_start(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256, transcript_segments=_segments())
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    # 6500ms falls inside segment 2 (5000-9000) -> start_segment should be 2,
    # and the resulting seek time (mirrored via playback_time_s in the fake)
    # should land on segment 2's start_s (5.0), not 6.5.
    adapter.play(media, offset_ms=6500)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    call = engine.play_file_calls[0]
    assert call["start_segment"] == 2
    assert engine.playback_time_s == 5.0

    adapter.stop()


def test_play_resume_at_zero_uses_start_segment_zero(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256, transcript_segments=_segments())
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    assert engine.play_file_calls[0]["start_segment"] == 0

    adapter.stop()


# ---------------------------------------------------------------------------
# Media resolution via the content-addressed store.
# ---------------------------------------------------------------------------


def test_play_resolves_path_via_media_store(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    expected_path = media_store.path_for(sha256)
    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    assert str(engine.play_file_calls[0]["path"]) == str(expected_path)

    adapter.stop()


def test_play_raises_clear_error_when_media_not_on_disk():
    media = _finalized_media(sha256="c" * 64)  # never published
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    with pytest.raises(MediaNotAvailableError):
        adapter.play(media, offset_ms=0)

    assert engine.play_file_calls == []


# ---------------------------------------------------------------------------
# Truncated-decode guard (PM-10).
# ---------------------------------------------------------------------------


def test_full_playback_reports_ended(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 10.0  # played to the very end
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)
    engine.release_play_file()

    assert _wait_until(lambda: adapter.last_completion is not None)
    assert adapter.last_completion is CompletionReason.ENDED


def test_truncated_decode_does_not_report_ended(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 4.0  # ffmpeg died well short of the end
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)
    engine.release_play_file()

    assert _wait_until(lambda: adapter.last_completion is not None)
    assert adapter.last_completion is CompletionReason.TRUNCATED
    assert adapter.last_completion is not CompletionReason.ENDED


def test_truncation_within_tolerance_still_reports_ended(tmp_path):
    """A shortfall within the decode-granularity tolerance is not truncation."""
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 9.0  # 1s short — within the ~2s tolerance
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)
    engine.release_play_file()

    assert _wait_until(lambda: adapter.last_completion is not None)
    assert adapter.last_completion is CompletionReason.ENDED


def test_explicit_stop_reports_stopped_not_truncated(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 4.0  # would look truncated if not for stop()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    adapter.stop()

    assert adapter.last_completion is CompletionReason.STOPPED


def test_probe_failure_reports_unknown_not_ended(tmp_path):
    """If get_file_duration raises (ffprobe missing/broken), completeness is
    unverifiable -> UNKNOWN, never ENDED — so a caller does not auto-advance
    past what may have been a truncated decode."""
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 10.0  # would be ENDED if the duration were known
    engine.raise_on_duration = True  # ffprobe fails -> duration unverifiable
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)
    engine.release_play_file()

    assert _wait_until(lambda: adapter.last_completion is not None)
    assert adapter.last_completion is CompletionReason.UNKNOWN
    assert not adapter.last_completion.is_clean_completion


def test_is_clean_completion_only_true_for_ended():
    assert CompletionReason.ENDED.is_clean_completion is True
    assert CompletionReason.TRUNCATED.is_clean_completion is False
    assert CompletionReason.UNKNOWN.is_clean_completion is False
    assert CompletionReason.STOPPED.is_clean_completion is False


# ---------------------------------------------------------------------------
# Preemption: play() while playing / after pause() must not double-play or wedge.
# ---------------------------------------------------------------------------


def test_play_while_playing_preempts_prior_playback(tmp_path):
    """play() called while a prior playback is live (the A.4 interrupt flow)
    must stop+join the old play_file before starting the new one — never run
    two play_file bodies on the shared engine at once."""
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256, transcript_segments=_segments())
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    assert _wait_until(lambda: len(engine.play_file_calls) == 1)
    first_thread = adapter._thread

    adapter.play(media, offset_ms=0)
    assert _wait_until(lambda: len(engine.play_file_calls) == 2)

    assert engine.max_concurrent == 1  # never two play_file bodies concurrently
    assert first_thread is not None and not first_thread.is_alive()  # old thread joined
    assert engine.stop_calls == 1  # exactly one preempt stop (the FIRST play did not stop)

    adapter.stop()


def test_pause_then_play_stops_engine_before_relaunch(tmp_path):
    """The only resume path after pause() is a fresh play(); it must issue a
    preempting engine.stop() first (which, on the real engine, re-arms the
    pause event so the new stream is not wedged)."""
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    assert _wait_until(lambda: len(engine.play_file_calls) == 1)

    adapter.pause()
    assert engine.pause_calls == 1

    adapter.play(media, offset_ms=0)
    assert _wait_until(lambda: len(engine.play_file_calls) == 2)

    assert engine.stop_calls == 1  # preempting stop issued on the 2nd play
    assert engine.max_concurrent == 1

    adapter.stop()


def test_resume_without_transcript_segments_warns_and_restarts_at_zero(tmp_path, caplog):
    """A resume offset on a no-transcript descriptor can't be honored (no
    segments to seek by) — play_file restarts at 0:00, and the adapter warns
    rather than silently dropping the listener's position."""
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256, transcript_segments=())
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    with caplog.at_level(logging.WARNING, logger="wilted.station_runtime.playback_adapter"):
        adapter.play(media, offset_ms=45_000)
        _wait_until(lambda: len(engine.play_file_calls) == 1)

    assert engine.play_file_calls[0]["start_segment"] == 0  # restarted at 0
    assert any("resume position not honored" in msg for msg in caplog.messages)

    adapter.stop()


# ---------------------------------------------------------------------------
# on_complete completion callback.
# ---------------------------------------------------------------------------


def test_on_complete_fires_once_with_ended_on_clean_completion(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 10.0  # played to the very end
    calls: list[CompletionReason] = []
    adapter = MacPlaybackAdapter(engine=engine, on_complete=calls.append)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)
    engine.release_play_file()

    assert _wait_until(lambda: len(calls) == 1)
    assert calls == [CompletionReason.ENDED]
    assert adapter.last_completion is CompletionReason.ENDED


def test_on_complete_fires_with_truncated_when_playback_falls_short(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 4.0  # ffmpeg died well short of the end
    calls: list[CompletionReason] = []
    adapter = MacPlaybackAdapter(engine=engine, on_complete=calls.append)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)
    engine.release_play_file()

    assert _wait_until(lambda: len(calls) == 1)
    assert calls == [CompletionReason.TRUNCATED]


def test_on_complete_fires_with_unknown_when_duration_probe_raises(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 10.0  # would be ENDED if the duration were known
    engine.raise_on_duration = True  # ffprobe fails -> duration unverifiable
    calls: list[CompletionReason] = []
    adapter = MacPlaybackAdapter(engine=engine, on_complete=calls.append)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)
    engine.release_play_file()

    assert _wait_until(lambda: len(calls) == 1)
    assert calls == [CompletionReason.UNKNOWN]


def test_on_complete_does_not_fire_on_explicit_stop(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 4.0  # would look truncated if not for stop()
    calls: list[CompletionReason] = []
    adapter = MacPlaybackAdapter(engine=engine, on_complete=calls.append)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    adapter.stop()  # joins the background thread; classifier has fully run

    assert adapter.last_completion is CompletionReason.STOPPED
    assert calls == []


def test_on_complete_skips_preempted_session_but_fires_for_new_session(tmp_path):
    """play() while a prior playback is live preempts (STOPPED, no callback)
    the old session; the callback must fire only for the NEW session's own
    completion, mirroring test_play_while_playing_preempts_prior_playback's
    preempt machinery."""
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256, transcript_segments=_segments())
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 10.0
    calls: list[CompletionReason] = []
    adapter = MacPlaybackAdapter(engine=engine, on_complete=calls.append)

    adapter.play(media, offset_ms=0)
    assert _wait_until(lambda: len(engine.play_file_calls) == 1)

    # Preempt: the first session's play_file is still blocked, so this stops
    # + joins it (STOPPED, early-return path, no callback) before the second
    # play_file starts (freshly blocked on the fake's _release event).
    adapter.play(media, offset_ms=0)
    assert _wait_until(lambda: len(engine.play_file_calls) == 2)
    assert calls == []  # preempted session must not have fired

    engine.release_play_file()  # let the NEW session's play_file return

    assert _wait_until(lambda: len(calls) == 1)
    assert calls == [CompletionReason.ENDED]  # exactly the new session's completion
    assert adapter.last_completion is CompletionReason.ENDED

    adapter.stop()


def test_on_complete_exception_is_swallowed_and_last_completion_still_set(tmp_path, caplog):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine(file_duration_s=10.0)
    engine.final_playback_time_s = 10.0

    def _boom(reason: CompletionReason) -> None:
        raise RuntimeError(f"callback exploded for {reason}")

    adapter = MacPlaybackAdapter(engine=engine, on_complete=_boom)

    with caplog.at_level(logging.ERROR, logger="wilted.station_runtime.playback_adapter"):
        adapter.play(media, offset_ms=0)
        _wait_until(lambda: len(engine.play_file_calls) == 1)
        engine.release_play_file()

        assert _wait_until(lambda: adapter.last_completion is not None)

    # A raising callback must not corrupt _last_completion or escape the
    # background thread; the adapter still reports the correct classification.
    assert adapter.last_completion is CompletionReason.ENDED
    assert any("on_complete" in msg for msg in caplog.messages)


# ---------------------------------------------------------------------------
# Single resume authority: no set_resume_position anywhere on this path.
# ---------------------------------------------------------------------------


def test_play_never_calls_set_resume_position(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256, transcript_segments=_segments())
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    with unittest.mock.patch("wilted.playlists.set_resume_position") as mock_set_resume:
        adapter.play(media, offset_ms=6500)
        _wait_until(lambda: len(engine.play_file_calls) == 1)
        adapter.stop()

        mock_set_resume.assert_not_called()


def test_engine_fake_has_no_set_resume_position_attribute():
    """The fake engine itself exposes no such method — nothing could call it."""
    engine = _FakeEngine()
    assert not hasattr(engine, "set_resume_position")


# ---------------------------------------------------------------------------
# current_offset_ms()
# ---------------------------------------------------------------------------


def test_current_offset_ms_reflects_playback_time_s_rounded():
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    engine.playback_time_s = 12.3456
    assert adapter.current_offset_ms() == round(12.3456 * 1000)

    engine.playback_time_s = 0.0
    assert adapter.current_offset_ms() == 0

    engine.playback_time_s = 1.0005
    assert adapter.current_offset_ms() == round(1.0005 * 1000)


# ---------------------------------------------------------------------------
# pause()/stop() delegation and thread cleanup.
# ---------------------------------------------------------------------------


def test_pause_delegates_to_engine():
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.pause()

    assert engine.pause_calls == 1


def test_resume_delegates_to_engine():
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.resume()

    assert engine.resume_calls == 1


def test_stop_delegates_to_engine_and_joins_thread(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    adapter.stop()

    assert engine.stop_calls == 1
    # The background thread must be joined (not left dangling) by the time
    # stop() returns.
    with adapter._lock:
        thread = adapter._thread
    assert thread is not None
    assert not thread.is_alive()


def test_stop_is_safe_to_call_with_no_active_playback():
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.stop()  # must not raise

    assert engine.stop_calls == 1


def test_stop_callable_from_another_thread(tmp_path):
    sha256 = _publish_media(tmp_path)
    media = _finalized_media(sha256=sha256)
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    adapter.play(media, offset_ms=0)
    _wait_until(lambda: len(engine.play_file_calls) == 1)

    stopper_exceptions: list[BaseException] = []

    def _stop_from_other_thread() -> None:
        try:
            adapter.stop()
        except BaseException as exc:  # noqa: BLE001 - surfaced to the test below
            stopper_exceptions.append(exc)

    stopper = threading.Thread(target=_stop_from_other_thread)
    stopper.start()
    stopper.join(timeout=5.0)

    assert not stopper.is_alive()
    assert stopper_exceptions == []
    assert engine.stop_calls == 1


# ---------------------------------------------------------------------------
# Constructor default.
# ---------------------------------------------------------------------------


def test_constructor_defaults_to_real_audio_engine():
    from wilted.engine import AudioEngine

    adapter = MacPlaybackAdapter()
    assert isinstance(adapter._engine, AudioEngine)


# ---------------------------------------------------------------------------
# seek() is explicitly out of scope / unsupported.
# ---------------------------------------------------------------------------


def test_seek_raises_not_implemented():
    engine = _FakeEngine()
    adapter = MacPlaybackAdapter(engine=engine)

    with pytest.raises(NotImplementedError):
        adapter.seek(1000)
