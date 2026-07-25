"""Concrete ``PlaybackAdapter`` wrapping ``wilted.engine.AudioEngine`` for Mac.

Implements the ``wilted.station.protocols.PlaybackAdapter`` Protocol
(play/pause/stop/seek/current_offset_ms) against the pre-existing
``AudioEngine.play_file`` streaming path. This is the concrete station audio
backend that a future checkpoint poller / controller wiring (Task 3.5 / A.4)
will drive; this module does not import or know about the controller.

Two integration risks this module resolves (see
``spikes/integration-seam-2026-07-10/spike.py`` for the throwaway proof this
design is based on):

  PM-1: ``wilted.station.models.TranscriptSegment`` stores integer
      milliseconds (``start_ms``/``end_ms``); ``engine.play_file`` duck-types
      segment objects reading only ``.start_s``/``.end_s``/``.text`` (floats,
      seconds). The millisecond-to-second conversion happens in exactly one
      place: :func:`_to_engine_segments`. No other function in this module
      divides by 1000.

  PM-10: ``play_file`` streams via ffmpeg in a background thread; if ffmpeg
      dies mid-decode, ``play_file`` still returns (raises, actually — but a
      caller polling in a thread must not conflate "the thread finished" with
      "playback reached the end"). :meth:`MacPlaybackAdapter.play` runs
      ``play_file`` on a background thread and inspects
      ``engine.playback_time_s`` against ``engine.get_file_duration`` once
      that thread exits to tell "played to completion" apart from
      "truncated" — see :attr:`MacPlaybackAdapter.last_completion`.
"""

from __future__ import annotations

import logging
import threading
from enum import Enum
from typing import TYPE_CHECKING, NamedTuple, Protocol

from wilted.engine import AudioEngine
from wilted.station_runtime import media_store

if TYPE_CHECKING:
    from collections.abc import Callable

    from wilted.station.models import MediaDescriptor, TranscriptSegment

logger = logging.getLogger(__name__)

_JOIN_TIMEOUT_SECONDS = 5.0
"""Bound on how long a preempting :meth:`MacPlaybackAdapter.play` or
:meth:`MacPlaybackAdapter.stop` waits for the background stream thread to
exit after the engine has been told to stop (which kills any in-flight
ffmpeg, so a wedged read returns at once)."""


class MediaNotAvailableError(RuntimeError):
    """Raised when a :class:`MediaDescriptor`'s content is not on disk.

    ``media_store.path_for`` returns ``None`` (never raises) for an absent
    blob, so this adapter must translate that into an explicit, loud error
    rather than silently no-op'ing playback.
    """


class CompletionReason(Enum):
    """How the most recent :meth:`MacPlaybackAdapter.play` call ended.

    ``ENDED``: playback reached the end of the file (``engine.playback_time_s``
    landed within tolerance of ``engine.get_file_duration``).
    ``TRUNCATED``: the background ``play_file`` thread exited but playback
    fell short of the file's known duration by more than
    :data:`_TRUNCATION_TOLERANCE_S` — ffmpeg died mid-stream (or something
    else cut the decode short). Must NOT be treated as a normal completion:
    no auto-advance, no mark-complete.
    ``UNKNOWN``: the ``play_file`` thread exited but the file's duration could
    not be probed (``get_file_duration`` raised — ffprobe missing/slow/
    nonzero), so completeness is UNVERIFIABLE. Like ``TRUNCATED``, this must
    NOT be treated as a normal completion: with the expected length unknown
    the decode may well have been truncated, and defaulting an unverifiable
    result to "complete" would let a caller auto-advance past a partially
    played file — the exact failure ``TRUNCATED`` exists to prevent.
    ``STOPPED``: :meth:`MacPlaybackAdapter.stop` was called explicitly.
    """

    ENDED = "ended"
    TRUNCATED = "truncated"
    UNKNOWN = "unknown"
    STOPPED = "stopped"

    @property
    def is_clean_completion(self) -> bool:
        """True only for ``ENDED`` — a verified play-to-the-end.

        A caller deciding whether to auto-advance / mark-complete should gate
        on this: ``TRUNCATED`` (verified short), ``UNKNOWN`` (unverifiable),
        and ``STOPPED`` (caller-requested) are all NOT clean completions.
        """
        return self is CompletionReason.ENDED


