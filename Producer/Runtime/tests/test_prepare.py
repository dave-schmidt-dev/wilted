"""Tests for wilted.prepare — content preparation orchestrator."""

import threading
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from wilted.prepare import _transcribe_podcast, run_prepare

pytestmark = pytest.mark.usefixtures("execution_capability")


def _now():
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _run_prepare(**kwargs):
    """Run prepare with a test-scoped coordinator under execution capability."""
    from wilted.execution_capability import create_model_coordinator
    from wilted.handlers._ml import build_llm_backend
    from wilted.handlers.transcribe import transcribe_tier3

    kwargs.setdefault("backend_factory", lambda backend_type, model: build_llm_backend(backend_type, model=model))
    kwargs.setdefault("tier3_transcribe", transcribe_tier3)

    if "coordinator" in kwargs:
        return run_prepare(**kwargs)

    coordinator = create_model_coordinator()
    try:
        return run_prepare(coordinator=coordinator, **kwargs)
    finally:
        coordinator.close()


def _ads_ad_segment(start_s, end_s):
    """Build an AdSegment for INV-4 tests without importing at module top."""
    from wilted.ads import AdSegment

    return AdSegment(start_s=start_s, end_s=end_s, confidence=0.95, label="ad_break")


def _make_item(tmp_path, **kwargs):
    """Create an Item in the test database."""
    from wilted.db import Item

    defaults = dict(
        feed=None,
        guid="test-guid",
        title="Test Item",
        discovered_at=_now(),
        item_type="article",
        status="selected",
        status_changed_at=_now(),
    )
    defaults.update(kwargs)

    # If article, create a transcript file
    if defaults["item_type"] == "article" and not defaults.get("transcript_file"):
        articles_dir = tmp_path / "data" / "articles"
        articles_dir.mkdir(parents=True, exist_ok=True)
        transcript = articles_dir / "test_article.txt"
        transcript.write_text("This is a test article with enough words to process.")
        defaults["transcript_file"] = str(transcript)

    return Item.create(**defaults)


def _make_podcast(tmp_path, **kwargs):
    """Create a podcast Item with a feed."""
    from wilted.db import Feed, Item

    now = _now()
    feed = Feed.create(
        title="Test Podcast",
        feed_url="https://example.com/feed.xml",
        feed_type="podcast",
        enabled=True,
        created_at=now,
        updated_at=now,
    )
    defaults = dict(
        feed=feed,
        guid="pod-ep-1",
        title="Test Episode",
        discovered_at=now,
        item_type="podcast_episode",
        status="selected",
        status_changed_at=now,
        enclosure_url="https://example.com/episode.mp3",
        enclosure_type="audio/mpeg",
    )
    defaults.update(kwargs)
    return Item.create(**defaults)


# ---------------------------------------------------------------------------
# run_prepare — no selected items
# ---------------------------------------------------------------------------


class TestRunPrepareEmpty:
    def test_no_selected_items(self, tmp_path):
        """run_prepare returns zeros when nothing is selected."""
        stats = _run_prepare(use_llm=False)
        assert stats == {"prepared": 0, "errors": 0, "skipped": 0}


# ---------------------------------------------------------------------------
# run_prepare — article pipeline
# ---------------------------------------------------------------------------


class TestPrepareArticle:
    def test_article_skip_tts_marks_ready(self, tmp_path):
        """With skip_tts=True, articles are marked ready without TTS generation."""
        item = _make_item(tmp_path)
        stats = _run_prepare(use_llm=False, skip_tts=True)

        from wilted.db import Item

        refreshed = Item.get_by_id(item.id)
        assert refreshed.status == "ready"
        assert stats["prepared"] == 1
        assert stats["errors"] == 0

    def test_article_missing_transcript_errors(self, tmp_path):
        """Article without transcript_file transitions to error."""
        from wilted.db import Item

        item = Item.create(
            feed=None,
            guid="no-transcript",
            title="No Transcript",
            discovered_at=_now(),
            item_type="article",
            status="selected",
            status_changed_at=_now(),
            transcript_file=None,
        )
        stats = _run_prepare(use_llm=False)
        refreshed = Item.get_by_id(item.id)
        assert refreshed.status == "error"
        assert "No transcript file" in (refreshed.error_message or "")
        assert stats["errors"] == 1

    def test_article_missing_transcript_file_errors(self, tmp_path):
        """Article with transcript_file pointing to nonexistent file transitions to error."""
        from wilted.db import Item

        item = Item.create(
            feed=None,
            guid="missing-file",
            title="Missing File",
            discovered_at=_now(),
            item_type="article",
            status="selected",
            status_changed_at=_now(),
            transcript_file="/nonexistent/path.txt",
        )
        stats = _run_prepare(use_llm=False)
        refreshed = Item.get_by_id(item.id)
        assert refreshed.status == "error"
        assert stats["errors"] == 1

    def test_article_with_promo_removal(self, tmp_path):
        """Promo removal is called when LLM backend is provided."""
        _make_item(tmp_path)

        mock_backend = MagicMock()
        mock_backend.load = MagicMock()
        mock_backend.close = MagicMock()
        mock_backend.generate = MagicMock(return_value=('{"promo_indices": []}', 10))

        with (
            patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend) as mock_create,
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            stats = _run_prepare(use_llm=True)

        assert stats["prepared"] == 1
        mock_create.assert_called_once()
        mock_backend.load.assert_called_once()
        mock_backend.close.assert_called_once()


