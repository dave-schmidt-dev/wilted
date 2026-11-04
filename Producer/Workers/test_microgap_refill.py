"""Regressions for anchored short opening-gap recovery."""
from __future__ import annotations

import dataclasses
import unittest
from unittest import mock

from wilted_worker import microgap_refill


@dataclasses.dataclass(frozen=True)
class Token:
    text: str
    start_s: float
    end_s: float


@dataclasses.dataclass(frozen=True)
class Segment:
    start_s: float
    end_s: float
    text: str
    tokens: tuple[Token, ...]
    marker: str = "transcript"


def segment(*items: tuple[str, float, float], marker: str = "transcript") -> Segment:
    tokens = tuple(Token(text, start, end) for text, start, end in items)
    return Segment(tokens[0].start_s, tokens[-1].end_s,
                   "".join(token.text for token in tokens).strip(), tokens, marker)


def baseline() -> list[Segment]:
    return [
        segment(("Left", 0.8, 1.2)),
        segment(("Right", 1.8, 2.4)),
    ]


def decoded_with(*middle: tuple[str, float, float]) -> list[Segment]:
    return [segment(("Left", 0.9, 1.15), *middle, (" Right", 1.85, 2.1))]


class MicrogapPlanningTests(unittest.TestCase):
    def test_only_positive_sub_two_second_gaps_inside_opening_are_selected(self):
        cues = [
            segment(("first", 0.0, 1.0)),
            segment((".", 1.0, 1.1)),
            segment(("second", 1.5, 2.0)),
            segment(("third", 4.0, 5.0)),
            segment(("late", 301.0, 302.0)),
        ]
        gaps = microgap_refill.find_intercue_microgaps(cues, 400.0)
        self.assertEqual([(gap.start_s, gap.end_s) for gap in gaps], [(1.0, 1.5)])

    def test_invalid_lexical_timing_fails_closed(self):
        cues = [segment(("first", 0.0, 1.0)), Segment(float("nan"), 1.2, "unknown", ())]
        self.assertEqual(microgap_refill.find_intercue_microgaps(cues, 20.0), [])

    def test_float_noise_and_subframe_gaps_do_not_consume_windows(self):
        cues = [
            segment(("first", 0.0, 1.0)),
            segment(("same-frame", 1.000000000000004, 1.5)),
            segment(("subframe", 1.5005, 2.0)),
            segment(("real-gap", 2.002, 2.5)),
        ]
        gaps = microgap_refill.find_intercue_microgaps(cues, 10.0)
        self.assertEqual([(gap.start_s, gap.end_s) for gap in gaps], [(2.0, 2.002)])

    def test_overlapping_context_windows_merge_within_thirty_second_cap(self):
        gaps = [
            microgap_refill.InterCueGap(10.0, 11.0, 0, 1),
            microgap_refill.InterCueGap(15.0, 16.0, 2, 3),
            microgap_refill.InterCueGap(40.0, 41.0, 4, 5),
        ]
        cues = [
            segment(("left1", 8.0, 10.0)), segment(("right1", 11.0, 14.0)),
            segment(("left2", 14.0, 15.0)), segment(("right2", 16.0, 20.0)),
            segment(("left3", 38.0, 40.0)), segment(("right3", 41.0, 44.0)),
        ]
        windows, unresolved, cap_skipped = microgap_refill.plan_microgap_windows(gaps, 100.0, cues)
        self.assertEqual(windows, [
            microgap_refill.ContextWindow(7.0, 20.0, (0, 1)),
            microgap_refill.ContextWindow(37.0, 44.0, (2,)),
        ])
        self.assertEqual((unresolved, cap_skipped), (0, 0))

    def test_window_call_cap_reports_unselected_gaps(self):
        cues = []
        gaps = []
        for index in range(9):
            start = 10.0 + 40 * index
            left_index = len(cues)
            cues.extend((segment((f"left{index}", start, start + 1.0)),
                         segment((f"right{index}", start + 1.5, start + 2.5))))
            gaps.append(microgap_refill.InterCueGap(start + 1.0, start + 1.5, left_index, left_index + 1))
        windows, unresolved, cap_skipped = microgap_refill.plan_microgap_windows(gaps, 500.0, cues)
        self.assertEqual(len(windows), 8)
        self.assertEqual((unresolved, cap_skipped), (0, 1))

    def test_window_skips_when_both_complete_cues_exceed_thirty_seconds(self):
        cues = [segment(("long-left", 0.0, 20.0)), segment(("long-right", 21.0, 40.0))]
        gaps = [microgap_refill.InterCueGap(20.0, 21.0, 0, 1)]
        windows, unresolved, cap_skipped = microgap_refill.plan_microgap_windows(gaps, 100.0, cues)
        self.assertEqual(windows, [])
        self.assertEqual((unresolved, cap_skipped), (1, 0))

    def test_refill_executes_at_most_eight_context_decodes(self):
        cues = []
        for index in range(9):
            start = 10.0 + 40.0 * index
            cues.extend((segment((f"left{index}", start, start + 1.0)),
                         segment((f"right{index}", start + 1.5, start + 2.5))))
        calls = []
        with mock.patch.object(microgap_refill.subprocess, "run"):
            microgap_refill.refill_intercue_microgaps(
                "source.wav", cues, 400.0, lambda path: calls.append(path) or []
            )
        self.assertEqual(len(calls), microgap_refill.MICROGAP_MAX_WINDOWS)


