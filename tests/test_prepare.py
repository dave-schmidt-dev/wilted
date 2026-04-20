"""Tests for wilted.prepare — content preparation orchestrator."""

from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

from wilted.prepare import run_prepare


def _now():
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


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
        stats = run_prepare(use_llm=False)
        assert stats == {"prepared": 0, "errors": 0, "skipped": 0}


# ---------------------------------------------------------------------------
# run_prepare — article pipeline
# ---------------------------------------------------------------------------


class TestPrepareArticle:
    def test_article_skip_tts_marks_ready(self, tmp_path):
        """With skip_tts=True, articles are marked ready without TTS generation."""
        item = _make_item(tmp_path)
        stats = run_prepare(use_llm=False, skip_tts=True)

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
        stats = run_prepare(use_llm=False)
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
        stats = run_prepare(use_llm=False)
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
            patch("wilted.llm.create_backend", return_value=mock_backend) as mock_create,
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            stats = run_prepare(use_llm=True)

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
        stats = run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select())
        assert items[0].status == "error"
        assert stats["errors"] == 1

    def test_podcast_download_failure_errors(self, tmp_path):
        """Podcast with failed download transitions to error."""
        from wilted.download import DownloadError

        _make_podcast(tmp_path)

        with patch("wilted.prepare.download_podcast", side_effect=DownloadError("HTTP 404")):
            stats = run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select().where(Item.item_type == "podcast_episode"))
        assert items[0].status == "error"
        assert "Download failed" in (items[0].error_message or "")
        assert stats["errors"] == 1

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
            stats = run_prepare(use_llm=False)

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
            run_prepare(use_llm=False)

        from wilted.db import Item

        items = list(Item.select().where(Item.item_type == "podcast_episode"))
        assert items[0].status == "error"
        assert "Transcription failed" in (items[0].error_message or "")


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
            stats = run_prepare(use_llm=False, skip_tts=True)

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

        stats = run_prepare(use_llm=False, skip_tts=True)

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
            patch("wilted.llm.create_backend", return_value=mock_backend),
            patch("wilted.cache.generate_article_cache", return_value=True),
        ):
            run_prepare(use_llm=True)

        mock_backend.load.assert_called_once()
        mock_backend.close.assert_called_once()

    def test_llm_failure_continues_without_llm(self, tmp_path):
        """If LLM fails to load, items are still processed without it."""
        _make_item(tmp_path)

        with patch(
            "wilted.llm.create_backend",
            side_effect=RuntimeError("Model not found"),
        ):
            stats = run_prepare(use_llm=True, skip_tts=True)

        assert stats["prepared"] == 1


# ---------------------------------------------------------------------------
# Status transitions
# ---------------------------------------------------------------------------


class TestStatusTransitions:
    def test_processing_status_set_during_run(self, tmp_path):
        """Items transition through 'processing' before 'ready'."""
        _make_item(tmp_path)
        run_prepare(use_llm=False, skip_tts=True)

        # After run, item should be 'ready' — the intermediate 'processing'
        # status is set and then overwritten to 'ready' in the same call
        from wilted.db import Item

        item = Item.get()
        assert item.status == "ready"


# ---------------------------------------------------------------------------
# CLI dispatch
# ---------------------------------------------------------------------------


class TestCmdPrepare:
    def test_cmd_prepare_calls_run_prepare(self):
        """cmd_prepare dispatches to run_prepare."""
        from wilted.cli import cmd_prepare

        with patch("wilted.prepare.run_prepare", return_value={"prepared": 2, "errors": 0}) as mock:
            cmd_prepare([])

        mock.assert_called_once()

    def test_cmd_prepare_no_llm_flag(self):
        """--no-llm flag passed through to run_prepare."""
        from wilted.cli import cmd_prepare

        with patch("wilted.prepare.run_prepare", return_value={"prepared": 0, "errors": 0}) as mock:
            cmd_prepare(["--no-llm"])

        _, kwargs = mock.call_args
        assert kwargs["use_llm"] is False
