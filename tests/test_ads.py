"""Tests for ad detection, audio cutting, and promotional content removal (ads.py)."""

from __future__ import annotations

import json
from dataclasses import dataclass
from unittest.mock import MagicMock, patch

import pytest

from wilted.ads import (
    AdSegment,
    _chunk_segments,
    _compute_keep_segments,
    _merge_adjacent,
    cut_ads,
    detect_ads,
    remove_promos,
    remove_promos_batch,
)

# ---------------------------------------------------------------------------
# Local TranscriptSegment for tests (avoids dependency on transcribe.py)
# ---------------------------------------------------------------------------


@dataclass
class TranscriptSegment:
    start_s: float
    end_s: float
    text: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_segments(intervals: list[tuple[float, float, str]]) -> list[TranscriptSegment]:
    """Create TranscriptSegment list from (start, end, text) tuples."""
    return [TranscriptSegment(start_s=s, end_s=e, text=t) for s, e, t in intervals]


def _mock_backend(responses: list[str]) -> MagicMock:
    """Create a mock LLM backend that returns the given responses in order."""
    backend = MagicMock()
    backend.generate = MagicMock(side_effect=[(r, 100) for r in responses])
    return backend


# ---------------------------------------------------------------------------
# _chunk_segments
# ---------------------------------------------------------------------------


class TestChunkSegments:
    def test_correct_window_splitting_with_overlap(self):
        """10-minute chunks with 2-minute overlap over 25 minutes of content."""
        # Create segments spanning 0-25 minutes (1500 seconds)
        segs = _make_segments(
            [
                (0.0, 300.0, "seg1"),  # 0-5 min
                (300.0, 600.0, "seg2"),  # 5-10 min
                (600.0, 900.0, "seg3"),  # 10-15 min
                (900.0, 1200.0, "seg4"),  # 15-20 min
                (1200.0, 1500.0, "seg5"),  # 20-25 min
            ]
        )
        chunks = _chunk_segments(segs, chunk_minutes=10.0, overlap_minutes=2.0)

        # With 10-min chunks, 2-min overlap -> 8-min step (480s)
        # Windows: [0,600], [480,1080], [960,1560], [1440,2040]
        assert len(chunks) == 4

        # First chunk covers 0-600s: seg1, seg2
        assert len(chunks[0]) == 2
        # Second chunk covers 480-1080s: seg2(300-600 overlaps), seg3, seg4 starts at 900
        assert len(chunks[1]) == 3  # seg2, seg3, seg4
        # Third chunk covers 960-1560s: seg4(900-1200), seg5(1200-1500)
        assert len(chunks[2]) == 2  # seg4, seg5
        # Fourth chunk covers 1440-2040s: seg5(1200-1500 overlaps)
        assert len(chunks[3]) == 1  # seg5

    def test_single_chunk_for_short_transcript(self):
        """Short transcript fits in one chunk."""
        segs = _make_segments(
            [
                (0.0, 60.0, "hello"),
                (60.0, 120.0, "world"),
            ]
        )
        chunks = _chunk_segments(segs, chunk_minutes=10.0, overlap_minutes=2.0)
        assert len(chunks) == 1
        assert len(chunks[0]) == 2

    def test_empty_segments_returns_empty(self):
        """Empty input returns empty output."""
        assert _chunk_segments([], chunk_minutes=10.0, overlap_minutes=2.0) == []


# ---------------------------------------------------------------------------
# detect_ads
# ---------------------------------------------------------------------------