class MicrogapReconciliationTests(unittest.TestCase):
    def run_refill(self, original, decoded, duration=10.0):
        with mock.patch.object(microgap_refill.subprocess, "run"):
            return microgap_refill.refill_intercue_microgaps(
                "source.wav", original, duration, lambda _path: decoded
            )

    def test_missing_word_is_a_separate_bounded_segment(self):
        result = self.run_refill(baseline(), decoded_with((" At", 1.4, 1.55)))
        added = [item for item in result if item.text == "At"]
        self.assertEqual([(item.start_s, item.end_s) for item in added], [(1.4, 1.55)])
        right = next(item for item in result if item.text == "Right")
        self.assertEqual((right.start_s, right.end_s), (1.8, 2.4))
        self.assertFalse(any(item.start_s < 1.4 and item.end_s > 1.2 for item in result))
        self.assertFalse(any(item.start_s < 1.8 and item.end_s > 1.55 for item in result))

    def test_multiple_recovered_words_keep_their_individual_source_intervals(self):
        result = self.run_refill(baseline(), decoded_with(
            (" At", 1.3, 1.42), (" Michael", 1.56, 1.72)
        ))
        additions = [item for item in result if item.text in {"At", "Michael"}]
        self.assertEqual([(item.text, item.start_s, item.end_s) for item in additions], [
            ("At", 1.3, 1.42), ("Michael", 1.56, 1.72)
        ])

    def test_matched_word_extends_only_its_source_supported_boundary(self):
        original = [segment(("Again", 0.8, 1.2)), baseline()[1]]
        decoded = [segment(("Again", 0.9, 1.35), (" Right", 1.85, 2.1))]
        result = self.run_refill(original, decoded)
        again = next(item for item in result if item.text == "Again")
        self.assertEqual((again.start_s, again.end_s), (0.8, 1.35))
        self.assertEqual(again.tokens[0].end_s, 1.35)
        self.assertEqual(next(item for item in result if item.text == "Right").start_s, 1.8)

    def test_true_repeated_words_remain_two_separate_occurrences(self):
        decoded = decoded_with((" very", 1.3, 1.4), (" very", 1.45, 1.6))
        result = self.run_refill(baseline(), decoded)
        repeated = [item for item in result if item.text.casefold() == "very"]
        self.assertEqual([(item.start_s, item.end_s) for item in repeated], [(1.3, 1.4), (1.45, 1.6)])

    def test_padding_only_duplicates_do_not_create_gap_words(self):
        original = [segment(("Echo", 0.8, 1.2)), segment(("Right", 1.8, 2.4))]
        decoded = [segment(("Echo", 0.9, 1.1), (" echo", 1.0, 1.15), (" Right", 1.85, 2.1))]
        result = self.run_refill(original, decoded)
        self.assertEqual([(item.text, item.start_s, item.end_s) for item in result], [
            ("Echo", 0.8, 1.2), ("Right", 1.8, 2.4)
        ])

    def test_ambiguous_anchor_repetition_leaves_input_unchanged(self):
        original = [segment(("Echo", 0.8, 1.2)), segment(("Right", 1.8, 2.4))]
        decoded = [segment(("Echo", 0.9, 1.05), (" Echo", 1.0, 1.15),
                           (" At", 1.4, 1.55), (" Right", 1.85, 2.1))]
        result = self.run_refill(original, decoded)
        self.assertEqual(result, original)

    def test_unanchored_or_empty_decode_leaves_input_unchanged(self):
        original = [Segment(0.8, 1.2, "Left", ()), Segment(1.8, 2.4, "Right", ())]
        result = self.run_refill(original, [segment(("At", 1.4, 1.55))])
        self.assertEqual(result, original)
        self.assertEqual(self.run_refill(baseline(), []), baseline())

    def test_partial_unmatched_word_crossing_gap_edge_is_rejected(self):
        decoded = decoded_with((" At", 1.1, 1.4))
        result = self.run_refill(baseline(), decoded)
        self.assertEqual(result, baseline())

    def test_punctuation_only_decode_does_not_become_a_recovered_cue(self):
        result = self.run_refill(baseline(), decoded_with(("!", 1.4, 1.55)))
        self.assertEqual(result, baseline())

    def test_existing_segment_metadata_is_not_reclassified(self):
        original = [
            dataclasses.replace(baseline()[0], marker="programme"),
            dataclasses.replace(baseline()[1], marker="programme"),
        ]
        decoded = [dataclasses.replace(decoded_with((" At", 1.4, 1.55))[0], marker="context")]
        result = self.run_refill(original, decoded)
        self.assertEqual([item.marker for item in result if item.text in {"Left", "Right"}],
                         ["programme", "programme"])
        self.assertEqual(next(item.marker for item in result if item.text == "At"), "context")

    def test_exact_edge_fragment_completion_replaces_only_that_word_slot(self):
        original = [
            segment(("reliable", 0.8, 1.1)),
            Segment(1.4, 2.2, "yota trucks", (
                Token("y", 1.4, 1.6), Token("ota", 1.6, 1.8), Token(" trucks", 1.8, 2.1)
            )),
        ]
        decoded = [segment(
            ("reliable", 0.82, 1.1), (" Toyota", 1.24, 1.8), (" trucks", 1.8, 2.1)
        )]
        result = self.run_refill(original, decoded)
        self.assertEqual([(item.text, item.start_s, item.end_s) for item in result], [
            ("reliable", 0.8, 1.1), ("Toyota trucks", 1.24, 2.2)
        ])
        self.assertEqual([token.text for token in result[1].tokens], ["Toyota", " trucks"])

    def test_fragment_replacement_preserves_late_returned_subtoken_timing(self):
        original = [
            segment(("reliable", 0.8, 1.1)),
            Segment(1.4, 2.2, "yota trucks", (
                Token("y", 1.4, 1.6), Token("ota", 1.6, 1.8), Token(" trucks", 2.0, 2.2)
            )),
        ]
        decoded = [segment(
            ("reliable", 0.82, 1.1), (" Toy", 1.24, 1.7), ("ota", 1.84, 1.9),
            (" trucks", 2.0, 2.2),
        )]
        result = self.run_refill(original, decoded)
        completed = result[1]
        self.assertEqual(completed.text, "Toyota trucks")
        self.assertEqual((completed.tokens[1].start_s, completed.tokens[1].end_s), (1.84, 1.9))
        self.assertGreater(completed.tokens[1].end_s, completed.tokens[1].start_s)

    def test_short_and_whitespace_marked_fragments_do_not_complete(self):
        cases = ((" a", "data"), (" ab", "grab"), (" art", "start"), (" shop", "workshop"))
        for fragment, completion in cases:
            with self.subTest(fragment=fragment, completion=completion):
                original = [
                    segment(("reliable", 0.8, 1.1)),
                    Segment(1.4, 2.2, f"{fragment.strip()} now", (
                        Token(fragment, 1.4, 1.8), Token(" now", 1.8, 2.2)
                    )),
                ]
                decoded = [segment(
                    ("reliable", 0.82, 1.1), (f" {completion}", 1.24, 1.8), (" now", 1.8, 2.2)
                )]
                self.assertEqual(self.run_refill(original, decoded), original)

    def test_fragment_completion_rejects_competing_baseline_word_overlap(self):
        original = [
            segment(("reliable", 0.8, 1.1)),
            Segment(1.4, 2.2, "yota trucks", (
                Token("y", 1.4, 1.6), Token("ota", 1.6, 1.8), Token(" trucks", 1.75, 2.1)
            )),
        ]
        decoded = [segment(
            ("reliable", 0.82, 1.1), (" Toyota", 1.24, 1.85), (" trucks", 1.85, 2.1)
        )]
        self.assertEqual(self.run_refill(original, decoded), original)

    def test_fragment_replacement_requires_token_text_agreement(self):
        original = [
            segment(("reliable", 0.8, 1.1)),
            Segment(1.4, 2.2, "yota bonus trucks", (
                Token("y", 1.4, 1.6), Token("ota", 1.6, 1.8), Token(" trucks", 1.8, 2.1)
            )),
        ]
        decoded = [segment(
            ("reliable", 0.82, 1.1), (" Toyota", 1.24, 1.8), (" trucks", 1.8, 2.1)
        )]
        self.assertEqual(self.run_refill(original, decoded), original)

    def test_timing_only_update_preserves_original_segment_text(self):
        original = [
            Segment(0.8, 1.2, "Left original text", (Token("Left", 0.8, 1.2),)),
            segment(("Right", 1.8, 2.4)),
        ]
        decoded = [segment(("Left", 0.9, 1.35), (" Right", 1.85, 2.1))]
        result = self.run_refill(original, decoded)
        self.assertEqual(result[0].text, "Left original text")
        self.assertEqual(result[0].end_s, 1.35)

    def test_frame_bounded_independent_word_preserves_neighbor_and_repeated_words(self):
        # Extra distant baseline words make full-transcript indices differ from
        # the crop-local decoded indices used to place the recovered word.
        original = [segment((f"old{index}", index * 3.0, index * 3.0 + 0.5)) for index in range(16)]
        original.extend((
            Segment(48.8, 49.2, "row", (Token("row", 48.8, 49.2),)),
            Segment(49.6, 50.2, "Michael", (Token("Michael", 49.6, 50.2),)),
        ))
        decoded = [Segment(2.8, 3.8, "row At Michael", (
            Token("row", 2.8, 3.08),
            Token(" At", 3.16, 3.44),
            Token(" Michael", 3.44, 3.8),
        ))]
        result = self.run_refill(original, decoded, duration=60.0)
        recovered = next(item for item in result if item.text == "At")
        row = next(item for item in result if item.text == "row")
        michael = next(item for item in result if item.text == "Michael")
        self.assertEqual((recovered.start_s, recovered.end_s), (49.36, 49.64))
        self.assertEqual(row.end_s, 49.28)
        self.assertEqual((michael.start_s, michael.end_s), (49.6, 50.2))

        repeated_original = [segment(("very", 0.8, 1.2)), segment(("indeed", 1.6, 2.0))]
        repeated_decode = [segment(
            ("very", 0.9, 1.15), (" very", 1.18, 1.4), (" indeed", 1.7, 1.9)
        )]
        repeated = self.run_refill(repeated_original, repeated_decode)
        occurrences = [item for item in repeated if item.text.casefold() == "very"]
        self.assertEqual([(item.start_s, item.end_s) for item in occurrences], [(0.8, 1.2), (1.18, 1.4)])

    def test_neighbor_overlap_over_eighty_milliseconds_is_rejected(self):
        original = [
            segment(("row", 1.0, 1.2)),
            segment(("Michael", 1.4, 2.0)),
        ]
        decoded = [segment(
            ("row", 1.0, 1.2), (" At", 1.24, 1.481), (" Michael", 1.481, 1.9)
        )]
        self.assertEqual(self.run_refill(original, decoded), original)


if __name__ == "__main__":
    unittest.main()