# ---------------------------------------------------------------------------
# run_prepare — podcast pipeline
# ---------------------------------------------------------------------------


class TestPreparePodcast:
    def test_podcast_no_enclosure_url_errors(self, tmp_path):
        """Podcast without enclosure_url transitions to error."""
        _make_podcast(tmp_path, enclosure_url=None)
        stats = _run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select())
        assert items[0].status == "error"
        assert stats["errors"] == 1

    def test_podcast_download_failure_errors(self, tmp_path):
        """Podcast with failed download transitions to error."""
        from wilted.download import DownloadError

        _make_podcast(tmp_path)

        with patch("wilted.prepare.download_podcast", side_effect=DownloadError("HTTP 404")):
            stats = _run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select().where(Item.item_type == "podcast_episode"))
        assert items[0].status == "error"
        assert "Download failed" in (items[0].error_message or "")
        assert stats["errors"] == 1

    def test_bws_podcast_resolves_enclosure_only_for_download(self, tmp_path, monkeypatch):
        from wilted.feed_refs import make_bws_enclosure_reference

        private_url = "https://private.example/credential-material.mp3"
        item = _make_podcast(tmp_path)
        item.feed.feed_url = "bws:WILTED_FEED_PRIVATE"
        item.feed.save()
        item.enclosure_url = make_bws_enclosure_reference("bws:WILTED_FEED_PRIVATE", item.guid)
        item.save()
        monkeypatch.setenv("WILTED_FEED_PRIVATE", "https://private.example/feed.xml")
        parsed = type(
            "Parsed",
            (),
            {"entries": [{"id": item.guid, "enclosures": [{"href": private_url, "type": "audio/mpeg"}]}]},
        )
        audio_file = tmp_path / "episode.mp3"
        audio_file.write_bytes(b"audio")
        coordinator = MagicMock()
        coordinator.run_transcribe.return_value = []

        with (
            patch("wilted.feed_refs.feedparser.parse", return_value=parsed),
            patch("wilted.prepare.download_podcast", return_value=audio_file) as download,
        ):
            _transcribe_podcast(item, coordinator)

        assert private_url not in item.enclosure_url
        download.assert_called_once_with(
            item.id,
            private_url,
            url_label=item.enclosure_url,
            filename_override="episode.mp3",
        )

    def test_podcast_full_pipeline(self, tmp_path):
        """Podcast goes through download → transcribe → ready."""
        from wilted.transcribe import TranscriptSegment

        _make_podcast(tmp_path)

        audio_file = tmp_path / "data" / "podcasts" / "1" / "episode.mp3"
        audio_file.parent.mkdir(parents=True, exist_ok=True)
        audio_file.write_bytes(b"fake audio data")

        segments = [
            TranscriptSegment(0.0, 5.0, "Hello world"),
            TranscriptSegment(5.0, 10.0, "Goodbye world"),
        ]

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", return_value=segments),
            patch("wilted.prepare.save_transcript"),
            patch("wilted.engine.AudioEngine") as MockEngine,
        ):
            mock_engine = MockEngine.return_value
            mock_engine.get_file_duration.return_value = 10.0
            stats = _run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select().where(Item.item_type == "podcast_episode"))
        assert items[0].status == "ready"
        assert stats["prepared"] == 1

    def test_podcast_transcription_failure_errors(self, tmp_path):
        """Podcast with failed transcription transitions to error."""
        from wilted.transcribe import TranscriptionError

        _make_podcast(tmp_path)

        audio_file = tmp_path / "data" / "podcasts" / "1" / "episode.mp3"
        audio_file.parent.mkdir(parents=True, exist_ok=True)
        audio_file.write_bytes(b"fake audio data")

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", side_effect=TranscriptionError("No transcript")),
        ):
            _run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select().where(Item.item_type == "podcast_episode"))
        assert items[0].status == "error"
        assert "Transcription failed" in (items[0].error_message or "")