class TestDetectAds:
    def test_llm_returns_ads_parsed_and_filtered(self):
        """LLM returns ad segments that are parsed correctly."""
        segs = _make_segments([(0.0, 120.0, "content"), (120.0, 180.0, "ad here"), (180.0, 300.0, "more content")])
        response = json.dumps(
            [
                {"start_s": 120.0, "end_s": 180.0, "confidence": 0.95, "label": "sponsor_read"},
            ]
        )
        backend = _mock_backend([response])

        result = detect_ads(segs, backend, chunk_minutes=10.0, overlap_minutes=2.0, confidence_threshold=0.8)

        assert len(result) >= 1
        ad = result[0]
        assert ad.confidence >= 0.8
        assert ad.label == "sponsor_read"

    def test_llm_returns_no_ads(self):
        """LLM finds no ads, result is empty."""
        segs = _make_segments([(0.0, 120.0, "clean content")])
        backend = _mock_backend(["[]"])

        result = detect_ads(segs, backend, chunk_minutes=10.0, overlap_minutes=2.0)
        assert result == []

    def test_empty_segments(self):
        """Empty transcript returns empty result without calling backend."""
        backend = MagicMock()
        result = detect_ads([], backend)
        assert result == []
        backend.generate.assert_not_called()

    def test_overlap_resolution_majority_vote(self):
        """Two chunks overlap; majority vote resolves conflict."""
        # Create segments spanning 14 minutes so we get 2 overlapping chunks
        # 10-min chunks, 2-min overlap -> 8-min step
        # Chunk 0: [0, 600s], Chunk 1: [480, 1080s]
        # Overlap zone: 480-600s
        segs = _make_segments(
            [
                (0.0, 240.0, "seg1"),
                (240.0, 480.0, "seg2"),
                (480.0, 600.0, "overlap zone"),
                (600.0, 840.0, "seg4"),
            ]
        )

        # Chunk 0 says 480-600 is an ad, Chunk 1 also says 480-600 is an ad
        # Both agree -> majority vote keeps it
        response_chunk0 = json.dumps([{"start_s": 480.0, "end_s": 600.0, "confidence": 0.9, "label": "ad_break"}])
        response_chunk1 = json.dumps([{"start_s": 480.0, "end_s": 600.0, "confidence": 0.85, "label": "ad_break"}])
        backend = _mock_backend([response_chunk0, response_chunk1])

        result = detect_ads(segs, backend, chunk_minutes=10.0, overlap_minutes=2.0, confidence_threshold=0.8)

        # Should have an ad detection in the 480-600 range
        assert len(result) >= 1
        assert any(ad.start_s <= 490 and ad.end_s >= 590 for ad in result)

    def test_confidence_threshold_filters_low_confidence(self):
        """Low-confidence detections are filtered out."""
        segs = _make_segments([(0.0, 120.0, "maybe ad?")])
        response = json.dumps([{"start_s": 30.0, "end_s": 60.0, "confidence": 0.3, "label": "ad_break"}])
        backend = _mock_backend([response])

        result = detect_ads(segs, backend, chunk_minutes=10.0, overlap_minutes=2.0, confidence_threshold=0.8)
        assert result == []

    def test_adjacent_segments_merged(self):
        """Ad segments with gap < 2s are merged."""
        segs = _make_segments([(0.0, 300.0, "content with ads")])
        # Two adjacent ads with 1s gap
        response = json.dumps(
            [
                {"start_s": 30.0, "end_s": 60.0, "confidence": 0.95, "label": "sponsor_read"},
                {"start_s": 61.0, "end_s": 90.0, "confidence": 0.92, "label": "sponsor_read"},
            ]
        )
        backend = _mock_backend([response])

        result = detect_ads(segs, backend, chunk_minutes=10.0, overlap_minutes=2.0, confidence_threshold=0.8)

        # The two detections should merge into one since gap is < 2s
        assert len(result) == 1
        assert result[0].start_s <= 30
        assert result[0].end_s >= 90


# ---------------------------------------------------------------------------
# _merge_adjacent
# ---------------------------------------------------------------------------


class TestMergeAdjacent:
    def test_merge_overlapping(self):
        segs = [
            AdSegment(start_s=10, end_s=20, confidence=0.9, label="ad_break"),
            AdSegment(start_s=19, end_s=30, confidence=0.8, label="ad_break"),
        ]
        merged = _merge_adjacent(segs)
        assert len(merged) == 1
        assert merged[0].start_s == 10
        assert merged[0].end_s == 30

    def test_no_merge_large_gap(self):
        segs = [
            AdSegment(start_s=10, end_s=20, confidence=0.9, label="ad_break"),
            AdSegment(start_s=30, end_s=40, confidence=0.8, label="sponsor_read"),
        ]
        merged = _merge_adjacent(segs)
        assert len(merged) == 2

    def test_empty_list(self):
        assert _merge_adjacent([]) == []


