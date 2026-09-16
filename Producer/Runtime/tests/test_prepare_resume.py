"""Production-path + liveness tests for the podcast transcription resume path (C-Fork S3).

Drives the REAL ``handle_prepare -> prepare_item -> _transcribe_podcast`` chain with a
fake ``ModelCoordinator`` whose ``run_transcribe`` is an invocation spy and a genuine
on-disk atomic transcript save. Exercises the INV-6 resume consumer: a job re-claimed
after a prior attempt already persisted its transcript (S2) skips the download + GPU
transcribe lease, gated on the authoritative Item row and re-validated by word count +
audio coverage. The marker (``checkpoint_json._progress``) is read/written by production
code — proving it is non-dormant (PM-7) — but is never the sole gate.

Invariants exercised:
  * INV-9  production-path tests drive the real handler chain, not a re-implementation.
  * INV-6  resume trusts the atomically-written transcript/Item row; the marker is a hint.
  * INV-4  an empty ad-cut never overwrites the original audio.
  * PM-3   word-count integrity gates the on-disk transcript before it is trusted.
  * PM-7   the live consumer both reads and writes the checkpoint substrate.
"""

from __future__ import annotations

import json
from contextlib import ExitStack
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING
from unittest.mock import MagicMock, patch

import pytest

import wilted
import wilted.processing_jobs as processing_jobs
from wilted.background_work.contracts import JobKind, ProcessingJobState
from wilted.db import Feed, Item, ProcessingJob, now_utc
from wilted.handlers.prepare import handle_prepare
from wilted.prepare import (
    _COVERAGE_TOLERANCE,
    PrepareError,
    _process_podcast,
    _set_status,
    _transcribe_podcast,
)
from wilted.transcribe import TranscriptSegment, save_transcript, segments_to_text

if TYPE_CHECKING:
    from pathlib import Path

pytestmark = [pytest.mark.integration, pytest.mark.usefixtures("execution_capability")]