# ---------------------------------------------------------------------------
# run_prepare — daemon STT evict hint (PM-5/INV-2 co-residency avoidance)
# ---------------------------------------------------------------------------


class TestPrepareEvictHint:
    """After Phase A (transcribe) and BEFORE Phase B (LLM load), the daemon STT
    model is evicted so parakeet is never co-resident with the LLM in the daemon."""

    def _podcast_pipeline(self, tmp_path):
        """Set up a single podcast whose transcription is mocked to succeed."""
        from wilted.transcribe import TranscriptSegment

        _make_podcast(tmp_path)
        audio_file = tmp_path / "data" / "podcasts" / "1" / "episode.mp3"
        audio_file.parent.mkdir(parents=True, exist_ok=True)
        audio_file.write_bytes(b"fake audio data")
        segments = [TranscriptSegment(0.0, 5.0, "Hello world")]
        return audio_file, segments

    def test_evicts_stt_between_phases(self, tmp_path):
        """The daemon is the only tier-3 STT route (M2 cutover), so run_prepare
        unconditionally fires client.evict('stt') once between phases."""
        audio_file, segments = self._podcast_pipeline(tmp_path)

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", return_value=segments),
            patch("wilted.prepare.save_transcript"),
            patch("wilted.engine.AudioEngine") as MockEngine,
            patch("wilted.transcribe.client.evict") as mock_evict,
        ):
            MockEngine.return_value.get_file_duration.return_value = 5.0
            _run_prepare(use_llm=False)

        # The evict hint fired exactly once, dropping the resident STT model.
        mock_evict.assert_called_once_with("stt")

    def test_evict_failure_does_not_abort_prepare(self, tmp_path):
        """A DaemonUnavailable during the between-phases evict hint must not crash
        run_prepare (INV-6): evict_stt_model() swallows it internally, so a daemon
        that already went away between Phase A and the evict hint is a no-op."""
        from speech_stack import client

        audio_file, segments = self._podcast_pipeline(tmp_path)

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", return_value=segments),
            patch("wilted.prepare.save_transcript"),
            patch("wilted.engine.AudioEngine") as MockEngine,
            patch("wilted.transcribe.client.evict", side_effect=client.DaemonUnavailable("gone")),
        ):
            MockEngine.return_value.get_file_duration.return_value = 5.0
            stats = _run_prepare(use_llm=False)  # must not raise

        assert stats["errors"] == 0

    def test_evict_wedged_daemon_does_not_abort_prepare(self, tmp_path):
        """Full-batch regression lock for the wedged-daemon evict fix (see
        HISTORY 2026-07-19): a WEDGED daemon (socket present but unresponsive,
        surfacing as ``ConnectionLost`` rather than ``DaemonUnavailable``) during
        the between-phases evict hint must not crash the entire ``run_prepare``
        batch. ``evict_stt_model()`` is called unconditionally and unguarded at
        the ``run_prepare`` call site (no surrounding try/except there) -- so
        this exercises the real, undisguised regression shape: before the fix,
        ``evict_stt_model`` caught only ``DaemonUnavailable``, so a
        present-but-wedged daemon's ``ConnectionLost`` propagated straight out of
        this unguarded call and blew up the whole prepare run, not just the
        evict hint. ``test_evict_failure_does_not_abort_prepare`` above only
        covers the already-handled ``DaemonUnavailable`` case, which the buggy
        pre-fix code also caught -- it would not have caught this regression.
        """
        from speech_stack import client

        audio_file, segments = self._podcast_pipeline(tmp_path)
        wedged = client.ConnectionLost("stream closed after 0 of 4 expected bytes (peer gone)")

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", return_value=segments),
            patch("wilted.prepare.save_transcript"),
            patch("wilted.engine.AudioEngine") as MockEngine,
            patch("wilted.transcribe.client.evict", side_effect=wedged),
        ):
            MockEngine.return_value.get_file_duration.return_value = 5.0
            stats = _run_prepare(use_llm=False)  # must not raise

        assert stats["errors"] == 0
        assert stats["prepared"] == 1


