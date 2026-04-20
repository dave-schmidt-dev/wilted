"""Tests for transcript ingestion — three-tier sourcing (transcribe.py)."""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from wilted.transcribe import (
    TranscriptionError,
    TranscriptSegment,
    extract_transcript_from_url,
    fetch_transcript_from_rss,
    get_transcript,
    load_transcript,
    parse_podcast_json,
    parse_srt,
    parse_vtt,
    save_transcript,
    segments_to_text,
    transcribe_audio,
)

# ---------------------------------------------------------------------------
# VTT parsing
# ---------------------------------------------------------------------------


class TestParseVtt:
    def test_basic_vtt(self):
        content = """\
WEBVTT

00:00:01.000 --> 00:00:04.000
Welcome to the show.

00:00:04.500 --> 00:00:08.200
Today we're talking about Python.
"""
        segments = parse_vtt(content)
        assert len(segments) == 2
        assert segments[0].start_s == 1.0
        assert segments[0].end_s == 4.0
        assert segments[0].text == "Welcome to the show."
        assert segments[1].start_s == 4.5
        assert segments[1].end_s == 8.2
        assert segments[1].text == "Today we're talking about Python."

    def test_note_lines_skipped(self):
        content = """\
WEBVTT

NOTE This is a comment

00:00:01.000 --> 00:00:04.000
Hello world.
"""
        segments = parse_vtt(content)
        assert len(segments) == 1
        assert segments[0].text == "Hello world."

    def test_empty_lines_handled(self):
        content = """\
WEBVTT



00:00:01.000 --> 00:00:03.000
First cue.


00:00:05.000 --> 00:00:07.000
Second cue.
"""
        segments = parse_vtt(content)
        assert len(segments) == 2

    def test_timestamps_with_hours(self):
        content = """\
WEBVTT

01:30:00.000 --> 01:30:05.500
Deep into the episode.
"""
        segments = parse_vtt(content)
        assert len(segments) == 1
        assert segments[0].start_s == 5400.0
        assert segments[0].end_s == 5405.5

    def test_multiline_cues(self):
        content = """\
WEBVTT

00:00:01.000 --> 00:00:05.000
This is line one.
This is line two.
"""
        segments = parse_vtt(content)
        assert len(segments) == 1
        assert segments[0].text == "This is line one. This is line two."

    def test_multiline_note_block(self):
        content = """\
WEBVTT

NOTE
This is a multi-line
note block

00:00:01.000 --> 00:00:03.000
After the note.
"""
        segments = parse_vtt(content)
        assert len(segments) == 1
        assert segments[0].text == "After the note."

    def test_cue_identifiers(self):
        """VTT cues can have optional identifiers before the timestamp line."""
        content = """\
WEBVTT

cue-1
00:00:01.000 --> 00:00:04.000
First cue.

cue-2
00:00:04.500 --> 00:00:08.000
Second cue.
"""
        segments = parse_vtt(content)
        assert len(segments) == 2
        assert segments[0].text == "First cue."
        assert segments[1].text == "Second cue."


# ---------------------------------------------------------------------------
# SRT parsing
# ---------------------------------------------------------------------------


class TestParseSrt:
    def test_basic_srt(self):
        content = """\
1
00:00:01,000 --> 00:00:04,000
Welcome to the show.

2
00:00:04,500 --> 00:00:08,200
Today we're talking about Python.
"""
        segments = parse_srt(content)
        assert len(segments) == 2
        assert segments[0].start_s == 1.0
        assert segments[0].end_s == 4.0
        assert segments[0].text == "Welcome to the show."
        assert segments[1].start_s == 4.5
        assert segments[1].end_s == 8.2

    def test_comma_decimal_separator(self):
        content = """\
1
00:01:30,500 --> 00:01:35,750
Ninety seconds in.
"""
        segments = parse_srt(content)
        assert len(segments) == 1
        assert segments[0].start_s == 90.5
        assert segments[0].end_s == 95.75

    def test_multiline_srt_text(self):
        content = """\
1
00:00:01,000 --> 00:00:05,000
Line one.
Line two.
"""
        segments = parse_srt(content)
        assert len(segments) == 1
        assert segments[0].text == "Line one. Line two."


