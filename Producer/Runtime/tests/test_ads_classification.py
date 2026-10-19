"""Tests for ad detection classification."""

from __future__ import annotations

import json
from unittest.mock import MagicMock

import pytest

from wilted.ads import (
    _AD_DETECT_CORRECTION_PROMPT,
    _AD_DETECT_RESPONSE_FORMAT,
    _AD_DETECT_SYSTEM_PROMPT,
    _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT,
    COARSE_CONFIDENCE_CEILING,
    AdSegment,
    _CoarseAdRun,
    _id_response_format,
    _parse_ad_response,
    _resolve_overlaps,
    _verify_ad_boundaries,
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
        ("response", "expected_ids"),
        [
            ('{"ads":[[0,"ad_break"],[0,"ad_break"]]}', [0, 1]),
            ('{"ads":[[1,"ad_break"],[0,"ad_break"]]}', [0, 1]),
            ('{"ads":[[2,"ad_break"]]}', [0, 1]),
            ('{"ads":[[true,"ad_break"]]}', [1]),
            ('{"ads":[[0,"commercial"]]}', [0]),
            ('{"ads":[[0]]}', [0]),
            ('{"ads":[{"id":0,"label":"ad_break"}]}', [0]),
        ],
    )
    def test_compact_parser_rejects_invalid_partitions(self, response, expected_ids):
        with pytest.raises(ValueError):
            _parse_ad_response(response, expected_ids)

    @pytest.mark.parametrize(
        ("expected_ids", "ad_ids", "label"),
        [
            (list(range(102, 166)), [127], "sponsor_read"),
            (list(range(194, 258)), list(range(245, 254)), "ad_break"),
        ],
        ids=["zip", "visible"],
    )
    def test_compact_parser_accepts_ad_subset_and_inferrs_complete_content(self, expected_ids, ad_ids, label):
        response = json.dumps({"ads": [[segment_id, label] for segment_id in ad_ids]})

        parsed = _parse_ad_response(response, expected_ids)
        assert [segment_id for segment_id, is_ad, _label in parsed if is_ad] == ad_ids
        assert all(parsed[expected_ids.index(segment_id)][2] == label for segment_id in ad_ids)

    def test_compact_contract_does_not_echo_content_ids_and_forwards_constraints(self):
        segs = _make_segments([(0, 10, "content"), (10, 20, "Visit acme.com today.")])
        backend = _mock_backend(['{"ads":[[1,"sponsor_read"]]}'])

        assert detect_ads(segs, backend) == [AdSegment(10, 20, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        call = backend.generate.call_args_list[0]
        assert "content_ids" not in _AD_DETECT_SYSTEM_PROMPT
        assert '[[1,"sponsor_read"]]' in _AD_DETECT_SYSTEM_PROMPT
        assert call.kwargs["response_format"] == _AD_DETECT_RESPONSE_FORMAT

    def test_compact_contract_includes_trailing_legal_and_offer_terms_in_ad_pod(self):
        assert "trailing legal disclaimers, offer restrictions, and terms" in _AD_DETECT_SYSTEM_PROMPT
        assert "trailing legal disclaimers, offer restrictions, and terms" in _AD_DETECT_CORRECTION_PROMPT

        segs = _make_segments(
            [
                (0, 10, "Editorial introduction."),
                (10, 20, "This message is brought to you by Acme."),
                (20, 30, "Visit acme.com and use offer code SHOW."),
                (30, 40, "Acme does not provide legal advice; independently review and verify all information."),
                (40, 41, "."),
                (41, 50, "The interview resumes."),
            ]
        )
        backend = _mock_backend([self._classifications(list(range(6)), {1, 2}), '{"include":false}'])

        assert detect_ads(segs, backend) == [AdSegment(10, 41, COARSE_CONFIDENCE_CEILING, "sponsor_read")]

    def test_trailing_disclaimer_completion_does_not_absorb_editorial_legal_discussion(self):
        segs = _make_segments(
            [
                (0, 10, "Editorial introduction."),
                (10, 20, "This message is brought to you by Acme."),
                (20, 30, "The guests discuss how lawyers provide legal advice and independently review cases."),
                (30, 40, "The interview continues."),
            ]
        )
        backend = _mock_backend(
            [self._classifications(list(range(4)), {1}), '{"include":false}', '{"content_start_id":2}']
        )

        assert detect_ads(segs, backend) == [AdSegment(10, 20, COARSE_CONFIDENCE_CEILING, "sponsor_read")]

    def test_trailing_disclaimer_completion_runs_after_overlapping_vote_tie(self):
        segs = _make_segments(
            [
                (0, 10, "Visit acme.com and use offer code SHOW."),
                (10, 20, "Acme does not provide legal advice; independently review and verify all information."),
                (20, 21, "."),
            ]
        )
        overlapping_votes = [
            [(0, True, "sponsor_read"), (1, True, "sponsor_read"), (2, False, None)],
            [(0, True, "sponsor_read"), (1, False, None), (2, False, None)],
        ]

        assert _resolve_overlaps(overlapping_votes, segs) == [
            _CoarseAdRun(0, 2, COARSE_CONFIDENCE_CEILING, "sponsor_read")
        ]

    def test_post_vote_completion_keeps_adjacent_editorial_legal_discussion_as_content(self):
        segs = _make_segments(
            [
                (0, 10, "Visit acme.com and use offer code SHOW."),
                (10, 20, "The guests discuss how lawyers provide legal advice and independently review cases."),
            ]
        )
        votes = [[(0, True, "sponsor_read"), (1, False, None)]]

        assert _resolve_overlaps(votes, segs) == [_CoarseAdRun(0, 0, COARSE_CONFIDENCE_CEILING, "sponsor_read")]

    def test_two_argument_test_double_remains_compatible_without_constraints(self):
        segs = _make_segments([(0, 10, "content")])

        def generate(_system_prompt, _transcript_text):
            return '{"ads":[]}', 1

        backend = MagicMock()
        backend.generate = MagicMock(side_effect=generate)

        assert detect_ads(segs, backend) == []
        assert backend.generate.call_args.kwargs == {}

    def test_wrapped_two_argument_test_double_remains_compatible_without_constraints(self):
        segs = _make_segments([(0, 10, "Visit acme.com today.")])

        def generate(_system_prompt, _transcript_text):
            return '{"ads":[[0,"sponsor_read"]]}', 1

        backend = MagicMock()
        backend.generate = MagicMock(wraps=generate)

        assert detect_ads(segs, backend) == [AdSegment(0, 10, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        assert all(call.kwargs == {} for call in backend.generate.call_args_list)

    def test_fenced_responses_preserve_golden_pod_and_intro_acknowledgement(self):
        """Fenced compact classifications retain exact source boundaries."""
        segs = _make_segments(
            [(float(index * 10), float(index * 10 + 10), f"segment {index}") for index in range(34)]
            + [
                (620.44, 630.0, "KPMG research says..."),
                (630.0, 640.0, "KPMG sponsor copy"),
                (640.0, 660.0, "KPMG CTA"),
                (660.0, 680.0, "HyperAgent"),
                (680.0, 702.0, "HyperAgent CTA"),
                (702.0, 721.0, "Blitzy opening"),
                (721.0, 750.0, "Blitzy CTA"),
                (750.0, 770.0, "Retool"),
                (770.0, 786.28, "Retool CTA"),
                (786.28, 800.0, "Back to the episode."),
            ]
        )
        # The real-model compact shape marks the housekeeping intro as an ad; the deterministic override removes it.
        segs[3] = TranscriptSegment(
            19.52,
            38.64,
            "Before we get started, a quick announcement: thanks to our sponsors, and see our ad-free subscription.",
        )
        ads = []
        for segment_id in range(len(segs)):
            if segment_id == 3:
                ads.append([segment_id, "ad_break"])
            elif 35 <= segment_id <= 42:
                ads.append([segment_id, "sponsor_read"])
        response = f"```json\n{json.dumps({'ads': ads})}\n```"
        backend = _mock_backend([response, '{"include": true}', '{"include": false}'])

        result = detect_ads(segs, backend, chunk_minutes=20)

        assert [(ad.start_s, ad.end_s) for ad in result] == [(620.44, 786.28)]
        assert "[ID 3]" in backend.generate.call_args_list[0].args[1]
        assert "CANDIDATE_ID=34" in backend.generate.call_args_list[1].args[1]
        assert "CANDIDATE_TIMESTAMPS=620.44s-630.00s" in backend.generate.call_args_list[1].args[1]
        assert "CANDIDATE_ID=33" in backend.generate.call_args_list[2].args[1]
        assert backend.generate.call_count == 3

    def test_normal_sponsor_read_is_not_housekeeping(self):
        """A sponsor read has no multi-cue housekeeping exemption."""
        segs = _make_segments([(0, 10, "This episode is brought to you by Acme. Visit acme.example today.")])
        backend = _mock_backend(['{"ads":[[0,"ad_break"]]}'])

        assert detect_ads(segs, backend) == [AdSegment(0, 10, COARSE_CONFIDENCE_CEILING, "ad_break")]

    @pytest.mark.parametrize(
        "text",
        [
            "This episode is brought to you by Acme.",
            "This episode of SmartLess is brought to you in part by Acme.",
            "Visit acme.com/savings today.",
            "Use promo code ROGAN at checkout.",
            "Get 20 percent off your first order.",
            "Start your free trial today.",
            "Download the Acme app now.",
            "Try Acme today.",
            "Switch to the Acme plan now.",
        ],
    )
    def test_sparse_genuine_promotional_cues_are_retained(self, text):
        segs = _make_segments([(0, 10, text)])
        backend = _mock_backend([self._classifications([0], {0})])

        assert detect_ads(segs, backend) == [AdSegment(0, 10, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        assert backend.generate.call_count == 1

    @pytest.mark.parametrize(
        "text",
        [
            "Oh and this is Ford.",
            "Ford rehired engineers after its AI rollout failed.",
            "The discussion turned to Ford's business strategy and recent layoffs.",
            "Researchers tried to download the Ford report for analysis.",
            "Engineers switch between the two systems during testing.",
            "Analysts visit Ford factories while researching the layoffs.",
            "Analysts discussed the back-to-school event and its weak effect on retail demand.",
            "The panel debated whether seasonal sales still matter to shoppers.",
            "Organizers asked attendees to save the conference event for today.",
        ],
    )
    def test_sparse_company_or_editorial_mentions_without_promo_cues_are_discarded(self, text):
        segs = _make_segments([(0, 10, text)])
        backend = _mock_backend([self._classifications([0], {0})])

        assert detect_ads(segs, backend) == []
        assert backend.generate.call_count == 1

    def test_direct_sales_sparse_seed_recovers_through_punctuation_gap(self):
        segs = _make_segments(
            [
                (0, 10, "Alienware back to school event: the perfect time to score top gaming gear."),
                (10, 20, "Save on an Alienware laptop for a limited time."),
                (20, 21, "."),
                (30, 40, "The hosts discuss the next game."),
                (40, 50, "More editorial discussion."),
            ]
        )
        backend = _mock_backend([self._classifications(list(range(5)), {0}), '{"content_start_id":3}'])

        assert detect_ads(segs, backend) == [AdSegment(0, 20, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        verifier_call = backend.generate.call_args_list[1]
        assert verifier_call.args[0] == _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT
        assert verifier_call.kwargs["response_format"] == _id_response_format("content_start_id", [1, 2, 3, 4])

    def test_sparse_content_verifier_at_window_edge_suppresses_partial_pod(self):
        segs = _make_segments(
            [
                (0, 10, "Limited-time sale on Acme gaming gear."),
                (10, 20, "Possible remaining ad copy."),
                (20, 30, "Possible program discussion."),
            ]
        )
        backend = _mock_backend([self._classifications(list(range(3)), {0}), '{"content_start_id":2}'])

        assert detect_ads(segs, backend) == []

    def test_multi_cue_self_promo_membership_housekeeping_is_rejected(self):
        segs = _make_segments(
            [
                (0, 10, "People ask how can folks support us and the show."),
                (10, 20, "Our premium membership includes ad-free versions of every episode."),
                (20, 30, "Members can also hear premium exclusive shows."),
            ]
        )
        response = json.dumps({"ads": [[index, "self_promo"] for index in range(3)]})

        assert detect_ads(segs, _mock_backend([response])) == []

    def test_real_self_promo_without_multiple_housekeeping_cues_is_retained(self):
        segs = _make_segments(
            [
                (0, 10, "Join our premium membership."),
                (10, 20, "Visit giantbomb.com slash join today for the new subscriber bonus."),
                (20, 30, "Sign up now."),
            ]
        )
        response = json.dumps({"ads": [[index, "self_promo"] for index in range(3)]})

        assert detect_ads(segs, _mock_backend([response])) == [
            AdSegment(0, 30, COARSE_CONFIDENCE_CEILING, "self_promo")
        ]

    def test_jre_ford_editorial_false_positive_is_discarded_before_boundary_calls(self):
        prior_count = 1075
        prior_duration = 5093.44 / prior_count
        segs = _make_segments(
            [
                (index * prior_duration, (index + 1) * prior_duration, f"editorial segment {index}")
                for index in range(prior_count)
            ]
            + [
                (5093.44, 5160.92, "oh and this is Ford."),
                (5160.92, 5170.0, "They rehired engineers after the AI system failed."),
            ]
        )
        backend = MagicMock()

        def generate(_system_prompt, transcript_text):
            ids = [int(line.split("]", 1)[0].removeprefix("[ID ")) for line in transcript_text.splitlines()]
            return self._classifications(ids, {1075} if 1075 in ids else set()), 100

        backend.generate = MagicMock(side_effect=generate)

        assert detect_ads(segs, backend) == []
        assert any("[ID 1075]" in call.args[1] for call in backend.generate.call_args_list)
        assert all("EDGE=" not in call.args[1] for call in backend.generate.call_args_list)
        assert all("CONFIRMED_END_ID=" not in call.args[1] for call in backend.generate.call_args_list)

    def test_huge_single_segment_classification_request_is_hard_bounded(self):
        text = "HEAD-EVIDENCE " + "x" * 20_000 + " TAIL-EVIDENCE"
        backend = _mock_backend(['{"ads":[]}'])

        assert detect_ads(_make_segments([(0, 10, text)]), backend) == []
        user_content = backend.generate.call_args.args[1]
        assert len(user_content) <= 12_000
        assert "[ID 0]" in user_content
        assert "HEAD-EVIDENCE" in user_content
        assert "TAIL-EVIDENCE" in user_content
        assert "[TRUNCATED]" in user_content

    def test_huge_left_boundary_context_is_hard_bounded_and_keeps_required_ids(self):
        segs = _make_segments(
            [
                (0, 10, "LEFT-HEAD " + "x" * 20_000 + " LEFT-TAIL"),
                (10, 20, "This episode is brought to you by Acme."),
            ]
        )
        backend = _mock_backend(['{"include":false}'])

        result = _verify_ad_boundaries(_CoarseAdRun(1, 1, 1.0, "sponsor_read"), segs, backend)

        assert result == AdSegment(10, 20, 1.0, "sponsor_read")
        user_content = backend.generate.call_args.args[1]
        assert len(user_content) <= 12_000
        assert "CANDIDATE_ID=0" in user_content
        assert "[ID 0]" in user_content and "[ID 1]" in user_content
        assert "LEFT-HEAD" in user_content and "LEFT-TAIL" in user_content

    def test_huge_pod_end_context_is_hard_bounded_and_keeps_required_ids(self):
        segs = _make_segments(
            [
                (0, 10, "Visit acme.com and use code SHOW."),
                (10, 20, "NEXT-HEAD " + "x" * 20_000 + " NEXT-TAIL"),
                (20, 30, "FINAL-HEAD " + "y" * 20_000 + " FINAL-TAIL"),
            ]
        )
        backend = _mock_backend(['{"content_start_id":1}'])

        result = _verify_ad_boundaries(_CoarseAdRun(0, 0, 1.0, "sponsor_read"), segs, backend)

        assert result == AdSegment(0, 10, 1.0, "sponsor_read")
        user_content = backend.generate.call_args.args[1]
        assert len(user_content) <= 12_000
        assert "CONFIRMED_AD_SEED_ID=0" in user_content
        assert all(f"[ID {segment_id}]" in user_content for segment_id in range(3))
        assert "NEXT-HEAD" in user_content and "NEXT-TAIL" in user_content
        assert "FINAL-HEAD" in user_content and "FINAL-TAIL" in user_content