# ---------------------------------------------------------------------------
# run_prepare — mixed items
# ---------------------------------------------------------------------------


class TestPrepareMixed:
    def test_mixed_items_processes_both_types(self, tmp_path):
        """Both podcasts and articles are processed in a single run."""
        from wilted.transcribe import TranscriptSegment

        _make_item(tmp_path, guid="article-1", title="Test Article")
        _make_podcast(tmp_path, guid="pod-1", title="Test Podcast")

        audio_file = tmp_path / "data" / "podcasts" / "2" / "episode.mp3"
        audio_file.parent.mkdir(parents=True, exist_ok=True)
        audio_file.write_bytes(b"fake audio data")

        segments = [TranscriptSegment(0.0, 5.0, "Hello")]

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", return_value=segments),
            patch("wilted.prepare.save_transcript"),
            patch("wilted.engine.AudioEngine") as MockEngine,
        ):
            mock_engine = MockEngine.return_value
            mock_engine.get_file_duration.return_value = 5.0

            # Skip TTS for article to keep test fast
            stats = _run_prepare(use_llm=False, skip_tts=True)

        assert stats["prepared"] == 2
        assert stats["errors"] == 0

    def test_one_failure_does_not_stop_others(self, tmp_path):
        """If one item fails, remaining items still get processed."""
        from wilted.db import Item

        # Article with no transcript (will error)
        Item.create(
            feed=None,
            guid="bad-article",
            title="Bad Article",
            discovered_at=_now(),
            item_type="article",
            status="selected",
            status_changed_at=_now(),
            transcript_file=None,
        )
        # Good article
        _make_item(tmp_path, guid="good-article", title="Good Article")

        stats = _run_prepare(use_llm=False, skip_tts=True)

        assert stats["prepared"] == 1
        assert stats["errors"] == 1

        items = {it.guid: it for it in Item.select()}
        assert items["bad-article"].status == "error"
        assert items["good-article"].status == "ready"


# ---------------------------------------------------------------------------
# run_prepare — LLM lifecycle
# ---------------------------------------------------------------------------