# ---------------------------------------------------------------------------
# Podcast JSON parsing
# ---------------------------------------------------------------------------


class TestParsePodcastJson:
    def test_segments_wrapper_format(self):
        data = {
            "segments": [
                {"startTime": 1.0, "endTime": 4.0, "body": "Welcome to the show."},
                {"startTime": 4.5, "endTime": 8.2, "body": "Let's get started."},
            ]
        }
        segments = parse_podcast_json(json.dumps(data))
        assert len(segments) == 2
        assert segments[0].start_s == 1.0
        assert segments[0].end_s == 4.0
        assert segments[0].text == "Welcome to the show."

    def test_flat_array_format(self):
        data = [
            {"startTime": 0.0, "endTime": 3.0, "body": "Hello."},
            {"startTime": 3.5, "endTime": 7.0, "body": "Goodbye."},
        ]
        segments = parse_podcast_json(json.dumps(data))
        assert len(segments) == 2
        assert segments[0].text == "Hello."
        assert segments[1].text == "Goodbye."

    def test_empty_body_skipped(self):
        data = [
            {"startTime": 0.0, "endTime": 1.0, "body": ""},
            {"startTime": 1.0, "endTime": 2.0, "body": "Real text."},
        ]
        segments = parse_podcast_json(json.dumps(data))
        assert len(segments) == 1
        assert segments[0].text == "Real text."


# ---------------------------------------------------------------------------
# Tier 1: RSS transcript fetch
# ---------------------------------------------------------------------------

_FEED_XML_TEMPLATE = """\
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
  <channel>
    <title>Test Podcast</title>
    <item>
      <guid>ep-1</guid>
      <title>Episode 1</title>
      <podcast:transcript url="{url}" type="{mime}" />
    </item>
    <item>
      <guid>ep-2</guid>
      <title>Episode 2 (no transcript)</title>
    </item>
  </channel>
</rss>
"""


class TestFetchTranscriptFromRss:
    @patch("wilted.transcribe.urlopen")
    def test_fetches_vtt_transcript(self, mock_urlopen):
        vtt_content = """\
WEBVTT

00:00:01.000 --> 00:00:04.000
Hello from RSS.
"""
        mock_resp = MagicMock()
        mock_resp.read.return_value = vtt_content.encode()
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        feed_xml = _FEED_XML_TEMPLATE.format(url="https://example.com/transcript.vtt", mime="text/vtt")
        segments = fetch_transcript_from_rss(feed_xml, "ep-1")

        assert segments is not None
        assert len(segments) == 1
        assert segments[0].text == "Hello from RSS."

    def test_returns_none_when_guid_not_found(self):
        feed_xml = _FEED_XML_TEMPLATE.format(url="https://example.com/t.vtt", mime="text/vtt")
        result = fetch_transcript_from_rss(feed_xml, "nonexistent-guid")
        assert result is None

    def test_returns_none_when_no_transcript_tag(self):
        feed_xml = _FEED_XML_TEMPLATE.format(url="https://example.com/t.vtt", mime="text/vtt")
        result = fetch_transcript_from_rss(feed_xml, "ep-2")
        assert result is None

    def test_returns_none_for_invalid_xml(self):
        result = fetch_transcript_from_rss("not valid xml <><>", "ep-1")
        assert result is None

    @patch("wilted.transcribe.urlopen")
    def test_detects_format_from_extension(self, mock_urlopen):
        srt_content = """\
1
00:00:01,000 --> 00:00:03,000
From SRT.
"""
        mock_resp = MagicMock()
        mock_resp.read.return_value = srt_content.encode()
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        # Empty mime type, rely on .srt extension
        feed_xml = _FEED_XML_TEMPLATE.format(url="https://example.com/transcript.srt", mime="")
        segments = fetch_transcript_from_rss(feed_xml, "ep-1")

        assert segments is not None
        assert len(segments) == 1
        assert segments[0].text == "From SRT."