_OWNER = "runner-resume"


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _future() -> str:
    return (datetime.now(UTC) + timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _past() -> str:
    return (datetime.now(UTC) - timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")


class _CoordinatorSpy:
    """Fake ModelCoordinator: counts ``run_transcribe`` calls; runs both callbacks inline."""

    def __init__(self) -> None:
        self.transcribe_calls = 0
        self.llm_calls = 0

    def run_transcribe(self, fn):
        self.transcribe_calls += 1
        return fn()

    def run_llm(self, backend, fn):
        self.llm_calls += 1
        return fn(backend)


def _segments(*, last_end: float) -> list[TranscriptSegment]:
    """Two-segment transcript (6 words) whose final segment ends at ``last_end``."""
    return [
        TranscriptSegment(0.0, last_end / 2, "hello world foo"),
        TranscriptSegment(last_end / 2, last_end, "bar baz qux"),
    ]


def _make_podcast(**kwargs) -> Item:
    now = _now()
    feed = Feed.create(
        title="Resume Feed",
        feed_url="https://example.com/feed.xml",
        feed_type="podcast",
        enabled=True,
        created_at=now,
        updated_at=now,
    )
    defaults = dict(
        feed=feed,
        guid=f"resume-ep-{id(object())}",
        title="Resume Episode",
        discovered_at=now,
        item_type="podcast_episode",
        status="selected",
        status_changed_at=now,
        enclosure_url="https://example.com/episode.mp3",
        enclosure_type="audio/mpeg",
    )
    defaults.update(kwargs)
    return Item.create(**defaults)


def _make_job(item: Item, *, use_llm: bool = False, progress: dict | None = None, key: str = "a") -> ProcessingJob:
    payload: dict = {"operation_version": 1, "use_llm": use_llm, "skip_tts": False}
    if progress is not None:
        payload["_progress"] = progress
        payload["_checkpoint_v"] = 2
    now = now_utc()
    return ProcessingJob.create(
        idempotency_key=f"{JobKind.PREPARE.value}:v1:resume:{key}",
        kind=JobKind.PREPARE.value,
        state=ProcessingJobState.RUNNING.value,
        priority=0,
        attempt_count=0,
        max_attempts=3,
        created_at=now,
        updated_at=now,
        started_at=now,
        lease_owner=_OWNER,
        lease_expires_at=_future(),
        checkpoint_json=json.dumps(payload),
        item_id=item.id,
    )


def _seed_resumed_podcast(*, segments: list[TranscriptSegment], create_audio: bool = True):
    """Persist a transcript + Item row exactly as a prior attempt would, then leave the
    item mid-flight (status 'processing') so a re-claim exercises the resume path.

    Returns (reloaded_item, audio_path, transcript_path).
    """
    item = _make_podcast()
    tdir = wilted.DATA_DIR / "transcripts"
    tdir.mkdir(parents=True, exist_ok=True)
    tpath = tdir / f"{item.id}_transcript.json"
    save_transcript(segments, tpath)

    adir = wilted.DATA_DIR / "podcasts" / str(item.id)
    adir.mkdir(parents=True, exist_ok=True)
    apath = adir / "episode.mp3"
    if create_audio:
        apath.write_bytes(b"fake audio bytes")

    word_count = len(segments_to_text(segments).split())
    Item.update(
        transcript_file=str(tpath),
        word_count=word_count,
        audio_file=str(apath),
    ).where(Item.id == item.id).execute()

    reloaded = Item.get_by_id(item.id)
    _set_status(reloaded, "processing")  # crash-before-ready; transcript_file preserved
    return Item.get_by_id(item.id), apath, tpath


def _drive(
    job: ProcessingJob,
    coordinator: _CoordinatorSpy,
    *,
    audio_path: Path,
    transcribe_result: list[TranscriptSegment],
    duration: float = 100.0,
    backend=None,
    ads_result=None,
) -> MagicMock:
    """Run the real ``handle_prepare`` under standard prepare-path patches.

    Returns the ``detect_ads`` mock so callers can assert Phase B ad detection.
    """
    detect_mock = MagicMock(return_value=ads_result or [])
    with ExitStack() as stack:
        stack.enter_context(patch("wilted.prepare.download_podcast", return_value=audio_path))
        stack.enter_context(patch("wilted.prepare.get_transcript", return_value=transcribe_result))
        stack.enter_context(patch("wilted.prepare._get_feed_xml", return_value=None))
        stack.enter_context(
            patch("wilted.handlers.prepare.build_llm_backend", return_value=backend or MagicMock()),
        )
        stack.enter_context(patch("wilted.ads.detect_ads", detect_mock))
        mock_engine = stack.enter_context(patch("wilted.engine.AudioEngine"))
        mock_engine.return_value.get_file_duration.return_value = duration
        handle_prepare(ProcessingJob.get_by_id(job.id), coordinator)
    return detect_mock


def _reclaim(job: ProcessingJob, item: Item) -> None:
    """Simulate crash-then-retry: job back to RUNNING (marker preserved), item mid-flight."""
    ProcessingJob.update(
        state=ProcessingJobState.RUNNING.value,
        lease_owner=_OWNER,
        lease_expires_at=_future(),
        completed_at=None,
        result_json=None,
        updated_at=now_utc(),
    ).where(ProcessingJob.id == job.id).execute()  # checkpoint_json intentionally preserved
    _set_status(Item.get_by_id(item.id), "processing")


def _marker(job: ProcessingJob) -> dict:
    payload = json.loads(ProcessingJob.get_by_id(job.id).checkpoint_json)
    return payload.get("_progress", {})


def _result_metadata(job: ProcessingJob) -> dict:
    return json.loads(ProcessingJob.get_by_id(job.id).result_json)["metadata"]


# ---------------------------------------------------------------------------
# (a) full run writes the marker; re-claim resume-skips transcription
# ---------------------------------------------------------------------------


class TestFullRunThenResume:
    def test_full_run_writes_marker_then_reclaim_skips_transcription(self):
        item = _make_podcast()
        job = _make_job(item, use_llm=False, key="a")

        audio = wilted.DATA_DIR / "podcasts" / str(item.id) / "episode.mp3"
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"fake audio bytes")

        first = _CoordinatorSpy()
        _drive(job, first, audio_path=audio, transcribe_result=_segments(last_end=70.0), duration=100.0)

        # Full transcribe happened exactly once and the marker was written.
        assert first.transcribe_calls == 1
        assert Item.get_by_id(item.id).status == "ready"
        marker = _marker(job)
        assert marker["stage"] == "transcribed"
        assert marker["word_count"] == 6
        assert marker["coverage_ratio"] == pytest.approx(0.7)
        assert json.loads(ProcessingJob.get_by_id(job.id).checkpoint_json)["_checkpoint_v"] == 2
        assert ProcessingJob.get_by_id(job.id).state == ProcessingJobState.COMPLETED.value

        # Re-claim the same job (marker preserved) and re-run with a FRESH spy.
        _reclaim(job, item)
        resumed = _CoordinatorSpy()
        _drive(job, resumed, audio_path=audio, transcribe_result=_segments(last_end=70.0), duration=100.0)

        assert resumed.transcribe_calls == 0  # resume-skip: GPU lease never taken
        assert Item.get_by_id(item.id).status == "ready"
        assert _result_metadata(job)["prepared"] == 1


# ---------------------------------------------------------------------------
# (b) truncated transcript (word-count mismatch) forces re-transcription
# ---------------------------------------------------------------------------


class TestWriteIntegrity:
    def test_word_count_mismatch_retranscribes(self):
        item, audio, tpath = _seed_resumed_podcast(segments=_segments(last_end=70.0))
        # Corrupt the on-disk transcript so its word count no longer matches the Item row.
        save_transcript([TranscriptSegment(0.0, 5.0, "only")], tpath)
        job = _make_job(item, progress={"stage": "transcribed", "word_count": 6, "coverage_ratio": 0.7}, key="b")

        spy = _CoordinatorSpy()
        _drive(job, spy, audio_path=audio, transcribe_result=_segments(last_end=70.0), duration=100.0)

        assert spy.transcribe_calls == 1  # PM-3: integrity check rejected the stale file
        assert Item.get_by_id(item.id).status == "ready"


# ---------------------------------------------------------------------------
# (c) coverage calibration: complete transcript resumes, half-length stub re-runs
# ---------------------------------------------------------------------------


class TestCoverageCalibration:
    def test_tolerance_is_conservative(self):
        # Pin the calibrated value: a high threshold (e.g. 0.98) would spuriously
        # re-transcribe complete transcripts that end before the file's last second.
        assert _COVERAGE_TOLERANCE == 0.5

    def test_complete_transcript_with_trailing_tail_resumes(self):
        # Last segment ends at 70% of a 100s file (trailing music/silence) — complete.
        item, audio, _ = _seed_resumed_podcast(segments=_segments(last_end=70.0))
        job = _make_job(item, progress=None, key="c1")  # no marker → recompute path

        spy = _CoordinatorSpy()
        _drive(job, spy, audio_path=audio, transcribe_result=_segments(last_end=70.0), duration=100.0)

        assert spy.transcribe_calls == 0  # 0.70 >= 0.5 → resume
        assert Item.get_by_id(item.id).status == "ready"

    def test_half_length_stub_retranscribes(self):
        # A grossly-truncated stub (ends at 12% of the file) must be rejected even though
        # its word count matches the Item row — coverage is the separate completeness gate.
        stub = _segments(last_end=12.0)
        item, audio, _ = _seed_resumed_podcast(segments=stub)
        job = _make_job(item, progress=None, key="c1b")  # no marker → recompute path

        spy = _CoordinatorSpy()
        _drive(job, spy, audio_path=audio, transcribe_result=_segments(last_end=70.0), duration=100.0)

        assert spy.transcribe_calls == 1  # 0.12 < 0.5 → re-transcribe
        assert Item.get_by_id(item.id).status == "ready"


# ---------------------------------------------------------------------------
# (c2) crash-window: transcript on disk, NO marker → resume via _recompute_coverage
# ---------------------------------------------------------------------------


class TestCrashWindow:
    def test_no_marker_resumes_via_recompute(self):
        # The :185->:190 crash leaves a complete transcript + Item row but no marker.
        # The marker-gated design would wrongly re-run; gating on the Item row does not.
        item, audio, _ = _seed_resumed_podcast(segments=_segments(last_end=70.0))
        job = _make_job(item, progress=None, key="c2")  # checkpoint_json has options only

        assert "_progress" not in json.loads(ProcessingJob.get_by_id(job.id).checkpoint_json)

        spy = _CoordinatorSpy()
        _drive(job, spy, audio_path=audio, transcribe_result=_segments(last_end=70.0), duration=100.0)

        assert spy.transcribe_calls == 0  # recompute → 0.70 >= 0.5 → resume
        assert Item.get_by_id(item.id).status == "ready"


# ---------------------------------------------------------------------------
# (d) audio-on-resume: drives ad detection when present; fails loudly when pruned
# ---------------------------------------------------------------------------


class TestAudioOnResume:
    def test_resume_drives_process_podcast_ad_detection(self):
        item, audio, _ = _seed_resumed_podcast(segments=_segments(last_end=70.0))
        job = _make_job(
            item,
            use_llm=True,
            progress={"stage": "transcribed", "word_count": 6, "coverage_ratio": 0.7},
            key="d1",
        )
        backend = MagicMock()

        spy = _CoordinatorSpy()
        detect = _drive(
            job,
            spy,
            audio_path=audio,
            transcribe_result=_segments(last_end=70.0),
            duration=100.0,
            backend=backend,
        )

        assert spy.transcribe_calls == 0  # resumed
        # Phase B ran against the DB-persisted audio: ad detection saw the resumed segments.
        assert detect.call_count == 1
        assert len(detect.call_args.args[0]) == 2
        assert Item.get_by_id(item.id).status == "ready"

    def test_resume_with_pruned_audio_fails_loudly(self):
        # Marker present (resume fires without probing audio), but the audio was pruned.
        item, audio, _ = _seed_resumed_podcast(segments=_segments(last_end=70.0))
        audio.unlink()  # prune the downloaded audio after the transcript was saved
        job = _make_job(
            item,
            use_llm=False,
            progress={"stage": "transcribed", "word_count": 6, "coverage_ratio": 0.7},
            key="d2",
        )

        spy = _CoordinatorSpy()
        _drive(job, spy, audio_path=audio, transcribe_result=_segments(last_end=70.0), duration=100.0)

        assert spy.transcribe_calls == 0  # resume-skip did fire (transcript trusted)
        refreshed = Item.get_by_id(item.id)
        assert refreshed.status == "error"  # loud failure — never a half-prepared 'ready'
        assert "missing" in (refreshed.error_message or "").lower()
        # Content failures COMPLETE the job with errors=1 (manifest is structurally
        # complete, so record_job_completion always succeeds) — never a silent success.
        assert ProcessingJob.get_by_id(job.id).state == ProcessingJobState.COMPLETED.value
        assert _result_metadata(job)["prepared"] == 0
        assert _result_metadata(job)["errors"] == 1

    def test_process_podcast_missing_audio_raises(self):
        item = _make_podcast()
        Item.update(audio_file="/nonexistent/pruned.mp3").where(Item.id == item.id).execute()
        target = Item.get_by_id(item.id)

        with pytest.raises(PrepareError, match="missing"):
            _process_podcast(target, _segments(last_end=70.0))

        assert Item.get_by_id(item.id).status == "error"


# ---------------------------------------------------------------------------
# (e) INV-4: an empty ad-cut never overwrites the original audio
# ---------------------------------------------------------------------------


class TestInv4EmptyOverwriteGate:
    def test_empty_ad_cut_keeps_original_audio(self):
        item, audio, _ = _seed_resumed_podcast(segments=_segments(last_end=70.0))
        original = audio.read_bytes()
        from wilted.ads import AdSegment

        ad = AdSegment(start_s=1.0, end_s=2.0, confidence=0.95, label="ad_break")

        with (
            patch("wilted.ads.detect_ads", return_value=[ad]),
            patch("wilted.ads.cut_ads"),  # produces no output file
            patch("wilted.engine.AudioEngine") as mock_engine,
        ):
            mock_engine.return_value.get_file_duration.return_value = 100.0
            _process_podcast(Item.get_by_id(item.id), _segments(last_end=70.0), llm_backend=MagicMock())

        assert audio.read_bytes() == original  # INV-4: original preserved


# ---------------------------------------------------------------------------
# PM-7 liveness: the live consumer both reads and writes the substrate
# ---------------------------------------------------------------------------


class TestLiveness:
    def test_transcribe_reads_and_writes_checkpoint_substrate(self):
        item = _make_podcast()
        job = _make_job(item, use_llm=False, key="pm7")
        audio = wilted.DATA_DIR / "podcasts" / str(item.id) / "episode.mp3"
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"fake audio bytes")

        # Full run must WRITE the marker via the real merge substrate.
        with patch.object(
            processing_jobs, "merge_checkpoint_progress", wraps=processing_jobs.merge_checkpoint_progress
        ) as merge_spy:
            _drive(job, _CoordinatorSpy(), audio_path=audio, transcribe_result=_segments(last_end=70.0))
        assert merge_spy.called

        # Resume run must READ the marker via the real read substrate.
        _reclaim(job, item)
        with patch.object(
            processing_jobs, "read_checkpoint_progress", wraps=processing_jobs.read_checkpoint_progress
        ) as read_spy:
            _drive(job, _CoordinatorSpy(), audio_path=audio, transcribe_result=_segments(last_end=70.0))
        assert read_spy.called