class TestPrepareLLMLifecycle:
    def test_llm_loaded_once_and_closed(self, tmp_path):
        """LLM backend is loaded once and closed after all items."""
        _make_item(tmp_path, guid="a1")
        _make_item(tmp_path, guid="a2")

        mock_backend = MagicMock()
        mock_backend.generate.return_value = ('{"promo_indices": []}', 10)

        with (
            patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend),
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            _run_prepare(use_llm=True)

        mock_backend.load.assert_called_once()
        mock_backend.close.assert_called_once()

    def test_llm_failure_continues_without_llm(self, tmp_path):
        """If LLM fails to load, items are still processed without it."""
        _make_item(tmp_path)

        with patch(
            "wilted.handlers._ml.build_llm_backend",
            side_effect=RuntimeError("Model not found"),
        ):
            stats = _run_prepare(use_llm=True, skip_tts=True)

        assert stats["prepared"] == 1

    def test_llm_load_failure_closes_then_continues_without_llm(self, tmp_path):
        """A failed coordinator load still closes the backend and falls back."""
        _make_item(tmp_path)
        mock_backend = MagicMock()
        mock_backend.load.side_effect = RuntimeError("Model not found")

        with patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend):
            stats = _run_prepare(use_llm=True, skip_tts=True)

        assert stats["prepared"] == 1
        mock_backend.close.assert_called_once()

    def test_llm_close_failure_is_logged_without_failing_batch(self, tmp_path):
        """A close-only failure keeps the legacy best-effort unload behavior."""
        _make_item(tmp_path)
        mock_backend = MagicMock()
        mock_backend.generate.return_value = ('{"promo_indices": []}', 10)
        mock_backend.close.side_effect = RuntimeError("close failed")

        with (
            patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend),
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            stats = _run_prepare(use_llm=True)

        assert stats == {"prepared": 1, "errors": 0, "skipped": 0}

    def test_llm_phase_runs_under_coordinator_lease(self, tmp_path):
        """Production prepare LLM work must not bypass ModelCoordinator (INV-1)."""
        from wilted.station_runtime.coordinator import ModelCoordinator

        _make_item(tmp_path)
        coordinator = ModelCoordinator()

        class LeaseCheckingBackend:
            def _assert_lease_held(self) -> None:
                assert coordinator._owner_thread_id == threading.get_ident()

            def load(self) -> None:
                self._assert_lease_held()

            def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
                self._assert_lease_held()
                return ('{"promo_indices": []}', 10)

            def close(self) -> None:
                self._assert_lease_held()

        backend = LeaseCheckingBackend()
        with (
            patch("wilted.handlers._ml.build_llm_backend", return_value=backend),
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            assert _run_prepare(coordinator=coordinator, use_llm=True)["prepared"] == 1


# ---------------------------------------------------------------------------
# INV-2 — load is paired with close, even when processing fails mid-run
# ---------------------------------------------------------------------------


class TestInv2LoadCloseAlwaysPaired:
    """Lock INV-2's coordinator-managed LLM load/close pairing.

    ``ModelCoordinator.run_llm`` must close the backend when item processing
    raises, so a loaded model cannot leak Metal memory on failure.
    """

    def test_close_called_when_item_processing_raises_mid_run(self, tmp_path):
        """A raise from _set_status (invoked before each item's own
        try/except, so the exception escapes the inner per-item guard and
        propagates from Phase B must still result in the coordinator closing
        the LLM backend.
        """
        _make_item(tmp_path, guid="a1")
        _make_item(tmp_path, guid="a2")

        mock_backend = MagicMock()
        mock_backend.load = MagicMock()
        mock_backend.close = MagicMock()
        mock_backend.generate = MagicMock(return_value=('{"promo_indices": []}', 10))

        # Raise only once "processing" status is set for the first item --
        # this happens *before* the item's own try/except in run_prepare's
        # loop body, so the exception is NOT swallowed there and instead
        # propagates out of run_prepare entirely. The coordinator lifecycle
        # must still guarantee close().
        def _raise_on_processing(item, status, error_message=None):
            if status == "processing":
                raise RuntimeError("simulated mid-run failure")

        with (
            patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend),
            patch("wilted.cache.generate_article_cache", return_value=True),
            patch("wilted.prepare._set_status", side_effect=_raise_on_processing),
        ):
            import pytest

            with pytest.raises(RuntimeError, match="simulated mid-run failure"):
                _run_prepare(use_llm=True)

        # The load must have happened, and close() must STILL have run even
        # though run_prepare itself raised out of the try body.
        mock_backend.load.assert_called_once()
        mock_backend.close.assert_called_once()

    def test_load_and_close_are_exactly_paired_on_success(self, tmp_path):
        """No unpaired load: a normal run calls load() exactly once and
        close() exactly once -- never a load with zero or multiple closes.
        """
        _make_item(tmp_path, guid="b1")

        mock_backend = MagicMock()
        mock_backend.load = MagicMock()
        mock_backend.close = MagicMock()
        mock_backend.generate = MagicMock(return_value=('{"promo_indices": []}', 10))

        with (
            patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend),
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            _run_prepare(use_llm=True)

        assert mock_backend.load.call_count == 1
        assert mock_backend.close.call_count == 1


# ---------------------------------------------------------------------------
# Status transitions
# ---------------------------------------------------------------------------


class TestStatusTransitions:
    def test_processing_status_set_during_run(self, tmp_path):
        """Items transition through 'processing' before 'ready'."""
        _make_item(tmp_path)
        _run_prepare(use_llm=False, skip_tts=True)

        # After run, item should be 'ready' — the intermediate 'processing'
        # status is set and then overwritten to 'ready' in the same call
        from wilted.db import Item

        item = Item.get()
        assert item.status == "ready"


# ---------------------------------------------------------------------------
# INV-4 — empty pipeline output must never overwrite existing content
# ---------------------------------------------------------------------------


