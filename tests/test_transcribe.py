"""Tests for transcript ingestion — three-tier sourcing (transcribe.py)."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from speech_stack import client, isolated

from wilted.transcribe import (
    TranscriptionAborted,
    TranscriptionError,
    TranscriptionTimeout,
    TranscriptionWorkerError,
    TranscriptSegment,
    evict_stt_model,
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

pytestmark = pytest.mark.usefixtures("execution_capability")

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
    def test_private_transcript_fetch_failure_redacts_url_and_traceback(self, mock_urlopen, caplog):
        private_url = "https://private.example/transcript.vtt?credential=hidden"
        mock_urlopen.side_effect = RuntimeError(private_url)
        feed_xml = _FEED_XML_TEMPLATE.format(url=private_url, mime="text/vtt")

        result = fetch_transcript_from_rss(feed_xml, "ep-1", redact_urls=True)

        assert result is None
        assert private_url not in caplog.text
        assert "[private transcript URL]" in caplog.text

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

    @patch("wilted.transcribe.extract_transcript_from_url")
    @patch("wilted.transcribe.fetch_transcript_from_rss")
    def test_rss_tier_skips_other_tiers_on_success(self, mock_rss, mock_web):
        mock_rss.return_value = [TranscriptSegment(start_s=0.0, end_s=1.0, text="RSS wins.")]
        tier3 = MagicMock()

        get_transcript(
            item_id=1,
            guid="ep-1",
            feed_xml="<rss>...</rss>",
            episode_url="https://example.com/ep",
            audio_path=Path("/tmp/test.mp3"),
            tier3_transcribe=tier3,
        )

        mock_web.assert_not_called()
        tier3.assert_not_called()

    def test_all_tiers_fail_raises_error(self):
        with pytest.raises(TranscriptionError, match="All transcript tiers failed"):
            get_transcript(item_id=99)

    @patch("wilted.transcribe.extract_transcript_from_url")
    @patch("wilted.transcribe.fetch_transcript_from_rss")
    def test_falls_through_to_local_model(self, mock_rss, mock_web):
        mock_rss.return_value = None
        mock_web.return_value = None
        tier3 = MagicMock(
            return_value=[TranscriptSegment(start_s=0.0, end_s=2.0, text="From model.")],
        )

        segments = get_transcript(
            item_id=1,
            guid="ep-1",
            feed_xml="<rss>...</rss>",
            episode_url="https://example.com/ep",
            audio_path=Path("/tmp/test.mp3"),
            tier3_transcribe=tier3,
        )

        assert segments[0].text == "From model."
        mock_rss.assert_called_once()
        mock_web.assert_called_once()
        tier3.assert_called_once()


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

    def test_round_trip_preserves_tokens_and_old_cache_remains_readable(self, tmp_path):
        from wilted.transcribe import TranscriptToken

        path = tmp_path / "transcript.json"
        save_transcript(
            [
                TranscriptSegment(
                    start_s=1.0,
                    end_s=2.0,
                    text="Hello",
                    tokens=(TranscriptToken("Hello", 1.0, 2.0),),
                )
            ],
            path,
        )
        assert load_transcript(path) == [
            TranscriptSegment(
                start_s=1.0,
                end_s=2.0,
                text="Hello",
                tokens=(TranscriptToken("Hello", 1.0, 2.0),),
            )
        ]

        path.write_text('[{"start_s": 3.0, "end_s": 4.0, "text": "Old cache"}]')
        loaded = load_transcript(path)
        assert loaded is not None
        assert loaded[0].tokens is None

    def test_load_corrupt_json_returns_none(self, tmp_path):
        path = tmp_path / "bad.json"
        path.write_text("not valid json {{{")
        result = load_transcript(path)
        assert result is None


class TestSaveTranscriptAtomicity:
    """S2: ``save_transcript`` writes via temp-file + ``os.replace`` so a
    crash mid-write can never leave a partial/empty transcript for a later
    resume to trust. See INVARIANTS.md INV-4.
    """

    def test_no_tmp_file_left_behind_after_save(self, tmp_path):
        """Happy path: content round-trips and no ``.tmp`` litter remains."""
        segments = [TranscriptSegment(start_s=0.0, end_s=3.0, text="Hello.")]
        path = tmp_path / "transcript.json"

        save_transcript(segments, path)

        assert load_transcript(path) == segments
        assert not (tmp_path / "transcript.json.tmp").exists()
        assert list(tmp_path.glob("*.tmp")) == []

    def test_failed_replace_leaves_existing_transcript_intact(self, tmp_path, monkeypatch):
        """INV-4 crash-safety: if the swap fails (simulating a crash between
        the temp write and the rename), the pre-existing good transcript on
        disk must survive untouched — never truncated/emptied — and the
        temp file must not linger.
        """
        path = tmp_path / "transcript.json"
        original_segments = [TranscriptSegment(start_s=0.0, end_s=1.0, text="Original.")]
        save_transcript(original_segments, path)
        original_bytes = path.read_bytes()

        def _boom(_src, _dst):
            raise OSError("simulated crash between temp write and rename")

        monkeypatch.setattr("wilted.transcribe.os.replace", _boom)

        new_segments = [TranscriptSegment(start_s=9.0, end_s=10.0, text="Replacement.")]
        with pytest.raises(OSError, match="simulated crash"):
            save_transcript(new_segments, path)

        # Original file is byte-identical -- never truncated or emptied.
        assert path.read_bytes() == original_bytes
        assert load_transcript(path) == original_segments
        # No .tmp litter left behind from the aborted write.
        assert not (tmp_path / "transcript.json.tmp").exists()
        assert list(tmp_path.glob("*.tmp")) == []

    def test_save_empty_segments_behavior_unchanged(self, tmp_path):
        """Documents current behavior: ``save_transcript`` has no
        empty-content guard of its own -- INV-4's empty-result protection
        for transcripts lives upstream in ``get_transcript`` (which raises
        ``TranscriptionError`` rather than ever returning empty segments).
        This atomicity change must not alter that: an empty list still
        writes/round-trips as an empty list, same as before.
        """
        path = tmp_path / "transcript.json"
        save_transcript([], path)
        assert path.read_text(encoding="utf-8") == "[]"
        assert load_transcript(path) == []


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


class TestEvictSttModel:
    """The post-batch evict hint (PM-5/INV-2 co-residency avoidance).

    M2 daemon cutover: there is no backend guard anymore — the daemon is the
    only route, so evict always attempts ``client.evict("stt")``, swallowing
    ``DaemonUnavailable`` if the daemon is already gone.
    """

    def test_evicts_the_resident_model(self):
        with patch("wilted.transcribe.client.evict") as mock_evict:
            evict_stt_model()
        mock_evict.assert_called_once_with("stt")

    def test_swallows_daemon_unavailable(self):
        """If the daemon is already gone, there is nothing resident — swallow it."""
        with patch(
            "wilted.transcribe.client.evict",
            side_effect=client.DaemonUnavailable("gone"),
        ):
            evict_stt_model()  # must not raise

    @pytest.mark.parametrize(
        "fault",
        [
            client.ConnectionLost("stream closed after 0 of 4 expected bytes (peer gone)"),
            client.Timeout("broker did not reply in time"),
            client.Busy("broker at capacity"),
            client.WorkerError("isolated worker failed"),
        ],
        ids=["wedged-connection-lost", "timeout", "busy", "worker-error"],
    )
    def test_swallows_any_daemon_fault(self, fault):
        """A WEDGED daemon (or any ``IsolatedError``-family fault) must be swallowed too.

        Regression: ``evict_stt_model`` previously caught only ``DaemonUnavailable``,
        so a wedged gpu-host (socket present but unresponsive -> ``ConnectionLost``)
        propagated out of ``run_prepare``'s unconditional evict hint and crashed the
        *entire* prepare run — every article/podcast item — even though eviction is a
        best-effort hygiene hint with nothing downstream depending on it. All daemon
        transport/worker faults share the ``IsolatedError`` base, so all are swallowed.
        See HISTORY 2026-07-19.
        """
        with patch("wilted.transcribe.client.evict", side_effect=fault):
            evict_stt_model()  # must not raise
