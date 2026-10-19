"""Tests for ad detection, audio cutting, and promotional content removal (ads.py)."""

from __future__ import annotations

import inspect

import pytest

from wilted.ads import (
    _TRUNCATION_MARKER,
    COARSE_CONFIDENCE_CEILING,
    COARSE_CONFIDENCE_FLOOR,
    _chunk_segment_ids,
    _resolve_overlaps,
    _truncate_head_tail,
    coarse_confidence,
    detect_ads,
)

from .ads_test_support import _make_segments


@pytest.mark.parametrize(
    "budget",
    [
        0,
        1,
        len(_TRUNCATION_MARKER) - 1,
        len(_TRUNCATION_MARKER),
        len(_TRUNCATION_MARKER) + 1,
        len(_TRUNCATION_MARKER) + 2,
    ],
)
def test_head_tail_truncation_never_exceeds_tiny_budget(budget):
    text = "A" + "x" * 100 + "Z"

    result = _truncate_head_tail(text, budget)

    assert len(result) == budget
    if budget == len(_TRUNCATION_MARKER) + 1:
        assert result == "A" + _TRUNCATION_MARKER
    if budget == len(_TRUNCATION_MARKER) + 2:
        assert result.startswith("A" + _TRUNCATION_MARKER)
        assert result.endswith("Z")


# ---------------------------------------------------------------------------
# _chunk_segment_ids
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
        chunks = _chunk_segment_ids(segs, chunk_minutes=10.0, overlap_minutes=2.0)

        # With 10-min chunks, 2-min overlap -> 8-min step (480s)
        # Windows: [0,600], [480,1080], [960,1560], [1440,2040]
        assert chunks == [[0, 1], [1, 2, 3], [3, 4], [4]]
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
        chunks = _chunk_segment_ids(segs, chunk_minutes=10.0, overlap_minutes=2.0)
        assert len(chunks) == 1
        assert len(chunks[0]) == 2

    def test_empty_segments_returns_empty(self):
        """Empty input returns empty output."""
        assert _chunk_segment_ids([], chunk_minutes=10.0, overlap_minutes=2.0) == []


# ---------------------------------------------------------------------------
# coarse_confidence
# ---------------------------------------------------------------------------


class TestCoarseConfidence:
    """The coarse path reports corroboration, not a constant."""

    def test_the_band_is_bounded_and_monotonic(self):
        assert coarse_confidence(0, 2) == COARSE_CONFIDENCE_FLOOR
        assert coarse_confidence(2, 2) == COARSE_CONFIDENCE_CEILING
        assert coarse_confidence(1, 2) < coarse_confidence(2, 2)
        assert coarse_confidence(0, 2) < coarse_confidence(1, 2)
        # More agreement than the geometry can give is still just full.
        assert coarse_confidence(9, 2) == COARSE_CONFIDENCE_CEILING
        # A caller that asks for corroboration no window can supply gets the
        # floor rather than a ZeroDivisionError.
        assert coarse_confidence(1, 0) == COARSE_CONFIDENCE_FLOOR

    def test_the_band_never_claims_certainty(self):
        assert COARSE_CONFIDENCE_CEILING < 1.0
        assert coarse_confidence(5, 5) < 1.0

    def test_a_segment_only_one_window_saw_scores_below_one_two_windows_agreed_on(self):
        # Two windows; the first sees both segments, the second only the last.
        # Both call what they see an ad, so both survive the majority rule --
        # the difference the old vote ratio could not express is that the
        # second segment was corroborated and the first never could be.
        segs = _make_segments([(0, 10, "Visit acme.com."), (10, 20, "Use offer code SHOW.")])
        votes = [[(0, True, "sponsor_read"), (1, True, "sponsor_read")], [(1, True, "sponsor_read")]]

        runs = _resolve_overlaps(votes, segs)

        assert [run.confidence for run in runs] == [
            round((coarse_confidence(1, 2) + coarse_confidence(2, 2)) / 2, 4)
        ]
        assert coarse_confidence(1, 2) < COARSE_CONFIDENCE_CEILING

    def test_the_default_threshold_cannot_drop_a_run_the_majority_rule_passed(self):
        # The threshold is compared against the RUN mean, and a run can average
        # arbitrarily close to the floor: `_complete_trailing_disclaimer_decisions`
        # folds in segments with no ad votes at all, and each of those scores the
        # floor. A default above the floor silently drops long disclaimer tails --
        # 0.7 would have dropped a three-segment one, which no other test reaches.
        head, floor = coarse_confidence(2, 2), COARSE_CONFIDENCE_FLOOR
        means = [round((head + floor * tail) / (tail + 1), 4) for tail in range(1, 8)]

        assert min(means) >= COARSE_CONFIDENCE_FLOOR
        assert any(mean < 0.7 for mean in means), "the 0.7 default really was reachable"
        assert all(
            mean >= inspect.signature(detect_ads).parameters["confidence_threshold"].default
            for mean in means
        )

    def test_a_transcript_that_fits_one_window_is_fully_corroborated(self):
        # The target is read off the votes, so a transcript short enough for a
        # single window is not penalised for a second one that never existed.
        segs = _make_segments([(0, 10, "Visit acme.com.")])

        runs = _resolve_overlaps([[(0, True, "sponsor_read")]], segs)

        assert [run.confidence for run in runs] == [COARSE_CONFIDENCE_CEILING]
