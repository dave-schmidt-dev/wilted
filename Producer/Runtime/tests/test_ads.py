"""Tests for ad detection, audio cutting, and promotional content removal (ads.py)."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from unittest.mock import MagicMock, patch

import pytest

from wilted.ads import (
    _AD_DETECT_CORRECTION_PROMPT,
    _AD_DETECT_RESPONSE_FORMAT,
    _AD_DETECT_SYSTEM_PROMPT,
    _BOUNDARY_VERIFY_RESPONSE_FORMAT,
    _BRACKETED_SEED_VERIFY_SYSTEM_PROMPT,
    _POD_START_VERIFY_SYSTEM_PROMPT,
    _PREROLL_CONTENT_VERIFY_SYSTEM_PROMPT,
    _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT,
    _SPONSOR_ANCHOR_VERIFY_SYSTEM_PROMPT,
    _TRUNCATION_MARKER,
    AdSegment,
    _chunk_segments,
    _CoarseAdRun,
    _compute_keep_segments,
    _id_response_format,
    _merge_adjacent,
    _parse_ad_response,
    _recover_bracketed_ad_pods,
    _recover_explicit_sponsor_pods,
    _resolve_overlaps,
    _truncate_head_tail,
    _verify_ad_boundaries,
    cut_ads,
    detect_ads,
    remove_promos,
    remove_promos_batch,
)


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
# Local TranscriptSegment for tests (avoids dependency on transcribe.py)
# ---------------------------------------------------------------------------


@dataclass
class TranscriptSegment:
    start_s: float
    end_s: float
    text: str
    tokens: tuple[object, ...] | None = None


@dataclass
class _AlignedToken:
    text: str
    start_s: float
    end_s: float


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
    @staticmethod
    def _classifications(ids: list[int], ad_ids: set[int] = frozenset()) -> str:
        return json.dumps({"ads": [[segment_id, "sponsor_read"] for segment_id in ids if segment_id in ad_ids]})

    @staticmethod
    def _content_backend() -> MagicMock:
        backend = MagicMock()

        def generate(_system_prompt, transcript_text):
            return json.dumps({"ads": []}), 100

        backend.generate = MagicMock(side_effect=generate)
        return backend

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

        assert detect_ads(segs, backend) == [AdSegment(10, 20, 1.0, "sponsor_read")]
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

        assert detect_ads(segs, backend) == [AdSegment(10, 41, 1.0, "sponsor_read")]

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

        assert detect_ads(segs, backend) == [AdSegment(10, 20, 1.0, "sponsor_read")]

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

        assert _resolve_overlaps(overlapping_votes, segs) == [_CoarseAdRun(0, 2, 1.0, "sponsor_read")]

    def test_post_vote_completion_keeps_adjacent_editorial_legal_discussion_as_content(self):
        segs = _make_segments(
            [
                (0, 10, "Visit acme.com and use offer code SHOW."),
                (10, 20, "The guests discuss how lawyers provide legal advice and independently review cases."),
            ]
        )
        votes = [[(0, True, "sponsor_read"), (1, False, None)]]

        assert _resolve_overlaps(votes, segs) == [_CoarseAdRun(0, 0, 1.0, "sponsor_read")]

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

        assert detect_ads(segs, backend) == [AdSegment(0, 10, 1.0, "sponsor_read")]
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

        assert detect_ads(segs, backend) == [AdSegment(0, 10, 1.0, "ad_break")]

    @pytest.mark.parametrize(
        "text",
        [
            "This episode is brought to you by Acme.",
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

        assert detect_ads(segs, backend) == [AdSegment(0, 10, 1.0, "sponsor_read")]
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

        assert detect_ads(segs, backend) == [AdSegment(0, 20, 1.0, "sponsor_read")]
        verifier_call = backend.generate.call_args_list[1]
        assert verifier_call.args[0] == _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT
        assert verifier_call.kwargs["response_format"] == _id_response_format(
            "content_start_id", [1, 2, 3, 4]
        )

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

        assert detect_ads(segs, _mock_backend([response])) == [AdSegment(0, 30, 1.0, "self_promo")]

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
        assert detect_ads(segs, backend) == [AdSegment(10, 20, 1.0, "sponsor_read")]
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
    def test_compact_requests_are_bounded_for_short_dense_and_long_podcasts(
        self, duration_s, segment_count, text_size
    ):
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
            [
                (index * segment_duration, (index + 1) * segment_duration, "x" * 250)
                for index in range(segment_count)
            ]
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

        assert detect_ads(segs, backend) == [AdSegment(10, 30, 1.0, "sponsor_read")]
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

        assert detect_ads(segs, backend) == [AdSegment(10, 40, 1.0, "sponsor_read")]

    def test_below_threshold_run_skips_boundary_verification(self):
        segs = _make_segments([(0, 1000, "possible ad")])
        ad = self._classifications([0], {0})
        content = self._classifications([0])
        backend = _mock_backend([ad, ad, content])

        assert detect_ads(segs, backend, chunk_minutes=10, overlap_minutes=2, confidence_threshold=0.8) == []
        assert backend.generate.call_count == 3

    def test_noncontiguous_ad_runs_are_not_merged(self):
        segs = _make_segments(
            [(0, 10, "Visit acme.com."), (10, 20, "editorial"), (20, 30, "Use promo code ROGAN.")]
        )
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
        backend = _mock_backend(
            [classification, '{"include":true}', '{"include":true}', '{"content_start_id":7}']
        )

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

    def test_bracketed_smartless_pod_recovers_only_with_two_independent_commercial_signals(self):
        segs = _make_segments(
            [
                (0, 10, "We'll be right back."),
                (10, 20, "This is a paid ad for BetterHelp."),
                (20, 30, "Visit helixsleep.com today for a free trial."),
                (30, 40, "Terms and conditions apply."),
                (40, 50, "And now back to the show."),
                (50, 60, "The hosts resume their overlapping conversation."),
            ]
        )
        backend = self._content_backend()

        assert detect_ads(segs, backend) == [AdSegment(10, 50, 1.0, "ad_break")]

    def test_bracketed_pod_preserves_panel_chatter_before_sponsor_opening(self):
        segs = _make_segments(
            [
                (0, 10, "We'll be right back."),
                (10, 20, "The panel keeps discussing the court decision for another moment."),
                (20, 30, "This episode is brought to you by Acme."),
                (30, 40, "Visit acme.com and use code SHOW."),
                (40, 50, "And now back to the show."),
                (50, 60, "The panel resumes the court discussion."),
            ]
        )

        assert detect_ads(segs, self._content_backend()) == [AdSegment(20, 50, 1.0, "ad_break")]

    def test_bracketed_pod_semantically_recovers_story_ad_before_sponsor_anchor(self):
        segs = _make_segments(
            [
                (0, 10, "We'll be right back."),
                (10, 20, "Hot nights can leave you tossing and turning without air conditioning."),
                (20, 30, "The mattress has cooling upgrades and free shipping."),
                (30, 40, "This is a paid ad for BetterHelp."),
                (40, 50, "Visit betterhelp.com today for a free trial."),
                (50, 60, "And now back to the show."),
                (60, 70, "The interview resumes."),
            ]
        )
        backend = _mock_backend(['{"include":true}', '{"start_id":2}', '{"include":true}'])

        assert _recover_bracketed_ad_pods(
            segs,
            backend,
            [_CoarseAdRun(2, 2, 1.0, "sponsor_read")],
        ) == [AdSegment(10, 60, 1.0, "ad_break")]
        assert backend.generate.call_args_list[0].args[0] == _BRACKETED_SEED_VERIFY_SYSTEM_PROMPT
        assert backend.generate.call_args_list[1].args[0] == _POD_START_VERIFY_SYSTEM_PROMPT
        assert backend.generate.call_args_list[2].kwargs["response_format"] == _BOUNDARY_VERIFY_RESPONSE_FORMAT

    def test_bracketed_pod_rejects_false_positive_panel_seed_before_sponsor(self):
        segs = _make_segments(
            [
                (0, 10, "We'll be right back."),
                (10, 20, "The panel keeps discussing the court decision for another moment."),
                (20, 30, "This episode is brought to you by Acme."),
                (30, 40, "Visit acme.com and use code SHOW."),
                (40, 50, "And now back to the show."),
                (50, 60, "The panel resumes the court discussion."),
            ]
        )
        backend = _mock_backend(['{"include":false}'])

        assert _recover_bracketed_ad_pods(
            segs,
            backend,
            [_CoarseAdRun(1, 1, 1.0, "sponsor_read")],
        ) == [AdSegment(20, 50, 1.0, "ad_break")]
        assert backend.generate.call_count == 1

    def test_explicit_anchor_preserves_delayed_panel_chatter_before_sponsor_read(self):
        segs = _make_segments(
            [
                (0, 10, "We need to take a break."),
                (10, 20, "The panel keeps discussing the court decision for another moment."),
                (20, 30, "Our show today is brought to you by Acme."),
                (30, 40, "Visit acme.com and use code SHOW."),
                (45, 55, "Back to the panel and the court decision."),
            ]
        )
        backend = _mock_backend([self._classifications(list(range(5)), {3}), '{"content_start_id":4}'])

        assert detect_ads(segs, backend) == [AdSegment(20, 40, 1.0, "sponsor_read")]
        assert backend.generate.call_args_list[1].args[0] == _SPONSOR_ANCHOR_VERIFY_SYSTEM_PROMPT

    def test_explicit_anchor_replaces_partial_coarse_run_and_advances_past_sponsor_tail(self):
        segs = _make_segments(
            [
                (0, 10, "Panel discussion."),
                (10, 20, "Panel aside. Our show today brought to you by Acme."),
                (20, 30, "Acme protects your business."),
                (30, 40, "Visit acme.com and use code SHOW."),
                (40, 50, "Thank you to Acme for supporting the show. Our interview with its CEO is in the feed."),
                (55, 65, "The panel discusses a new court ruling."),
            ]
        )
        segs[1] = TranscriptSegment(
            10,
            20,
            segs[1].text,
            tokens=(
                _AlignedToken("Panel aside.", 10, 14),
                _AlignedToken(" Our show today brought to you by Acme.", 14, 20),
            ),
        )
        backend = _mock_backend([self._classifications(list(range(6)), {3}), '{"content_start_id":4}'])

        assert detect_ads(segs, backend) == [AdSegment(14, 50, 1.0, "sponsor_read")]
        anchor_call = backend.generate.call_args_list[1]
        assert anchor_call.kwargs["response_format"] == _id_response_format("content_start_id", [2, 3, 4, 5])
        assert backend.generate.call_count == 2

    def test_invalid_explicit_anchor_verifier_fails_closed(self):
        segs = _make_segments(
            [
                (0, 10, "Our sponsor for this section is Acme."),
                (10, 20, "Visit acme.com."),
                (20, 30, "Program discussion."),
            ]
        )
        backend = _mock_backend([self._classifications(list(range(3)), {1}), '{"content_start_id":99}'])

        assert detect_ads(segs, backend) == []
        assert backend.generate.call_count == 2

    def test_explicit_anchor_without_positive_seed_does_not_call_verifier(self):
        segs = _make_segments(
            [
                (0, 10, "Our show today is brought to you by Acme."),
                (10, 20, "Visit acme.com."),
                (20, 30, "Program discussion."),
            ]
        )
        backend = _mock_backend([self._classifications(list(range(3)))])

        assert detect_ads(segs, backend) == []
        assert backend.generate.call_count == 1

    def test_sponsor_acknowledgement_and_editorial_mention_do_not_create_anchor(self):
        segs = _make_segments(
            [
                (0, 10, "Thanks to Acme for supporting our show."),
                (10, 20, "The panel discusses Acme's latest product and criticizes its pricing."),
            ]
        )
        backend = _mock_backend([self._classifications(list(range(2)))])

        assert detect_ads(segs, backend) == []
        assert backend.generate.call_count == 1

    def test_explicit_anchor_recovery_keeps_legacy_two_argument_backend_compatible(self):
        segs = _make_segments(
            [
                (0, 10, "Today's sponsor is Acme."),
                (10, 20, "Visit acme.com."),
                (20, 30, "Program discussion."),
            ]
        )

        def generate(_system_prompt, _transcript_text):
            return '{"content_start_id":2}', 1

        backend = MagicMock()
        backend.generate = MagicMock(wraps=generate)

        assert _recover_explicit_sponsor_pods(
            segs, backend, [_CoarseAdRun(1, 1, 1.0, "sponsor_read")]
        ) == ([AdSegment(0, 20, 1.0, "sponsor_read")], [(0, 1)])
        assert backend.generate.call_args.kwargs == {}

    def test_explicit_anchor_recovery_skips_second_anchor_inside_recovered_pod(self):
        segs = _make_segments(
            [
                (0, 10, "Today's sponsor is Acme."),
                (10, 20, "Acme protects your business."),
                (20, 30, "Our show today is brought to you by Acme."),
                (30, 40, "Visit acme.com."),
                (40, 50, "Program discussion."),
            ]
        )
        backend = _mock_backend(['{"content_start_id":4}'])

        assert _recover_explicit_sponsor_pods(
            segs, backend, [_CoarseAdRun(1, 3, 1.0, "sponsor_read")]
        ) == ([AdSegment(0, 40, 1.0, "sponsor_read")], [(0, 3)])
        assert backend.generate.call_count == 1

    def test_explicit_anchor_at_truncated_context_edge_fails_closed(self):
        segs = _make_segments([(index * 5, index * 5 + 5, f"segment {index}") for index in range(66)])
        segs[0] = TranscriptSegment(0, 5, "Today's sponsor is Acme.")
        segs[1] = TranscriptSegment(5, 10, "Visit acme.com.")
        backend = _mock_backend(
            [
                self._classifications(list(range(64)), {1}),
                self._classifications([64, 65]),
                '{"content_start_id":63}',
            ]
        )

        assert detect_ads(segs, backend, chunk_minutes=10, overlap_minutes=0) == []
        assert backend.generate.call_count == 3

    def test_explicit_anchor_requires_positive_seed_inside_verified_span(self):
        segs = _make_segments(
            [
                (0, 10, "Today's sponsor is Acme."),
                (10, 20, "Opening sponsor copy."),
                (20, 30, "Program discussion."),
                (30, 40, "Visit acme.com."),
            ]
        )
        backend = _mock_backend(['{"content_start_id":2}'])

        assert _recover_explicit_sponsor_pods(
            segs, backend, [_CoarseAdRun(3, 3, 1.0, "sponsor_read")]
        ) == ([], [(0, 3)])

    def test_empty_smartless_bumpers_are_not_recovered_as_ads(self):
        segs = _make_segments(
            [
                (0, 10, "We'll be right back."),
                (10, 20, "A brief music bed plays."),
                (20, 30, "And now back to the show."),
                (30, 40, "The interview continues."),
            ]
        )

        assert detect_ads(segs, self._content_backend()) == []

    def test_distant_return_bumper_cannot_recover_across_program_content(self):
        segs = _make_segments(
            [(0, 10, "We'll be right back."), (10, 20, "This episode is brought to you by Acme.")]
            + [(index * 10, index * 10 + 10, "Ordinary program conversation.") for index in range(2, 132)]
            + [
                (1320, 1330, "Visit acme.com today for a free trial."),
                (1330, 1340, "And now back to the show."),
            ]
        )

        assert detect_ads(segs, self._content_backend(), chunk_minutes=30, overlap_minutes=2) == []

    def test_strong_sparse_allstate_seed_can_expand_back_to_story_opening(self):
        segs = _make_segments(
            [
                (0, 10, "The place you call home is important to you."),
                (10, 20, "So it is important to Allstate."),
                (20, 30, "Home is where you make your memories."),
                (30, 40, "Like forcing siblings into matching pajamas."),
                (40, 50, "If it is important to you, it is important to Allstate."),
                (50, 60, "Switch to Allstate, and you could save hundreds on home insurance today."),
                (60, 70, "Not available in every state."),
                (70, 80, "Potential savings vary subject to terms and qualifications."),
                (80, 90, "The next commercial begins."),
                (90, 100, "The program continues."),
            ]
        )
        classification = self._classifications(list(range(len(segs))), {5})
        backend = _mock_backend([classification, '{"start_id":0}', '{"content_start_id":8}'])

        assert detect_ads(segs, backend) == [AdSegment(0, 80, 1.0, "sponsor_read")]
        assert backend.generate.call_args_list[1].args[0] == _POD_START_VERIFY_SYSTEM_PROMPT
        assert "CANDIDATE_START_MIN_ID=0" in backend.generate.call_args_list[1].args[1]
        assert backend.generate.call_args_list[1].kwargs["response_format"] == _id_response_format(
            "start_id", [0, 1, 2, 3, 4, 5]
        )

    def test_transcript_start_sponsor_pod_uses_preroll_content_start_timestamp(self):
        segs = _make_segments([(index * 10, index * 10 + 10, f"pre-roll context {index}") for index in range(31)])
        segs[0] = TranscriptSegment(0, 10, "This message is brought to you by Apple Card.")
        segs[1] = TranscriptSegment(10, 20, "Get cash back every day with no annual fee.")
        segs[2] = TranscriptSegment(20, 30, "Visit apple.com slash card to learn more.")
        segs[3] = TranscriptSegment(30, 40, "Terms apply.")
        segs[29] = TranscriptSegment(290, 300, "Jason starts the actual show with a question.")
        classification = self._classifications(list(range(len(segs))), {0, 1, 2, 3})
        backend = _mock_backend([classification, '{"content_start_id":29}'])

        assert detect_ads(segs, backend) == [AdSegment(0, 290, 1.0, "sponsor_read")]
        assert backend.generate.call_args_list[1].args[0] == _PREROLL_CONTENT_VERIFY_SYSTEM_PROMPT
        assert "[ID 29]" in backend.generate.call_args_list[1].args[1]
        assert backend.generate.call_args_list[1].kwargs["response_format"] == _id_response_format(
            "content_start_id", list(range(4, 31))
        )


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

    def test_merge_label_tie_preserves_earlier_run_deterministically(self):
        segs = [
            AdSegment(start_s=10, end_s=20, confidence=0.9, label="sponsor_read"),
            AdSegment(start_s=20, end_s=30, confidence=0.8, label="self_promo"),
        ]

        merged = _merge_adjacent(segs)

        assert len(merged) == 1
        assert merged[0].start_s == 10
        assert merged[0].end_s == 30
        assert merged[0].confidence == pytest.approx(0.85)
        assert merged[0].label == "sponsor_read"


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