# ---------------------------------------------------------------------------
# Tier 2: Web page transcript
# ---------------------------------------------------------------------------


class TestExtractTranscriptFromUrl:
    @patch("wilted.transcribe.trafilatura")
    def test_sufficient_text_returns_segments(self, mock_traf):
        # Build a long-enough transcript (>= 500 words)
        long_text = "Word " * 600 + "\n\nSecond paragraph here."
        mock_traf.fetch_url.return_value = "<html>...</html>"
        mock_traf.extract.return_value = long_text

        segments = extract_transcript_from_url("https://example.com/episode")

        assert segments is not None
        assert len(segments) >= 1
        # All segments should have valid timestamps
        for seg in segments:
            assert seg.start_s >= 0
            assert seg.end_s > seg.start_s

    @patch("wilted.transcribe.trafilatura")
    def test_short_text_returns_none(self, mock_traf):
        mock_traf.fetch_url.return_value = "<html>...</html>"
        mock_traf.extract.return_value = "Just a few words of show notes."

        result = extract_transcript_from_url("https://example.com/episode")
        assert result is None

    @patch("wilted.transcribe.trafilatura")
    def test_fetch_failure_returns_none(self, mock_traf):
        mock_traf.fetch_url.return_value = None

        result = extract_transcript_from_url("https://example.com/episode")
        assert result is None

    @patch("wilted.transcribe.trafilatura")
    def test_custom_min_words(self, mock_traf):
        text = "Word " * 50
        mock_traf.fetch_url.return_value = "<html>...</html>"
        mock_traf.extract.return_value = text

        # Default min_words=500 should reject this
        assert extract_transcript_from_url("https://example.com/ep") is None

        # Custom min_words=10 should accept it
        segments = extract_transcript_from_url("https://example.com/ep", min_words=10)
        assert segments is not None


# ---------------------------------------------------------------------------
# Tier 3: Local transcription
# ---------------------------------------------------------------------------


class TestTranscribeAudio:
    @patch.dict("sys.modules", {"parakeet_mlx": MagicMock()})
    def test_transcribes_audio(self):
        import sys

        mock_parakeet = sys.modules["parakeet_mlx"]
        mock_model = MagicMock()
        mock_parakeet.from_pretrained.return_value = mock_model

        mock_result = SimpleNamespace(
            segments=[
                {"start": 0.0, "end": 3.0, "text": "Hello world."},
                {"start": 3.5, "end": 7.0, "text": "Testing transcription."},
            ]
        )
        mock_model.transcribe.return_value = mock_result

        segments = transcribe_audio(Path("/tmp/test.mp3"))

        assert len(segments) == 2
        assert segments[0].text == "Hello world."
        assert segments[1].start_s == 3.5

    def test_import_error_raises_transcription_error(self):
        with pytest.raises(TranscriptionError, match="parakeet_mlx is not installed"):
            # Ensure parakeet_mlx is not importable
            with patch.dict("sys.modules", {"parakeet_mlx": None}):
                transcribe_audio(Path("/tmp/test.mp3"))

    @patch.dict("sys.modules", {"parakeet_mlx": MagicMock()})
    def test_empty_segments_raises_error(self):
        import sys

        mock_parakeet = sys.modules["parakeet_mlx"]
        mock_model = MagicMock()
        mock_parakeet.from_pretrained.return_value = mock_model
        mock_model.transcribe.return_value = SimpleNamespace(segments=[])

        with pytest.raises(TranscriptionError, match="no segments"):
            transcribe_audio(Path("/tmp/test.mp3"))


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------