class TestInv4NoEmptyOverwrite:
    """Guard against the data-loss path where an all-ads / all-promo result
    (a 0-byte audio file or an empty transcript) silently replaces the
    original non-empty source. See INVARIANTS.md INV-4.
    """

    def test_all_ads_preserves_original_audio(self, tmp_path):
        """When ad cutting yields an empty file, the original audio survives."""
        from wilted.db import Item
        from wilted.transcribe import TranscriptSegment

        _make_podcast(tmp_path)

        original_bytes = b"ORIGINAL PODCAST AUDIO PAYLOAD" * 64
        audio_file = tmp_path / "data" / "podcasts" / "1" / "episode.mp3"
        audio_file.parent.mkdir(parents=True, exist_ok=True)
        audio_file.write_bytes(original_bytes)

        segments = [
            TranscriptSegment(0.0, 5.0, "buy our sponsor"),
            TranscriptSegment(5.0, 10.0, "and this other sponsor"),
        ]
        ads = [
            _ads_ad_segment(0.0, 10.0),
        ]

        def _empty_cut(audio_path, ad_segments, output_path, *a, **k):
            # Reproduce the pre-fix defect: return a 0-byte file as "success".
            Path(output_path).touch()
            return Path(output_path)

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", return_value=segments),
            patch("wilted.prepare.save_transcript"),
            patch("wilted.ads.detect_ads", return_value=ads),
            patch("wilted.ads.cut_ads", side_effect=_empty_cut),
            patch("wilted.engine.AudioEngine") as MockEngine,
        ):
            mock_engine = MockEngine.return_value
            mock_engine.get_file_duration.return_value = 10.0

            mock_backend = MagicMock()
            mock_backend.generate.return_value = ("[]", 10)
            with patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend):
                _run_prepare(use_llm=True)

        # The original audio must be untouched: still present and byte-identical.
        assert audio_file.exists()
        assert audio_file.read_bytes() == original_bytes
        assert audio_file.stat().st_size > 0
        # No stray empty cleaned_ temp file left behind.
        assert not (audio_file.parent / f"cleaned_{audio_file.name}").exists()

        items = list(Item.select().where(Item.item_type == "podcast_episode"))
        assert items[0].status == "ready"

    def test_cut_ads_raises_when_nothing_to_keep(self, tmp_path):
        """cut_ads no longer returns a silent 0-byte file when all is ads."""
        from wilted.ads import EmptyCutResultError, cut_ads

        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio data with real bytes")

        output = tmp_path / "output.mp3"
        # One ad spanning the whole clip -> _compute_keep_segments returns [].
        ads = [_ads_ad_segment(0.0, 300.0)]

        probe_result = MagicMock()
        probe_result.stdout = "300.0\n"

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run", return_value=probe_result),
        ):
            import pytest

            with pytest.raises(EmptyCutResultError):
                cut_ads(audio, ads, output, buffer_seconds=0.5)

        # No 0-byte file should have been created at the output path.
        assert not output.exists()

    def test_cut_ads_raises_when_all_keep_segments_zero_width(self, tmp_path):
        """cut_ads raises when keep_segments is non-empty but every segment
        has duration <= 0 after buffer clamping, so the extraction loop
        skips all of them and segment_files ends up empty (ads.py:493).
        """
        from wilted.ads import EmptyCutResultError, cut_ads

        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio data with real bytes")

        output = tmp_path / "output.mp3"
        # Ad segments here are irrelevant since _compute_keep_segments is
        # mocked directly; a non-empty list just satisfies the
        # `if not ad_segments` short-circuit so cut_ads reaches the ffprobe
        # call and the extraction loop.
        ads = [_ads_ad_segment(0.0, 10.0)]

        probe_result = MagicMock()
        probe_result.stdout = "300.0\n"

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run", return_value=probe_result),
            # Non-empty keep_segments (bypasses the :458 raise) but every
            # segment is zero-width, so the extraction loop's
            # `if duration <= 0: continue` skips all of them.
            patch("wilted.ads._compute_keep_segments", return_value=[(5.0, 5.0), (10.0, 10.0)]),
        ):
            import pytest

            with pytest.raises(EmptyCutResultError, match="No non-empty keep-segments"):
                cut_ads(audio, ads, output, buffer_seconds=0.5)

        # No 0-byte file should have been created at the output path.
        assert not output.exists()

    def test_all_promo_preserves_original_transcript(self, tmp_path):
        """When every paragraph is promo, the original transcript survives."""
        from wilted.db import Item

        articles_dir = tmp_path / "data" / "articles"
        articles_dir.mkdir(parents=True, exist_ok=True)
        transcript = articles_dir / "all_promo.txt"
        original_text = "Subscribe now!\n\nFollow us on social media.\n\nBuy our merch."
        transcript.write_text(original_text, encoding="utf-8")

        Item.create(
            feed=None,
            guid="all-promo",
            title="All Promo Article",
            discovered_at=_now(),
            item_type="article",
            status="selected",
            status_changed_at=_now(),
            transcript_file=str(transcript),
        )

        mock_backend = MagicMock()
        mock_backend.generate.return_value = ("{}", 10)

        with (
            patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend),
            # remove_promos flags every paragraph -> returns "".
            patch("wilted.ads.remove_promos", return_value=""),
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            _run_prepare(use_llm=True)

        # The original transcript must remain intact, not truncated to empty.
        assert transcript.exists()
        assert transcript.read_text(encoding="utf-8") == original_text
        assert transcript.stat().st_size > 0


