"""Tests for ad detection recovery and explicit anchors."""

from __future__ import annotations

from unittest.mock import MagicMock

from wilted.ads import (
    _BOUNDARY_VERIFY_RESPONSE_FORMAT,
    _BRACKETED_SEED_VERIFY_SYSTEM_PROMPT,
    _POD_START_VERIFY_SYSTEM_PROMPT,
    _SPONSOR_ANCHOR_VERIFY_SYSTEM_PROMPT,
    COARSE_CONFIDENCE_CEILING,
    AdSegment,
    _CoarseAdRun,
    _id_response_format,
    _recover_bracketed_ad_pods,
    _recover_explicit_sponsor_pods,
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

        assert detect_ads(segs, backend) == [AdSegment(10, 50, 0.5, "ad_break")]

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

        assert detect_ads(segs, self._content_backend()) == [AdSegment(20, 50, 0.5, "ad_break")]

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
        ) == [AdSegment(10, 60, 0.8, "ad_break")]
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
        ) == [AdSegment(20, 50, 0.6, "ad_break")]
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

        assert detect_ads(segs, backend) == [AdSegment(20, 40, 0.7, "sponsor_read")]
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

        assert detect_ads(segs, backend) == [AdSegment(14, 50, 0.7, "sponsor_read")]
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

        assert _recover_explicit_sponsor_pods(segs, backend, [_CoarseAdRun(1, 1, 1.0, "sponsor_read")]) == (
            [AdSegment(0, 20, 0.7, "sponsor_read")],
            [(0, 1)],
        )
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

        assert _recover_explicit_sponsor_pods(segs, backend, [_CoarseAdRun(1, 3, 1.0, "sponsor_read")]) == (
            [AdSegment(0, 40, 0.7, "sponsor_read")],
            [(0, 3)],
        )
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

        assert _recover_explicit_sponsor_pods(segs, backend, [_CoarseAdRun(3, 3, 1.0, "sponsor_read")]) == (
            [],
            [(0, 3)],
        )

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

        assert detect_ads(segs, backend) == [AdSegment(0, 80, COARSE_CONFIDENCE_CEILING, "sponsor_read")]
        assert backend.generate.call_args_list[1].args[0] == _POD_START_VERIFY_SYSTEM_PROMPT
        assert "CANDIDATE_START_MIN_ID=0" in backend.generate.call_args_list[1].args[1]
        assert backend.generate.call_args_list[1].kwargs["response_format"] == _id_response_format(
            "start_id", [0, 1, 2, 3, 4, 5]
        )