class _EngineTranscriptSegment(NamedTuple):
    """Duck-typed stand-in for ``transcribe.TranscriptSegment``.

    ``engine.play_file`` only ever reads ``.start_s``/``.end_s``/``.text`` off
    whatever is in ``transcript_segments`` (``engine.py:465,496`` — no
    isinstance check), so this minimal NamedTuple is a faithful, dependency-free
    substitute. Seconds, not milliseconds — see :func:`_to_engine_segments`.
    """

    start_s: float
    end_s: float
    text: str


class _EngineLike(Protocol):
    """The subset of ``AudioEngine`` this adapter depends on.

    Exists so tests can inject a lightweight fake without constructing a real
    ``AudioEngine`` (which the constructor test proves is cheap, but a fake
    keeps unit tests fast and hardware-free per the no-audio-device testing
    requirement).
    """

    def play_file(
        self,
        path,
        transcript_segments: list | None = None,
        start_segment: int = 0,
        on_progress=None,
    ) -> None: ...

    def get_file_duration(self, path) -> float: ...

    def pause(self) -> None: ...

    def resume(self) -> None: ...

    def stop(self) -> None: ...

    @property
    def playback_time_s(self) -> float: ...


# Decode-granularity tolerance for the truncated-decode guard (PM-10): ffmpeg's
# emitted PCM can legitimately fall a little short of the ffprobe-reported
# container duration (trailing partial block, container metadata rounding).
# Anything beyond this is treated as a genuine truncation, not decode noise.
_TRUNCATION_TOLERANCE_S = 2.0


def _to_engine_segments(segments: tuple[TranscriptSegment, ...]) -> list[_EngineTranscriptSegment]:
    """Convert station (integer ms) segments to engine-facing (float s) segments.

    This is the ONLY place milliseconds become seconds for station playback
    (PM-1). ``start_s = start_ms / 1000.0``, ``end_s = end_ms / 1000.0``.
    """
    return [
        _EngineTranscriptSegment(start_s=seg.start_ms / 1000.0, end_s=seg.end_ms / 1000.0, text=seg.text)
        for seg in segments
    ]


def _start_segment_for_offset(segments: tuple[TranscriptSegment, ...], offset_ms: int) -> int:
    """Map a resume offset (ms) to the engine ``start_segment`` index.

    Returns the index of the LAST segment whose ``start_ms <= offset_ms``, or
    0 if ``offset_ms == 0`` or ``segments`` is empty. ``engine.play_file``
    resumes by seeking to ``transcript_segments[start_segment].start_s``
    (``engine.py:464-465``), so this snaps resume to the containing segment's
    boundary: exact for interruption-resume offsets (already safe-point/
    segment-boundary snapped upstream), and a rewind of at most one segment's
    length for a general checkpoint offset that falls mid-segment.
    """
    if not segments or offset_ms <= 0:
        return 0
    best = 0
    for idx, seg in enumerate(segments):
        if seg.start_ms <= offset_ms:
            best = idx
        else:
            break
    return best