# ---------------------------------------------------------------------------
# INV-5 — runtime paths must resolve through the live wilted.DATA_DIR at
# call time, never a value captured at import
# ---------------------------------------------------------------------------


class TestInv5LiveDataDirResolution:
    """Locks INV-5: `download.get_podcast_dir` (and by extension every
    prepare.py/download.py/cache.py call site) must resolve `DATA_DIR`
    through the live `wilted.DATA_DIR` module attribute at call time.

    If a module instead captured the value at import time via
    `from wilted import DATA_DIR` and used the bare name directly in a
    function body, this test fails: the bare name was bound to the
    `wilted.DATA_DIR` Path object that existed when `wilted.download` was
    first imported (which happens once, e.g. during the autouse
    `isolated_data` fixture's own import chain or an earlier test module),
    so re-pointing `wilted.DATA_DIR` here would never be observed by the
    already-imported module — the returned path would still fall under the
    stale directory instead of `new_dir`. See INVARIANTS.md INV-5.
    """

    def test_get_podcast_dir_resolves_live_data_dir(self, tmp_path, monkeypatch):
        """After import, repointing wilted.DATA_DIR must change the path
        returned by download.get_podcast_dir() -- proving the module reads
        wilted.DATA_DIR at call time rather than a name bound at import.
        """
        import wilted
        from wilted.download import get_podcast_dir

        # Deliberately distinct from the autouse `isolated_data` tmp dir so a
        # stale import-time capture of the *original* isolated_data dir would
        # not accidentally satisfy this assertion.
        new_dir = tmp_path / "distinct_new_data_dir"
        new_dir.mkdir()
        assert new_dir != wilted.DATA_DIR

        monkeypatch.setattr(wilted, "DATA_DIR", new_dir)

        result = get_podcast_dir(123)

        assert result == new_dir / "podcasts" / "123"
        assert new_dir in result.parents

    def test_prepare_podcast_transcript_path_resolves_live_data_dir(self, tmp_path, monkeypatch):
        """run_prepare's podcast path (prepare.py:93, transcript_dir) must
        build its path under a freshly-repointed wilted.DATA_DIR, not the
        DATA_DIR captured whenever wilted.prepare was first imported.
        """
        import wilted
        from wilted.transcribe import TranscriptSegment

        new_dir = tmp_path / "another_distinct_data_dir"
        new_dir.mkdir()
        assert new_dir != wilted.DATA_DIR
        monkeypatch.setattr(wilted, "DATA_DIR", new_dir)

        _make_podcast(tmp_path)

        audio_file = new_dir / "podcasts" / "1" / "episode.mp3"
        audio_file.parent.mkdir(parents=True, exist_ok=True)
        audio_file.write_bytes(b"fake audio data")

        segments = [TranscriptSegment(0.0, 5.0, "Hello world")]

        with (
            patch("wilted.prepare.download_podcast", return_value=audio_file),
            patch("wilted.prepare.get_transcript", return_value=segments),
            patch("wilted.engine.AudioEngine") as MockEngine,
        ):
            mock_engine = MockEngine.return_value
            mock_engine.get_file_duration.return_value = 5.0
            _run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select().where(Item.item_type == "podcast_episode"))
        transcript_path = Path(items[0].transcript_file)
        assert new_dir in transcript_path.parents
        assert transcript_path == new_dir / "transcripts" / "1_transcript.json"
        assert transcript_path.exists()


# ---------------------------------------------------------------------------
# PM-5 — all Tier-3 transcription completes before the LLM is ever loaded
# ---------------------------------------------------------------------------