# ---------------------------------------------------------------------------
# item-2 regression: checkpoint=None path is byte-identical (probe-free, marker-free)
# ---------------------------------------------------------------------------


class TestCheckpointNoneProbeFree:
    def test_checkpoint_none_never_reads_marker_or_probes(self):
        item = _make_podcast()
        audio = wilted.DATA_DIR / "podcasts" / str(item.id) / "episode.mp3"
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"fake audio bytes")

        with (
            patch("wilted.prepare.download_podcast", return_value=audio),
            patch("wilted.prepare.get_transcript", return_value=_segments(last_end=70.0)),
            patch("wilted.prepare._get_feed_xml", return_value=None),
            patch("wilted.prepare._recompute_coverage") as recompute,
            patch.object(processing_jobs, "read_checkpoint_progress") as read_spy,
            patch.object(processing_jobs, "merge_checkpoint_progress") as merge_spy,
        ):
            _transcribe_podcast(item, _CoordinatorSpy(), checkpoint=None)

        recompute.assert_not_called()  # no ffprobe on the CLI/batch path
        read_spy.assert_not_called()
        merge_spy.assert_not_called()


# ---------------------------------------------------------------------------
# (f) end-to-end: abrupt crash -> REAL recover_stale_jobs -> REAL claim_next_job
#     -> resume. The (a) case above proves resume-skip but bridges the crash
#     with a hand-rolled `_reclaim` UPDATE. This class drives the *real*
#     reconciliation — recover_stale_jobs() flips the lease-expired RUNNING job
#     to RETRY, and claim_next_job()'s CAS advances it back to RUNNING — closing
#     the "proven in two halves, not end-to-end" seam the 2026-07-24 close-out
#     note flagged. Synthetic (fake audio + mocked duration) keeps it hermetic
#     and in the default gate; the same path was verified once against real
#     trial audio + a real ffprobe probe out-of-band (item-2 manual check).
# ---------------------------------------------------------------------------


