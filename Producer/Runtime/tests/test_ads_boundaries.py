"""Tests for ad detection boundary verification."""

from __future__ import annotations

import math
from unittest.mock import MagicMock

import pytest

from wilted.ads import (
    _BOUNDARY_VERIFY_RESPONSE_FORMAT,
    _PREROLL_CONTENT_VERIFY_SYSTEM_PROMPT,
    _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT,
    COARSE_CONFIDENCE_CEILING,
    AdSegment,
    _CoarseAdRun,
    _id_response_format,
    _verify_ad_boundaries,
    detect_ads,
)

from .ads_test_support import (
    AdDetectionTestSupport,
    TranscriptSegment,
    _AlignedToken,
    _make_segments,
    _mock_backend,
)


class TestDetectAds(AdDetectionTestSupport):
    def test_jre_zip_pod_end_expands_127_through_138_and_stops_before_return(self):
        segs = _make_segments([(index * 4, index * 4 + 4, f"earlier segment {index}") for index in range(127)])
        segs.extend(
            _make_segments(
                [
                    (598.92, 603.5, "This episode is brought to you by ZipRecruiter."),
                    (603.5, 608.0, "Building a great team takes time. Every new hire matters."),
                    (608.0, 612.5, "Sorting through applications can pull you away from the work."),
                    (612.5, 617.0, "ZipRecruiter helps you find qualified candidates faster."),
                    (617.0, 621.5, "Its matching technology identifies people with the right experience."),
                    (621.5, 626.0, "You can invite top candidates to apply to your job."),
                    (626.0, 630.5, "Four out of five employers get a quality candidate on the first day."),
                    (630.5, 635.0, "That means less time searching and more time interviewing."),
                    (635.0, 640.0, "Try ZipRecruiter for free at ziprecruiter.com slash rogan."),
                    (640.0, 645.0, "That is ziprecruiter.com slash rogan."),
                    (645.0, 650.0, "ZipRecruiter. The smartest way to hire."),
                    (650.0, 654.48, "Terms and conditions apply."),
                    (654.48, 660.0, "Okay, we're back."),
                ]
            )
        )
        segs[127] = TranscriptSegment(
            598.92,
            603.5,
            "Yeah, I mean, there are both kinds of this episode is brought to you by ZipRecruiter.",
            tokens=(
                _AlignedToken(" Yeah, I mean, there are both kinds of", 598.92, 601.24),
                _AlignedToken(" this", 601.72, 601.88),
                _AlignedToken(" episode is brought to you by ZipRecruiter.", 601.88, 603.5),
            ),
        )
        coarse_run = _CoarseAdRun(start_id=127, end_id=127, confidence=1.0, label="sponsor_read")
        segs.append(TranscriptSegment(660.0, 665.0, "The interview continues."))
        backend = _mock_backend(['{"include":false}', '{"content_start_id":139}'])

        result = _verify_ad_boundaries(coarse_run, segs, backend)

        assert result == AdSegment(601.72, 654.48, 1.0, "sponsor_read")
        assert "CONFIRMED_START_ID=127" in backend.generate.call_args_list[1].args[1]
        assert "CONFIRMED_AD_SEED_ID=127" in backend.generate.call_args_list[1].args[1]
        assert "CANDIDATE_CONTENT_MAX_ID=140" in backend.generate.call_args_list[1].args[1]
        assert "[ID 139]" in backend.generate.call_args_list[1].args[1]
        assert backend.generate.call_args_list[0].kwargs["response_format"] == _BOUNDARY_VERIFY_RESPONSE_FORMAT
        assert backend.generate.call_args_list[1].kwargs["response_format"] == _id_response_format(
            "content_start_id", list(range(128, 141))
        )

    def test_jre_visible_dense_coarse_run_retains_253_without_right_verifier(self):
        segs = _make_segments([(index * 4, index * 4 + 4, f"earlier segment {index}") for index in range(245)])
        segs.extend(
            _make_segments(
                [
                    (1195.48, 1201, "Summer is here, and it is a good time to think about your health."),
                    (1201, 1207, "Visible membership details."),
                    (1207, 1213, "Track your health data."),
                    (1213, 1219, "Lab testing and insights."),
                    (1219, 1225, "Product benefits and claims."),
                    (1225, 1231, "Membership pricing."),
                    (1231, 1238, "Visible customer experience."),
                    (1238, 1245, "Visit visible.com slash rogan."),
                    (1245, 1251.0, "Visible sponsor call to action."),
                    (1251.0, 1260, "The conversation returns to an editorial topic."),
                ]
            )
        )
        coarse_run = _CoarseAdRun(start_id=245, end_id=253, confidence=1.0, label="sponsor_read")
        backend = _mock_backend(['{"include":false}'])

        result = _verify_ad_boundaries(coarse_run, segs, backend)

        assert result == AdSegment(1195.48, 1251.0, 1.0, "sponsor_read")
        assert backend.generate.call_count == 1
        assert backend.generate.call_args.args[0] != _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT

    def test_malformed_or_non_sponsor_tokens_keep_segment_start(self):
        segment = TranscriptSegment(
            10.0,
            20.0,
            "Editorial discussion mentions a sponsor.",
            tokens=(
                _AlignedToken("Editorial", 10.0, 11.0),
                _AlignedToken(" discussion", 9.5, 12.0),
            ),
        )

        result = _verify_ad_boundaries(
            _CoarseAdRun(start_id=0, end_id=0, confidence=1.0, label="sponsor_read"),
            [segment],
            _mock_backend([]),
        )

        assert result.start_s == 10.0

    @pytest.mark.parametrize("bad_time", [float("nan"), float("inf")])
    def test_nonfinite_token_time_keeps_finite_segment_start(self, bad_time):
        segment = TranscriptSegment(
            10.0,
            20.0,
            "This episode is brought to you by Acme.",
            tokens=(
                _AlignedToken("This", bad_time, 10.3),
                _AlignedToken(" episode is brought to you by Acme.", 10.3, 12.0),
            ),
        )

        result = _verify_ad_boundaries(
            _CoarseAdRun(start_id=0, end_id=0, confidence=1.0, label="sponsor_read"),
            [segment],
            _mock_backend([]),
        )

        assert result.start_s == 10.0
        assert math.isfinite(result.start_s)

    @pytest.mark.parametrize(
        "invalid_end",
        ["not json", '{"content_start_id":2}', '{"content_start_id":4}', '{"content_start_id":99}'],
    )
    def test_invalid_or_unsafe_sparse_content_start_suppresses_coarse_run(self, invalid_end):
        segs = _make_segments([(index * 10, index * 10 + 10, f"segment {index}") for index in range(5)])
        coarse_run = _CoarseAdRun(start_id=1, end_id=2, confidence=0.9, label="ad_break")
        backend = _mock_backend(['{"include":false}', invalid_end])

        assert _verify_ad_boundaries(coarse_run, segs, backend) is None

    def test_boundary_verifier_probes_at_most_two_left_candidates_and_one_pod_end(self):
        segs = _make_segments([(index * 10, index * 10 + 10, f"segment {index}") for index in range(9)])
        segs[3] = TranscriptSegment(30, 40, "This message is brought to you by Acme.")
        classification = self._classifications(list(range(9)), {3})
        backend = _mock_backend([classification, '{"include":true}', '{"include":true}', '{"content_start_id":7}'])

        assert [(ad.start_s, ad.end_s) for ad in detect_ads(segs, backend)] == [(10, 70)]
        assert backend.generate.call_count == 4
        boundary_prompts = [call.args[1] for call in backend.generate.call_args_list[1:]]
        assert all("CANDIDATE_ID=0" not in prompt for prompt in boundary_prompts[:2])
        assert "CANDIDATE_CONTENT_MAX_ID=8" in boundary_prompts[2]
        assert all(
            call.kwargs["response_format"] == _BOUNDARY_VERIFY_RESPONSE_FORMAT
            for call in backend.generate.call_args_list[1:3]
        )
        assert backend.generate.call_args_list[3].kwargs["response_format"] == _id_response_format(
            "content_start_id", [4, 5, 6, 7, 8]
        )

    def test_boundary_verifiers_keep_legacy_two_argument_backend_compatible(self):
        segs = _make_segments(
            [(0, 10, "editorial"), (10, 20, "Visit acme.com today."), (20, 30, "return"), (30, 40, "more")]
        )

        def generate(system_prompt, _transcript_text):
            if system_prompt == _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT:
                return '{"content_start_id":2}', 1
            return '{"include":false}', 1

        backend = MagicMock()
        backend.generate = MagicMock(wraps=generate)

        assert _verify_ad_boundaries(_CoarseAdRun(1, 1, 1.0, "ad_break"), segs, backend) == AdSegment(
            10, 20, 1.0, "ad_break"
        )
        assert all(call.kwargs == {} for call in backend.generate.call_args_list)

    def test_transcript_start_sponsor_pod_uses_preroll_content_start_timestamp(self):
        segs = _make_segments([(index * 10, index * 10 + 10, f"pre-roll context {index}") for index in range(31)])
        segs[0] = TranscriptSegment(0, 10, "This message is brought to you by Apple Card.")
        segs[1] = TranscriptSegment(10, 20, "Get cash back every day with no annual fee.")
        segs[2] = TranscriptSegment(20, 30, "Visit apple.com slash card to learn more.")
        segs[3] = TranscriptSegment(30, 40, "Terms apply.")
        segs[29] = TranscriptSegment(290, 300, "Jason starts the actual show with a question.")
        classification = self._classifications(list(range(len(segs))), {0, 1, 2, 3})
        backend = _mock_backend([classification, '{"content_start_id":29}'])

        assert detect_ads(segs, backend) == [AdSegment(0, 290, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        assert backend.generate.call_args_list[1].args[0] == _PREROLL_CONTENT_VERIFY_SYSTEM_PROMPT
        assert "[ID 29]" in backend.generate.call_args_list[1].args[1]
        assert backend.generate.call_args_list[1].kwargs["response_format"] == _id_response_format(
            "content_start_id", list(range(4, 31))
        )