class TestPm5TranscribeBeforeLlm:
    """Locks PM-5: the Tier-3 isolated GPU transcription child must never run
    while the LLM is (or could be) resident.

    `run_prepare` now transcribes every podcast (Phase A) BEFORE calling
    `llm_backend.load()` (Phase B). This test records a single ordered event
    log: each `get_transcript` call appends ``("transcribe", item_id)`` and
    the backend's `load()` appends ``("llm_load",)``. The gate is that EVERY
    transcribe event precedes the (single) llm_load event.

    Why it bites against the OLD structure: previously `run_prepare` called
    `llm_backend.load()` up front and held it resident across the whole
    podcast loop, so `("llm_load",)` was appended FIRST and every
    `("transcribe", ...)` event came AFTER it — the assertion below (all
    transcribe indices < the llm_load index) would fail. Sanity-checked
    below via `_llm_load_index` being 0 in that ordering.
    """

    def test_all_transcription_completes_before_llm_loads(self, tmp_path):
        from wilted.db import Feed, Item
        from wilted.transcribe import TranscriptSegment

        # Two selected podcasts so Phase A must transcribe both before load.
        # Distinct feed_urls: feeds.feed_url is UNIQUE.
        now = _now()
        for suffix in ("a", "b"):
            feed = Feed.create(
                title=f"Test Podcast {suffix}",
                feed_url=f"https://example.com/feed-{suffix}.xml",
                feed_type="podcast",
                enabled=True,
                created_at=now,
                updated_at=now,
            )
            Item.create(
                feed=feed,
                guid=f"pod-{suffix}",
                title=f"Podcast {suffix.upper()}",
                discovered_at=now,
                item_type="podcast_episode",
                status="selected",
                status_changed_at=now,
                enclosure_url="https://example.com/episode.mp3",
                enclosure_type="audio/mpeg",
            )

        audio_files = {}
        for item_id in (1, 2):
            audio_file = tmp_path / "data" / "podcasts" / str(item_id) / "episode.mp3"
            audio_file.parent.mkdir(parents=True, exist_ok=True)
            audio_file.write_bytes(b"fake audio data")
            audio_files[item_id] = audio_file

        events: list[tuple] = []

        segments = [TranscriptSegment(0.0, 5.0, "Hello world")]

        def _record_transcribe(*, item_id, **kwargs):
            events.append(("transcribe", item_id))
            return segments

        # The LLM backend: load() records the ("llm_load",) event so its
        # ordering relative to the transcribe events is observable.
        mock_backend = MagicMock()
        mock_backend.load = MagicMock(side_effect=lambda: events.append(("llm_load",)))
        mock_backend.close = MagicMock()
        mock_backend.generate = MagicMock(return_value=("[]", 10))

        def _download(item_id, url):
            return audio_files[item_id]

        with (
            patch("wilted.prepare.download_podcast", side_effect=_download),
            patch("wilted.prepare.get_transcript", side_effect=_record_transcribe),
            patch("wilted.prepare.save_transcript"),
            patch("wilted.prepare._get_feed_xml", return_value=None),
            patch("wilted.ads.detect_ads", return_value=[]),
            patch("wilted.engine.AudioEngine") as MockEngine,
            patch("wilted.handlers._ml.build_llm_backend", return_value=mock_backend),
        ):
            mock_engine = MockEngine.return_value
            mock_engine.get_file_duration.return_value = 5.0
            stats = _run_prepare(use_llm=True, skip_tts=True)

        # Sanity: the log actually captured both transcribe events and exactly
        # one llm_load event, and both podcasts were prepared.
        transcribe_indices = [i for i, e in enumerate(events) if e[0] == "transcribe"]
        llm_load_indices = [i for i, e in enumerate(events) if e[0] == "llm_load"]
        assert len(transcribe_indices) == 2, events
        assert len(llm_load_indices) == 1, events
        assert stats["prepared"] == 2
        assert stats["errors"] == 0

        # PM-5 gate: every transcription happened strictly before the LLM
        # loaded. Against the OLD load-LLM-first structure, llm_load would be
        # at index 0 and this would fail.
        llm_load_index = llm_load_indices[0]
        assert all(t_idx < llm_load_index for t_idx in transcribe_indices), (
            f"Transcription must complete before LLM load; got event order: {events}"
        )


# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------


class TestCmdPrepare:
    def test_cmd_prepare_calls_run_prepare_via_runner(self):
        """cmd_prepare dispatches to run_prepare_via_runner."""
        from wilted.cli import cmd_prepare

        with patch("wilted.pipeline_submit.run_prepare_via_runner", return_value={"prepared": 2, "errors": 0}) as mock:
            cmd_prepare([])

        mock.assert_called_once()

    def test_cmd_prepare_no_llm_flag(self):
        """--no-llm flag passed through to run_prepare_via_runner."""
        from wilted.cli import cmd_prepare

        with patch("wilted.pipeline_submit.run_prepare_via_runner", return_value={"prepared": 0, "errors": 0}) as mock:
            cmd_prepare(["--no-llm"])

        _, kwargs = mock.call_args
        assert kwargs["use_llm"] is False