class MacPlaybackAdapter:
    """Concrete ``PlaybackAdapter`` (see ``wilted.station.protocols``) for Mac.

    Wraps ``wilted.engine.AudioEngine.play_file`` — which blocks until
    playback ends — on a background thread so :meth:`play` returns promptly.
    All shared state read/written across the caller thread and the background
    stream thread is guarded by :attr:`_lock`.

    This adapter is the sole resume authority for station playback: it never
    calls ``engine.set_resume_position`` (that legacy TUI resume path lives in
    ``wilted.playlists`` and is unrelated to station playback). Resume is
    driven entirely by the ``offset_ms`` -> ``start_segment`` mapping in
    :func:`_start_segment_for_offset`, fed into ``play_file``'s own
    ``start_segment`` seek.
    """

    def __init__(
        self,
        engine: _EngineLike | None = None,
        *,
        on_complete: Callable[[CompletionReason], None] | None = None,
    ) -> None:
        """Construct the adapter, optionally wired with a completion callback.

        ``on_complete``, if given, is invoked exactly once per completed
        :meth:`play` call, but ONLY for a natural end-of-thread completion
        (``ENDED``, ``TRUNCATED``, or ``UNKNOWN`` — see :class:`CompletionReason`)
        — never for ``STOPPED``. It runs on the background ``play_file``
        thread (see :meth:`_on_play_file_finished`), not the caller's thread;
        a Textual caller must marshal back via ``call_from_thread``. This lets
        a caller auto-advance on ``reason.is_clean_completion`` and surface a
        warning otherwise, without polling :attr:`last_completion`.
        """
        self._engine: _EngineLike = engine if engine is not None else AudioEngine()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._last_completion: CompletionReason | None = None
        self._stop_requested = False
        self.on_complete = on_complete

    @property
    def last_completion(self) -> CompletionReason | None:
        """How the most recent :meth:`play` call ended, or None if never played.

        ``None`` before any playback has completed, or while playback is
        still in progress from the most recent :meth:`play` call.
        """
        with self._lock:
            return self._last_completion

    def play(self, media: MediaDescriptor, *, offset_ms: int) -> None:
        """Begin playback of ``media`` starting at ``offset_ms``.

        Resolves ``media.sha256`` to an on-disk path via
        ``media_store.path_for`` (raises :class:`MediaNotAvailableError` if
        the blob is not published/on disk — never silently no-ops), converts
        ``media.transcript_segments`` to engine-facing seconds exactly once
        (:func:`_to_engine_segments`), maps ``offset_ms`` to a
        ``start_segment`` index (:func:`_start_segment_for_offset`), and runs
        ``engine.play_file`` on a background thread so this call returns
        promptly.

        Raises:
            MediaNotAvailableError: If ``media.sha256`` has no published blob.
        """
        # Resolve the new media BEFORE preempting the current playback: if the
        # new blob is missing, raise and leave whatever is currently playing
        # untouched rather than tearing it down for a play that can't start.
        resolved_path = media_store.path_for(media.sha256)
        if resolved_path is None:
            raise MediaNotAvailableError(
                f"media {media.sha256!r} is not published/on disk (media_store.path_for returned None); "
                "cannot start station playback"
            )

        # Preempt any in-flight (or paused) playback before launching a new
        # play_file. The station controller drives play() while a prior entry
        # is still playing (AcceptInterruption -> play(bulletin)) and as one
        # ends (auto-advance), so a second concurrent play_file on the shared
        # engine would open two OutputStreams and corrupt playback_time_s.
        # _preempt_current stops the engine (killing the old ffmpeg AND
        # re-arming the engine's pause event, which un-wedges a play() issued
        # after a pause()) and JOINS the old thread, so its completion
        # classifier has fully run and observed the STOPPED flag before we
        # reset session state below for the new play.
        self._preempt_current()

        if offset_ms > 0 and not media.transcript_segments:
            # play_file can only seek via transcript_segments[start_segment];
            # with no segments there is no arbitrary-ms seek, so a requested
            # resume offset silently becomes 0:00. Surface it rather than
            # swallowing a lost listener position.
            logger.warning(
                "resume requested at offset_ms=%d for media %r with no transcript segments; "
                "play_file cannot seek without segments, so playback restarts from 0:00 "
                "(resume position not honored)",
                offset_ms,
                media.sha256,
            )

        engine_segments = _to_engine_segments(media.transcript_segments)
        start_segment = _start_segment_for_offset(media.transcript_segments, offset_ms)

        with self._lock:
            self._last_completion = None
            self._stop_requested = False

        def _run() -> None:
            self._engine.play_file(
                path=resolved_path,
                transcript_segments=engine_segments,
                start_segment=start_segment,
            )
            self._on_play_file_finished(resolved_path)

        thread = threading.Thread(target=_run, daemon=True)
        with self._lock:
            self._thread = thread
        thread.start()

    def _preempt_current(self) -> None:
        """Stop and join any in-flight playback so a new one can start cleanly.

        No-op when nothing is running (so an ordinary first ``play`` does not
        spuriously call ``engine.stop``). When a prior stream thread is still
        alive it sets the STOPPED classification for that (now-abandoned)
        session, tells the engine to stop, and joins the thread — mirroring
        :meth:`stop` but conditional on there being something to preempt.
        """
        with self._lock:
            thread = self._thread
            if thread is None or not thread.is_alive():
                return
            self._stop_requested = True
            self._last_completion = CompletionReason.STOPPED

        self._engine.stop()
        thread.join(timeout=_JOIN_TIMEOUT_SECONDS)

    def _on_play_file_finished(self, path) -> None:
        """Classify how playback ended once the background thread's play_file returns.

        Truncated-decode guard (PM-10): compares ``engine.playback_time_s``
        (how far playback actually reached) against
        ``engine.get_file_duration(path)`` (expected total). A shortfall
        beyond :data:`_TRUNCATION_TOLERANCE_S` means the decode was truncated
        (e.g. ffmpeg died mid-stream) and must not be reported as a normal
        completion.

        An explicit :meth:`stop` takes precedence over the truncation check:
        a caller-requested stop is reported as ``STOPPED``, not ``TRUNCATED``,
        even though it also leaves playback short of the full duration.

        Completion callback: :attr:`on_complete`, if set, is invoked exactly
        when this call COMMITS an ``outcome`` below (i.e. natural ends only —
        ``ENDED``/``TRUNCATED``/``UNKNOWN``). The early-return STOPPED path
        above and a stop that races in during the duration probe (caught by
        the final ``if not self._stop_requested`` guard) both skip the
        callback. The callback runs OUTSIDE :attr:`_lock` — it may be slow or
        re-enter the adapter (e.g. call :meth:`play` to auto-advance) — and is
        never allowed to escape onto this background thread: a raise there is
        logged and swallowed so it cannot corrupt stream-thread state or leave
        :attr:`_last_completion` unset.
        """
        with self._lock:
            if self._stop_requested:
                self._last_completion = CompletionReason.STOPPED
                return

        try:
            expected_duration_s = self._engine.get_file_duration(path)
        except Exception:  # noqa: BLE001 - duration probe failure must not mask completion classification
            expected_duration_s = None

        reached_s = self._engine.playback_time_s
        if expected_duration_s is None:
            # Duration unverifiable -> cannot confirm a clean play-to-the-end.
            # Report UNKNOWN (not ENDED) so a caller does not auto-advance past
            # what may have been a truncated decode.
            outcome = CompletionReason.UNKNOWN
        elif (expected_duration_s - reached_s) > _TRUNCATION_TOLERANCE_S:
            outcome = CompletionReason.TRUNCATED
        else:
            outcome = CompletionReason.ENDED

        fired: CompletionReason | None = None
        with self._lock:
            if not self._stop_requested:
                self._last_completion = outcome
                fired = outcome

        if fired is not None and self.on_complete is not None:
            try:
                self.on_complete(fired)
            except Exception:  # noqa: BLE001 - a misbehaving callback must never corrupt the stream thread
                logger.error("on_complete callback raised for completion %r", fired, exc_info=True)

    def pause(self) -> None:
        """Pause playback, retaining the current position."""
        self._engine.pause()

    def resume(self) -> None:
        """Resume playback previously paused with :meth:`pause`, from the retained position."""
        self._engine.resume()

    def stop(self) -> None:
        """Stop playback and release any held playback resources.

        Safe to call from another thread. Reliably tears down the background
        stream thread: sets the stop flag (so the completion classifier
        reports ``STOPPED`` rather than ``TRUNCATED``), tells the engine to
        stop (which kills any in-flight ffmpeg process so a blocked read
        returns at once — see ``AudioEngine.stop``), then joins the thread.
        """
        with self._lock:
            self._stop_requested = True
            self._last_completion = CompletionReason.STOPPED
            thread = self._thread

        self._engine.stop()

        if thread is not None:
            thread.join(timeout=_JOIN_TIMEOUT_SECONDS)

    def seek(self, offset_ms: int) -> None:
        """Move the current playback position to ``offset_ms``.

        Not supported as an in-place seek by the underlying engine (only
        ``play_file``'s startup-time ffmpeg ``-ss`` seek exists); out of scope
        per Task 3.2 (only :meth:`play` with an ``offset_ms`` resumes at a
        position). Left unimplemented deliberately rather than faked with a
        silent no-op or a full stop+replay a caller would not expect.
        """
        raise NotImplementedError(
            "MacPlaybackAdapter.seek is not supported: AudioEngine has no in-place seek; "
            "resume-at-offset is only available via play(media, offset_ms=...)"
        )

    def current_offset_ms(self) -> int:
        """Return the current playback position in milliseconds.

        Reads ``engine.playback_time_s`` (continuous episode time, safely
        readable while the background stream thread runs) and converts to
        milliseconds: the only ms<->s conversion point on the read side,
        mirroring :func:`_to_engine_segments` on the write side.
        """
        return round(self._engine.playback_time_s * 1000)