# ---------------------------------------------------------------------------
# _compute_keep_segments
# ---------------------------------------------------------------------------


class TestComputeKeepSegments:
    def test_correct_inversion(self):
        """Keeps are the inverse of ad segments."""
        ads = [
            AdSegment(start_s=30.0, end_s=60.0, confidence=0.9, label="ad_break"),
            AdSegment(start_s=120.0, end_s=150.0, confidence=0.85, label="sponsor_read"),
        ]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)

        # Expected: [0, 29.5], [60.5, 119.5], [150.5, 300]
        assert len(keeps) == 3
        assert keeps[0] == (0.0, 29.5)
        assert keeps[1] == (60.5, 119.5)
        assert keeps[2] == (150.5, 300.0)

    def test_no_ads_entire_duration_kept(self):
        """No ads means the full duration is one keep segment."""
        keeps = _compute_keep_segments(600.0, [], buffer_s=0.5)
        assert keeps == [(0.0, 600.0)]

    def test_ad_at_beginning(self):
        """Ad at the start of the audio."""
        ads = [AdSegment(start_s=0.0, end_s=30.0, confidence=0.9, label="ad_break")]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)

        # Buffer clamps to 0, so ad region is [0, 30.5]
        assert len(keeps) == 1
        assert keeps[0][0] == 30.5
        assert keeps[0][1] == 300.0

    def test_ad_at_end(self):
        """Ad at the end of the audio."""
        ads = [AdSegment(start_s=270.0, end_s=300.0, confidence=0.9, label="ad_break")]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)

        # Content before ad: [0, 269.5], ad region [269.5, 300] -> no content after
        assert len(keeps) == 1
        assert keeps[0] == (0.0, 269.5)

    def test_ad_covers_entire_duration(self):
        """Ad spans the whole file leaves nothing."""
        ads = [AdSegment(start_s=0.0, end_s=300.0, confidence=0.9, label="ad_break")]
        keeps = _compute_keep_segments(300.0, ads, buffer_s=0.5)
        assert keeps == []

    def test_overlapping_ads(self):
        """Overlapping ad segments handled correctly."""
        ads = [
            AdSegment(start_s=10.0, end_s=30.0, confidence=0.9, label="ad_break"),
            AdSegment(start_s=25.0, end_s=50.0, confidence=0.85, label="sponsor_read"),
        ]
        keeps = _compute_keep_segments(100.0, ads, buffer_s=0.5)

        # After sorting by start_s:
        # Ad 1: [10-0.5, 30+0.5] = [9.5, 30.5]
        # Ad 2: [25-0.5, 50+0.5] = [24.5, 50.5]
        # Merged ad zone: [9.5, 50.5]
        # Keeps: [0, 9.5], [50.5, 100]
        assert len(keeps) == 2
        assert keeps[0] == (0.0, 9.5)
        assert keeps[1] == (50.5, 100.0)


# ---------------------------------------------------------------------------
# cut_ads
# ---------------------------------------------------------------------------