class TestCrashRecoverReclaimResume:
    def test_real_recover_and_claim_span_crash_to_resume(self):
        item = _make_podcast()
        job = _make_job(item, use_llm=False, key="f")
        audio = wilted.DATA_DIR / "podcasts" / str(item.id) / "episode.mp3"
        audio.parent.mkdir(parents=True, exist_ok=True)
        audio.write_bytes(b"fake audio bytes")

        # -- PASS 1: real transcribe, then an abrupt crash in the post-transcription
        # stage. KeyboardInterrupt (a BaseException) escapes prepare_item's broad
        # `except Exception` exactly as a real Ctrl-C / SIGKILL would, leaving the
        # job RUNNING (recoverable) rather than gracefully COMPLETED-with-error.
        first = _CoordinatorSpy()
        with (
            patch("wilted.prepare.download_podcast", return_value=audio),
            patch("wilted.prepare.get_transcript", return_value=_segments(last_end=70.0)),
            patch("wilted.prepare._get_feed_xml", return_value=None),
            patch("wilted.engine.AudioEngine") as mock_engine,
            patch("wilted.prepare._process_podcast", side_effect=KeyboardInterrupt("crash")),
        ):
            mock_engine.return_value.get_file_duration.return_value = 100.0
            with pytest.raises(KeyboardInterrupt):
                handle_prepare(ProcessingJob.get_by_id(job.id), first)

        assert first.transcribe_calls == 1  # the crashed attempt took the GPU lease once
        crashed_item = Item.get_by_id(item.id)
        assert crashed_item.transcript_file  # atomic transcript survived the crash
        assert crashed_item.word_count == 6
        crashed_job = ProcessingJob.get_by_id(job.id)
        assert crashed_job.state == ProcessingJobState.RUNNING.value  # recoverable, not COMPLETED
        marker = _marker(job)
        assert marker["stage"] == "transcribed"
        assert marker["coverage_ratio"] == pytest.approx(0.7)

        # -- RECOVERY: expire the lease, then the REAL reconciliation flips
        # RUNNING -> RETRY (the transition the note said was never spanned e2e).
        ProcessingJob.update(lease_expires_at=_past()).where(ProcessingJob.id == job.id).execute()
        recovered = processing_jobs.recover_stale_jobs(data_dir=wilted.DATA_DIR, owner_id=_OWNER, now=_now())
        assert recovered == 1
        assert ProcessingJob.get_by_id(job.id).state == ProcessingJobState.RETRY.value

        # -- RE-CLAIM: the REAL CAS claim advances RETRY -> RUNNING under a fresh lease.
        claimed = processing_jobs.claim_next_job(data_dir=wilted.DATA_DIR, owner_id=_OWNER)
        assert claimed is not None
        assert claimed.id == job.id
        assert claimed.state == ProcessingJobState.RUNNING.value
        assert claimed.lease_owner == _OWNER

        # -- PASS 2: resume. download + get_transcript are spies that must NOT fire —
        # the fast-path returns the on-disk transcript, skipping download + GPU lease.
        resumed = _CoordinatorSpy()
        with (
            patch("wilted.prepare.download_podcast") as dl,
            patch("wilted.prepare.get_transcript") as gt,
            patch("wilted.prepare._get_feed_xml", return_value=None),
            patch("wilted.engine.AudioEngine") as mock_engine2,
        ):
            mock_engine2.return_value.get_file_duration.return_value = 100.0
            handle_prepare(ProcessingJob.get_by_id(job.id), resumed)

        assert resumed.transcribe_calls == 0  # resume-skip: GPU lease never taken
        dl.assert_not_called()
        gt.assert_not_called()
        assert Item.get_by_id(item.id).status == "ready"
        final_job = ProcessingJob.get_by_id(job.id)
        assert final_job.state == ProcessingJobState.COMPLETED.value
        assert _result_metadata(job)["prepared"] == 1