class TestGetTranscript:
    @patch("wilted.transcribe.fetch_transcript_from_rss")
    def test_rss_tier_succeeds(self, mock_rss):
        mock_rss.return_value = [TranscriptSegment(start_s=0.0, end_s=3.0, text="From RSS.")]

        segments = get_transcript(item_id=1, guid="ep-1", feed_xml="<rss>...</rss>")

        assert len(segments) == 1
        assert segments[0].text == "From RSS."
        mock_rss.assert_called_once()

    @patch("wilted.transcribe.extract_transcript_from_url")
    @patch("wilted.transcribe.fetch_transcript_from_rss")
    def test_rss_fails_web_succeeds(self, mock_rss, mock_web):
        mock_rss.return_value = None
        mock_web.return_value = [TranscriptSegment(start_s=0.0, end_s=5.0, text="From web.")]

        segments = get_transcript(
            item_id=1,
            guid="ep-1",
            feed_xml="<rss>...</rss>",
            episode_url="https://example.com/ep",
        )

        assert len(segments) == 1
        assert segments[0].text == "From web."

    @patch("wilted.transcribe.transcribe_audio")
    @patch("wilted.transcribe.extract_transcript_from_url")
    @patch("wilted.transcribe.fetch_transcript_from_rss")
    def test_rss_tier_skips_other_tiers_on_success(self, mock_rss, mock_web, mock_audio):
        mock_rss.return_value = [TranscriptSegment(start_s=0.0, end_s=1.0, text="RSS wins.")]

        get_transcript(
            item_id=1,
            guid="ep-1",
            feed_xml="<rss>...</rss>",
            episode_url="https://example.com/ep",
            audio_path=Path("/tmp/test.mp3"),
        )

        mock_web.assert_not_called()
        mock_audio.assert_not_called()

    def test_all_tiers_fail_raises_error(self):
        with pytest.raises(TranscriptionError, match="All transcript tiers failed"):
            get_transcript(item_id=99)

    @patch("wilted.transcribe.transcribe_audio")
    @patch("wilted.transcribe.extract_transcript_from_url")
    @patch("wilted.transcribe.fetch_transcript_from_rss")
    def test_falls_through_to_local_model(self, mock_rss, mock_web, mock_audio):
        mock_rss.return_value = None
        mock_web.return_value = None
        mock_audio.return_value = [TranscriptSegment(start_s=0.0, end_s=2.0, text="From model.")]

        segments = get_transcript(
            item_id=1,
            guid="ep-1",
            feed_xml="<rss>...</rss>",
            episode_url="https://example.com/ep",
            audio_path=Path("/tmp/test.mp3"),
        )

        assert segments[0].text == "From model."
        mock_rss.assert_called_once()
        mock_web.assert_called_once()
        mock_audio.assert_called_once()


# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------


class TestSaveLoadTranscript:
    def test_round_trip(self, tmp_path):
        segments = [
            TranscriptSegment(start_s=0.0, end_s=3.0, text="Hello."),
            TranscriptSegment(start_s=3.5, end_s=7.0, text="World."),
        ]
        path = tmp_path / "transcript.json"

        save_transcript(segments, path)
        loaded = load_transcript(path)

        assert loaded is not None
        assert len(loaded) == 2
        assert loaded[0].start_s == 0.0
        assert loaded[0].text == "Hello."
        assert loaded[1].end_s == 7.0

    def test_load_nonexistent_returns_none(self, tmp_path):
        result = load_transcript(tmp_path / "missing.json")
        assert result is None

    def test_load_corrupt_json_returns_none(self, tmp_path):
        path = tmp_path / "bad.json"
        path.write_text("not valid json {{{")
        result = load_transcript(path)
        assert result is None


class TestSegmentsToText:
    def test_joins_with_spaces(self):
        segments = [
            TranscriptSegment(start_s=0.0, end_s=1.0, text="Hello"),
            TranscriptSegment(start_s=1.0, end_s=2.0, text="world"),
            TranscriptSegment(start_s=2.0, end_s=3.0, text="today."),
        ]
        assert segments_to_text(segments) == "Hello world today."

    def test_empty_list(self):
        assert segments_to_text([]) == ""

    def test_single_segment(self):
        segments = [TranscriptSegment(start_s=0.0, end_s=1.0, text="Only one.")]
        assert segments_to_text(segments) == "Only one."