class TestCutAds:
    def test_ffmpeg_commands_correct(self, tmp_path):
        """Verify ffmpeg is called with correct arguments."""
        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio")
        output = tmp_path / "output.mp3"

        ads = [AdSegment(start_s=30.0, end_s=60.0, confidence=0.9, label="ad_break")]

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run") as mock_run,
            patch("wilted.ads.shutil.move"),
            patch("wilted.ads.tempfile.mkdtemp") as mock_mkdtemp,
            patch("wilted.ads.shutil.rmtree"),
        ):
            tmpdir = tmp_path / "tmpwork"
            tmpdir.mkdir()
            mock_mkdtemp.return_value = str(tmpdir)

            # ffprobe returns duration
            probe_result = MagicMock()
            probe_result.stdout = "300.0\n"

            # Segment extraction succeeds
            seg_result = MagicMock()

            mock_run.side_effect = [probe_result, seg_result]

            # With one ad in the middle (30-60s), buffer 0.5s, duration 300s:
            # Keep: [0, 29.5] and [60.5, 300]
            # Two keep segments -> extract + extract + concat
            mock_run.reset_mock()
            mock_run.side_effect = [probe_result, seg_result, seg_result, MagicMock()]

            cut_ads(audio, ads, output, buffer_seconds=0.5)

            calls = mock_run.call_args_list
            # First call: ffprobe
            assert calls[0].args[0][0] == "ffprobe"
            # Second call: ffmpeg extract segment 0
            assert calls[1].args[0][0] == "ffmpeg"
            assert "-ss" in calls[1].args[0]
            assert "-t" in calls[1].args[0]
            # Third call: ffmpeg extract segment 1
            assert calls[2].args[0][0] == "ffmpeg"
            # Fourth call: ffmpeg concat
            assert "-f" in calls[3].args[0]
            assert "concat" in calls[3].args[0]

    def test_no_ads_copies_file(self, tmp_path):
        """No ad segments means the file is copied as-is."""
        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio data")
        output = tmp_path / "output.mp3"

        with patch("wilted.ads.check_ffmpeg"):
            result = cut_ads(audio, [], output)

        assert result == output
        assert output.exists()
        assert output.read_bytes() == b"fake audio data"

    def test_missing_audio_raises(self, tmp_path):
        """FileNotFoundError if audio file doesn't exist."""
        audio = tmp_path / "nonexistent.mp3"
        output = tmp_path / "output.mp3"

        with patch("wilted.ads.check_ffmpeg"):
            with pytest.raises(FileNotFoundError):
                cut_ads(audio, [], output)

    def test_single_keep_segment_no_concat(self, tmp_path):
        """Single keep segment uses move instead of concat."""
        audio = tmp_path / "input.mp3"
        audio.write_bytes(b"fake audio")
        output = tmp_path / "output.mp3"

        # Ad at the very beginning, so only one keep segment after the ad
        ads = [AdSegment(start_s=0.0, end_s=30.0, confidence=0.9, label="ad_break")]

        with (
            patch("wilted.ads.check_ffmpeg"),
            patch("wilted.ads.subprocess.run") as mock_run,
            patch("wilted.ads.shutil.move") as mock_move,
            patch("wilted.ads.tempfile.mkdtemp") as mock_mkdtemp,
            patch("wilted.ads.shutil.rmtree"),
        ):
            tmpdir = tmp_path / "tmpwork2"
            tmpdir.mkdir()
            mock_mkdtemp.return_value = str(tmpdir)

            probe_result = MagicMock()
            probe_result.stdout = "300.0\n"
            seg_result = MagicMock()

            mock_run.side_effect = [probe_result, seg_result]

            cut_ads(audio, ads, output, buffer_seconds=0.5)

            # Should have ffprobe + one segment extract (no concat)
            assert mock_run.call_count == 2
            # Should use shutil.move for single segment
            mock_move.assert_called_once()


# ---------------------------------------------------------------------------
# remove_promos
# ---------------------------------------------------------------------------


class TestRemovePromos:
    def test_promos_identified_and_removed(self):
        """LLM identifies promotional paragraphs which are removed."""
        text = "Good content here.\n\nMore good stuff.\n\nSubscribe to our newsletter!\n\nFinal paragraph."
        response = json.dumps({"promo_indices": [2]})
        backend = _mock_backend([response])

        result = remove_promos(text, backend)

        assert "Subscribe to our newsletter" not in result
        assert "Good content here." in result
        assert "More good stuff." in result
        assert "Final paragraph." in result

    def test_no_promos_text_unchanged(self):
        """No promotional content detected, text returned as-is."""
        text = "Paragraph one.\n\nParagraph two.\n\nParagraph three."
        response = json.dumps({"promo_indices": []})
        backend = _mock_backend([response])

        result = remove_promos(text, backend)

        assert result == text

    def test_empty_text_returns_empty(self):
        """Empty or whitespace-only text returns empty string."""
        backend = MagicMock()
        assert remove_promos("", backend) == ""
        assert remove_promos("   \n\n  ", backend) == ""
        backend.generate.assert_not_called()

    def test_multiple_promos_removed(self):
        """Multiple promotional paragraphs removed."""
        text = "Real content.\n\nSubscribe now!\n\nMore content.\n\nFollow us on Twitter!\n\nFinal content."
        response = json.dumps({"promo_indices": [1, 3]})
        backend = _mock_backend([response])

        result = remove_promos(text, backend)

        assert "Subscribe now" not in result
        assert "Follow us on Twitter" not in result
        assert "Real content." in result
        assert "More content." in result
        assert "Final content." in result

    def test_llm_failure_returns_original(self):
        """If LLM fails, original text is returned."""
        text = "Some content.\n\nMore content."
        backend = MagicMock()
        backend.generate.side_effect = RuntimeError("model error")

        result = remove_promos(text, backend)
        assert result == text


