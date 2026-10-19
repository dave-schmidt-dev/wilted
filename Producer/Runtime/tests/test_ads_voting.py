"""Tests for ad detection voting and windowing."""

from __future__ import annotations

import json
from unittest.mock import MagicMock

import pytest

from wilted.ads import (
    COARSE_CONFIDENCE_CEILING,
    AdSegment,
    detect_ads,
)

from .ads_test_support import (
    AdDetectionTestSupport,
    TranscriptSegment,
    _make_segments,
    _mock_backend,
)


class TestDetectAds(AdDetectionTestSupport):
    @pytest.mark.parametrize(
        "invalid",
        [
            '{"ads":[[0,"ad_break"],[0,"ad_break"]]}',
            '{"ads":[[1,"ad_break"],[0,"ad_break"]]}',
            '{"ads":[[9,"ad_break"]]}',
        ],
    )
    def test_invalid_partition_retries_once_then_uses_complete_retry(self, invalid):
        segs = _make_segments([(0, 10, "content"), (10, 20, "This episode is brought to you by Acme.")])
        valid = self._classifications([0, 1], {1})
        backend = _mock_backend([invalid, valid, '{"include": false}'])
        assert detect_ads(segs, backend) == [AdSegment(10, 20, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        assert backend.generate.call_count == 3

    def test_persistently_invalid_singleton_fails_closed(self):
        backend = _mock_backend(["not json", '{"ads":[]}'])
        assert detect_ads(_make_segments([(0, 10, "content")]), backend) == []
        assert backend.generate.call_count == 2

    def test_invalid_multi_id_batch_recovers_from_valid_halves_without_duplicate_votes(self):
        segs = _make_segments([(index * 10, index * 10 + 10, f"segment {index}") for index in range(8)])
        successful_batches = []

        def generate(_system_prompt, transcript_text):
            ids = [int(line.split("]", 1)[0].removeprefix("[ID ")) for line in transcript_text.splitlines()]
            if len(ids) == 8:
                return "not json", 100
            successful_batches.append(ids)
            return json.dumps({"ads": []}), 100

        backend = MagicMock()
        backend.generate = MagicMock(side_effect=generate)

        assert detect_ads(segs, backend) == []
        assert successful_batches == [list(range(4)), list(range(4, 8))]
        assert [segment_id for batch in successful_batches for segment_id in batch] == list(range(8))
        assert backend.generate.call_count == 4

    @pytest.mark.parametrize(
        ("duration_s", "segment_count", "text_size"),
        [(300, 154, 250), (3 * 60 * 60, 180, 50)],
    )
    def test_compact_requests_are_bounded_for_short_dense_and_long_podcasts(self, duration_s, segment_count, text_size):
        segment_duration = duration_s / segment_count
        segs = _make_segments(
            [
                (index * segment_duration, (index + 1) * segment_duration, "x" * text_size)
                for index in range(segment_count)
            ]
        )
        backend = self._content_backend()

        assert detect_ads(segs, backend) == []
        prompts = [call.args[1] for call in backend.generate.call_args_list]
        request_ids = [
            [int(line.split("]", 1)[0].removeprefix("[ID ")) for line in prompt.splitlines()] for prompt in prompts
        ]
        assert all(1 <= len(ids) <= 64 for ids in request_ids)
        assert all(len(prompt) <= 12_000 for prompt in prompts)
        assert set().union(*(set(ids) for ids in request_ids)) == set(range(segment_count))

    def test_overlap_segment_is_classified_once_per_temporal_window(self):
        segs = _make_segments([(0, 480, "before"), (500, 600, "overlap"), (600, 840, "after")])
        backend = self._content_backend()

        assert detect_ads(segs, backend, chunk_minutes=10, overlap_minutes=2) == []
        prompts = [call.args[1] for call in backend.generate.call_args_list]
        assert sum("[ID 1]" in prompt for prompt in prompts) == 2

    def test_failed_overlapping_batch_casts_negative_vote_and_tie_is_content(self):
        segs = _make_segments([(0, 480, "before"), (500, 600, "possible ad"), (600, 840, "after")])
        first_window = json.dumps({"ads": [[1, "sponsor_read"]]})
        backend = _mock_backend(
            [
                first_window,
                "not json",
                '{"ads":[],"extra":true}',
                '{"ads":[]}',
                '{"ads":[]}',
            ]
        )

        assert detect_ads(segs, backend, chunk_minutes=10, overlap_minutes=2) == []
        assert backend.generate.call_count == 5

    def test_dense_size_failures_recover_by_splitting_to_bounded_final_requests(self):
        segment_count = 154
        segment_duration = 300 / segment_count
        segs = _make_segments(
            [(index * segment_duration, (index + 1) * segment_duration, "x" * 250) for index in range(segment_count)]
        )
        accepted_prompts = []

        def generate(_system_prompt, transcript_text):
            if len(transcript_text) > 2_000:
                return "request too large", 100
            accepted_prompts.append(transcript_text)
            return json.dumps({"ads": []}), 100

        backend = MagicMock()
        backend.generate = MagicMock(side_effect=generate)

        assert detect_ads(segs, backend) == []
        accepted_ids = [
            int(line.split("]", 1)[0].removeprefix("[ID "))
            for prompt in accepted_prompts
            for line in prompt.splitlines()
        ]
        assert accepted_ids == list(range(segment_count))
        assert all(len(prompt) <= 2_000 for prompt in accepted_prompts)
        assert all(len(call.args[1]) <= 12_000 for call in backend.generate.call_args_list)

    def test_reused_segment_object_retains_distinct_global_ids(self):
        segment = TranscriptSegment(0, 10, "same object")
        backend = self._content_backend()

        assert detect_ads([segment, segment], backend) == []
        prompt = backend.generate.call_args.args[1]
        assert "[ID 0]" in prompt
        assert "[ID 1]" in prompt

    def test_overlap_tie_is_content(self):
        segs = _make_segments([(0, 500, "content"), (500, 600, "possible ad"), (600, 1000, "content")])
        backend = _mock_backend(
            [self._classifications([0, 1], {1}), self._classifications([0, 1, 2]), self._classifications([2])]
        )
        assert detect_ads(segs, backend, chunk_minutes=10, overlap_minutes=2) == []

    def test_duplicate_timestamps_retain_global_run_ids_for_boundary_probes(self):
        segs = _make_segments(
            [
                (0, 10, "before"),
                (10, 30, "overlapping content"),
                (10, 30, "This message is brought to you by Acme."),
                (30, 40, "after"),
                (40, 50, "later"),
            ]
        )
        classification = self._classifications([0, 1, 2, 3, 4], {2})
        backend = _mock_backend([classification, '{"include": false}', '{"content_start_id":3}'])

        assert detect_ads(segs, backend) == [AdSegment(10, 30, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        assert "CANDIDATE_ID=1" in backend.generate.call_args_list[1].args[1]
        assert "CANDIDATE_CONTENT_MAX_ID=4" in backend.generate.call_args_list[2].args[1]

    def test_real_shape_visible_pod_keeps_generic_two_sentence_opening_continuous(self):
        segs = _make_segments(
            [
                (0, 10, "Joe wraps the previous topic."),
                (10, 20, "It is hard to know what is really happening. There is a lot to keep track of."),
                (20, 30, "Visible helps you understand your health with one simple membership."),
                (30, 40, "Visit visible.com and get started today."),
                (40, 50, "Joe returns to the interview."),
            ]
        )
        response = json.dumps({"ads": [[1, "sponsor_read"], [2, "sponsor_read"], [3, "sponsor_read"]]})
        backend = _mock_backend([response, '{"include": false}'])

        assert detect_ads(segs, backend) == [AdSegment(10, 40, COARSE_CONFIDENCE_CEILING, "sponsor_read")]

    def test_below_threshold_run_skips_boundary_verification(self):
        segs = _make_segments([(0, 1000, "possible ad")])
        ad = self._classifications([0], {0})
        content = self._classifications([0])
        backend = _mock_backend([ad, ad, content])

        assert detect_ads(segs, backend, chunk_minutes=10, overlap_minutes=2, confidence_threshold=0.8) == []
        assert backend.generate.call_count == 3

    def test_noncontiguous_ad_runs_are_not_merged(self):
        segs = _make_segments([(0, 10, "Visit acme.com."), (10, 20, "editorial"), (20, 30, "Use promo code ROGAN.")])
        backend = _mock_backend(
            [self._classifications([0, 1, 2], {0, 2}), '{"content_start_id":1}', '{"include": false}']
        )
        assert [(ad.start_s, ad.end_s) for ad in detect_ads(segs, backend)] == [(0, 10), (20, 30)]

    def test_boundary_verifier_never_shrinks_and_invalid_fallback_keeps_coarse_run(self):
        segs = _make_segments(
            [
                (0, 10, "nearby"),
                (10, 20, "opening"),
                (20, 30, "This message is brought to you by Acme."),
                (30, 40, "Visit acme.com."),
                (40, 50, "nearby"),
                (50, 60, "later editorial"),
            ]
        )
        classification = self._classifications([0, 1, 2, 3, 4, 5], {2, 3})
        no_expansion = _mock_backend([classification, '{"include": false}', '{"content_start_id":4}'])
        assert [(ad.start_s, ad.end_s) for ad in detect_ads(segs, no_expansion)] == [(20, 40)]

        fallback = _mock_backend([classification, '{"start_id": 99}', '{"content_start_id":4}'])
        assert [(ad.start_s, ad.end_s) for ad in detect_ads(segs, fallback)] == [(20, 40)]
        assert fallback.generate.call_count == 3