# ---------------------------------------------------------------------------
# remove_promos_batch
# ---------------------------------------------------------------------------


class TestRemovePromosBatch:
    def test_multiple_items_processed(self):
        """Batch processing handles multiple items."""
        items = [
            (1, "Content A.\n\nPromo A.\n\nMore A."),
            (2, "Content B.\n\nPromo B."),
            (3, "Clean content only."),
        ]

        responses = [
            json.dumps({"promo_indices": [1]}),
            json.dumps({"promo_indices": [1]}),
            json.dumps({"promo_indices": []}),
        ]
        backend = _mock_backend(responses)

        results = remove_promos_batch(items, backend)

        assert len(results) == 3
        assert 1 in results
        assert 2 in results
        assert 3 in results
        assert "Promo A" not in results[1]
        assert "Content A." in results[1]
        assert "Promo B" not in results[2]
        assert results[3] == "Clean content only."

    def test_partial_failure_returns_original(self):
        """If one item fails, its original text is returned."""
        items = [
            (1, "Good content.\n\nPromo."),
            (2, "Also good.\n\nAlso promo."),
        ]

        backend = MagicMock()
        # First call succeeds, second fails
        backend.generate.side_effect = [
            (json.dumps({"promo_indices": [1]}), 50),
            RuntimeError("boom"),
        ]

        results = remove_promos_batch(items, backend)

        assert len(results) == 2
        assert "Promo" not in results[1]
        assert results[2] == "Also good.\n\nAlso promo."  # Original returned on failure


# ---------------------------------------------------------------------------
# cut_ads — real ffmpeg integration
# ---------------------------------------------------------------------------


def _ffprobe_duration(path) -> float:
    import subprocess

    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return float(result.stdout.strip())


class TestCutAdsRealFfmpeg:
    @pytest.mark.skipif(
        not __import__("shutil").which("ffmpeg") or not __import__("shutil").which("ffprobe"),
        reason="ffmpeg and ffprobe required",
    )
    def test_cut_removes_middle_segment(self, tmp_path):
        """Real ffmpeg cuts a middle ad segment and produces shorter output."""
        import subprocess

        mp3_path = tmp_path / "input.mp3"
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=3:sample_rate=22050",
                str(mp3_path),
            ],
            capture_output=True,
            check=True,
        )

        ad = AdSegment(start_s=1.0, end_s=2.0, confidence=0.95, label="ad_break")
        output = tmp_path / "output.mp3"

        result = cut_ads(mp3_path, [ad], output, buffer_seconds=0.0)

        assert result == output
        assert output.exists()
        assert output.stat().st_size > 0

        input_dur = _ffprobe_duration(mp3_path)
        output_dur = _ffprobe_duration(output)

        assert output_dur < input_dur
        assert abs(output_dur - 2.0) < 0.5  # ~2s remaining after 1s cut

    @pytest.mark.skipif(
        not __import__("shutil").which("ffmpeg"),
        reason="ffmpeg required",
    )
    def test_no_ads_output_matches_input(self, tmp_path):
        """No ads — output is a byte-identical copy of input."""
        import subprocess

        mp3_path = tmp_path / "input.mp3"
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=2:sample_rate=22050",
                str(mp3_path),
            ],
            capture_output=True,
            check=True,
        )

        output = tmp_path / "output.mp3"
        cut_ads(mp3_path, [], output, buffer_seconds=0.0)

        assert output.read_bytes() == mp3_path.read_bytes()
