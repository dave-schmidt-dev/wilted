"""Unit tests for transcript word timing, subword token joining, keep-map remapping, and block grouping."""
from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr

from wilted_worker.cue_timing import KeepInterval
from wilted_worker.transcript_blocks import (
    enforce_transcript_caps,
    group_tokenless_cues,
    group_words_into_blocks,
)
from wilted_worker.transcript_word_timing import (
    TranscriptWord,
    extract_words_from_segment,
    extract_words_from_tokens,
    remap_cues_with_keep_map,
    remap_words_with_keep_map,
    validate_words,
)


class FakeToken:
    def __init__(self, text: str, start_s: float, end_s: float):
        self.text = text
        self.start_s = start_s
        self.end_s = end_s


class TranscriptWordTimingTests(unittest.TestCase):
    def test_subword_joining_by_leading_whitespace(self):
        tokens = [
            FakeToken(" hello", 0.0, 0.4),
            FakeToken(" world", 0.5, 0.9),
            FakeToken(" meas", 1.0, 1.3),
            FakeToken("ur", 1.3, 1.5),
            FakeToken("able", 1.5, 1.8),
        ]
        words = extract_words_from_tokens(tokens)
        self.assertEqual(len(words), 3)
        self.assertEqual(words[0].text, "hello")
        self.assertEqual(words[0].start_s, 0.0)
        self.assertEqual(words[0].end_s, 0.4)

        self.assertEqual(words[1].text, "world")
        self.assertEqual(words[1].start_s, 0.5)
        self.assertEqual(words[1].end_s, 0.9)

        self.assertEqual(words[2].text, "measurable")
        self.assertEqual(words[2].start_s, 1.0)
        self.assertEqual(words[2].end_s, 1.8)
        self.assertEqual(words[2].raw_text, "measurable")

    def test_word_to_dict_emits_only_required_fields(self):
        w = TranscriptWord(start_s=1.0, end_s=2.0, text="Word", raw_text="word", speaker="Host", partition_id=3)
        d = w.to_dict()
        self.assertEqual(d, {"startSeconds": 1.0, "endSeconds": 2.0, "text": "Word", "rawText": "word"})
        self.assertNotIn("token", d)
        self.assertNotIn("tokens", d)
        self.assertNotIn("speaker", d)
        self.assertNotIn("partition_id", d)

    def test_extract_words_from_segment(self):
        class Segment:
            tokens = (
                FakeToken(" First", 0.1, 0.5),
                FakeToken(" second", 0.6, 1.0),
            )
            speaker = "Host"

        words = extract_words_from_segment(Segment())
        self.assertEqual(len(words), 2)
        self.assertEqual(words[0].speaker, "Host")
        self.assertEqual(words[1].text, "second")

    def test_validate_words_rejects_negative_or_unordered(self):
        invalid_words = [
            TranscriptWord(start_s=-1.0, end_s=0.5, text="negative"),
            TranscriptWord(start_s=2.0, end_s=1.0, text="backwards_time"),
            TranscriptWord(start_s=0.5, end_s=0.9, text="valid"),
            TranscriptWord(start_s=0.2, end_s=0.8, text="out_of_order"),
            TranscriptWord(start_s=1.0, end_s=1.4, text=""),
        ]
        validated = validate_words(invalid_words)
        self.assertEqual(len(validated), 1)
        self.assertEqual(validated[0].text, "valid")

    def test_keep_map_remap_drops_cut_audio_and_offsets_surviving(self):
        # Audio from 0-10, keep [0-3] and [7-10], cut [3-7]
        keeps = [
            KeepInterval(start_s=0.0, end_s=3.0, output_start_s=0.0),
            KeepInterval(start_s=7.0, end_s=10.0, output_start_s=3.0),
        ]
        words = [
            TranscriptWord(start_s=0.5, end_s=1.2, text="intro"),
            TranscriptWord(start_s=4.0, end_s=5.0, text="ad_sponsor"),
            TranscriptWord(start_s=7.5, end_s=8.5, text="outro"),
        ]
        remapped = remap_words_with_keep_map(words, keeps)
        self.assertEqual(len(remapped), 2)
        self.assertEqual(remapped[0].text, "intro")
        self.assertEqual(remapped[0].start_s, 0.5)
        self.assertEqual(remapped[0].end_s, 1.2)
        self.assertEqual(remapped[0].partition_id, 0)

        # 7.5 original -> 3.0 + (7.5 - 7.0) = 3.5 in cut output
        self.assertEqual(remapped[1].text, "outro")
        self.assertEqual(remapped[1].start_s, 3.5)
        self.assertEqual(remapped[1].end_s, 4.5)
        self.assertEqual(remapped[1].partition_id, 1)

    def test_cut_boundary_rejects_spanning_word_and_separates_adjacent_partitions(self):
        # Keep 1: [0, 5], Keep 2: [15, 20] (cut [5, 15] removed)
        keeps = [
            KeepInterval(start_s=0.0, end_s=5.0, output_start_s=0.0),
            KeepInterval(start_s=15.0, end_s=20.0, output_start_s=5.0),
        ]
        words = [
            TranscriptWord(start_s=3.0, end_s=5.0, text="before_cut", speaker="Alice"),
            # Word spanning the cut boundary at 5.0: must be rejected!
            TranscriptWord(start_s=4.8, end_s=5.5, text="spanning_word", speaker="Alice"),
            # Surviving word immediately at start of keep 2: output time 5.0 to 6.0
            TranscriptWord(start_s=15.0, end_s=16.0, text="after_cut", speaker="Alice"),
        ]
        remapped = remap_words_with_keep_map(words, keeps)
        self.assertEqual(len(remapped), 2)
        self.assertEqual(remapped[0].text, "before_cut")
        self.assertEqual(remapped[0].start_s, 3.0)
        self.assertEqual(remapped[0].end_s, 5.0)
        self.assertEqual(remapped[0].partition_id, 0)

        self.assertEqual(remapped[1].text, "after_cut")
        self.assertEqual(remapped[1].start_s, 5.0)
        self.assertEqual(remapped[1].end_s, 6.0)
        self.assertEqual(remapped[1].partition_id, 1)

        # In output clock, before_cut ends at 5.0 and after_cut starts at 5.0.
        # Grouping MUST NOT merge them because partition_id differs!
        cues = group_words_into_blocks(remapped, min_words=1)
        self.assertEqual(len(cues), 2)
        self.assertEqual(cues[0]["text"], "before_cut")
        self.assertEqual(cues[1]["text"], "after_cut")

    def test_remap_cues_with_keep_map(self):
        keeps = [
            KeepInterval(start_s=0.0, end_s=5.0, output_start_s=0.0),
        ]
        cues = [
            {
                "startSeconds": 0.5,
                "endSeconds": 2.0,
                "text": "Hello there",
                "words": [
                    {"startSeconds": 0.5, "endSeconds": 1.0, "text": "Hello"},
                    {"startSeconds": 1.0, "endSeconds": 2.0, "text": "there"},
                ],
            },
            {
                "startSeconds": 6.0,
                "endSeconds": 8.0,
                "text": "Cut commercial",
            },
        ]
        remapped = remap_cues_with_keep_map(cues, keeps)
        self.assertEqual(len(remapped), 1)
        self.assertEqual(remapped[0]["text"], "Hello there")
        self.assertEqual(len(remapped[0]["words"]), 2)

    def test_speaker_split_and_sentence_grouping(self):
        words = [
            TranscriptWord(start_s=0.0, end_s=0.5, text="Hello.", speaker="Alice"),
            TranscriptWord(start_s=0.6, end_s=1.0, text="Hi.", speaker="Bob"),
        ]
        cues = group_words_into_blocks(words, min_words=1)
        self.assertEqual(len(cues), 2)
        self.assertEqual(cues[0]["speaker"], "Alice")
        self.assertEqual(cues[0]["text"], "Hello.")
        self.assertEqual(cues[1]["speaker"], "Bob")
        self.assertEqual(cues[1]["text"], "Hi.")

    def test_max_duration_is_unconditional_at_word_boundary(self):
        # 40 continuous words with no punctuation or natural pauses
        words = []
        for i in range(40):
            words.append(TranscriptWord(start_s=float(i), end_s=float(i) + 0.9, text=f"word{i}"))
        # With max_duration_s = 10.0, must split around 10s even without sentence boundaries
        cues = group_words_into_blocks(words, max_duration_s=10.0, max_words=50)
        self.assertGreater(len(cues), 1)
        for cue in cues:
            duration = float(cue["endSeconds"]) - float(cue["startSeconds"])
            self.assertLessEqual(duration, 11.0)

    def test_cue_text_8192_byte_cap_enforced_in_grouping(self):
        # Words whose combined text exceeds 8192 bytes
        long_word_text = "x" * 2000
        words = [
            TranscriptWord(start_s=float(i), end_s=float(i) + 0.9, text=long_word_text)
            for i in range(6)
        ]
        cues = group_words_into_blocks(words, max_words=50)
        self.assertGreater(len(cues), 1)
        for cue in cues:
            self.assertLessEqual(len(cue["text"].encode("utf-8")), 8192)

    def test_tokenless_cues_merge_and_preserve_metadata(self):
        cues = [
            {
                "startSeconds": 0.0,
                "endSeconds": 2.0,
                "text": "Part one.",
                "speaker": "Host",
                "rawText": "part one",
                "words": [{"startSeconds": 0.0, "endSeconds": 2.0, "text": "Part one."}],
                "_partition_id": 0,
            },
            {
                "startSeconds": 2.0,
                "endSeconds": 4.0,
                "text": "Part two.",
                "speaker": "Host",
                "rawText": "part two",
                "words": [{"startSeconds": 2.0, "endSeconds": 4.0, "text": "Part two."}],
                "_partition_id": 0,
            },
            {
                "startSeconds": 4.0,
                "endSeconds": 6.0,
                "text": "Different.",
                "speaker": "Guest",
                "_partition_id": 0,
            },
        ]
        grouped = group_tokenless_cues(cues, max_words=50)
        self.assertEqual(len(grouped), 2)
        self.assertEqual(grouped[0]["text"], "Part one. Part two.")
        self.assertEqual(grouped[0]["rawText"], "part one part two")
        self.assertEqual(len(grouped[0]["words"]), 2)
        self.assertEqual(grouped[0]["startSeconds"], 0.0)
        self.assertEqual(grouped[0]["endSeconds"], 4.0)
        self.assertEqual(grouped[0]["speaker"], "Host")
        self.assertNotIn("_partition_id", grouped[0])
        self.assertEqual(grouped[1]["text"], "Different.")

    def test_tokenless_cues_do_not_merge_across_cuts_or_gaps(self):
        cues = [
            {"startSeconds": 0.0, "endSeconds": 2.0, "text": "Before cut", "speaker": "Host", "_partition_id": 0},
            {"startSeconds": 2.0, "endSeconds": 4.0, "text": "After cut", "speaker": "Host", "_partition_id": 1},
        ]
        grouped = group_tokenless_cues(cues)
        self.assertEqual(len(grouped), 2)
        self.assertEqual(grouped[0]["text"], "Before cut")
        self.assertEqual(grouped[1]["text"], "After cut")

    def test_caps_enforcement_optional_detail_fallback(self):
        # 10 cues whose words push payload over budget
        cues = []
        for i in range(10):
            cues.append({
                "startSeconds": float(i),
                "endSeconds": float(i + 1),
                "text": f"Cue {i}",
                "speaker": "Host",
                "rawText": f"Raw {i}",
                "words": [{"startSeconds": float(i), "endSeconds": float(i + 1), "text": f"Cue {i}"}] * 500,
            })
        with redirect_stderr(io.StringIO()):
            from unittest.mock import patch
            with patch("wilted_worker.transcript_blocks.MAX_CUES_ENCODED_BYTES", 1000):
                capped = enforce_transcript_caps(cues)
                self.assertEqual(len(capped), len(cues))
                self.assertNotIn("words", capped[0])
                self.assertEqual(capped[0]["text"], "Cue 0")
                self.assertEqual(capped[0]["speaker"], "Host")

    def test_caps_enforcement_raw_text_boundaries_preserve_base_cue(self):
        accepted_raw = "x" * 8192
        omitted_raw = "x" * 8193
        cues = [
            {"startSeconds": 1.0, "endSeconds": 2.0, "text": "first", "rawText": accepted_raw},
            {"startSeconds": 3.0, "endSeconds": 4.0, "text": "second", "rawText": omitted_raw},
        ]
        with redirect_stderr(io.StringIO()):
            from unittest.mock import patch
            with patch("wilted_worker.transcript_blocks.reporting.progress") as progress:
                capped = enforce_transcript_caps(cues)

        self.assertEqual(capped[0]["rawText"], accepted_raw)
        self.assertNotIn("rawText", capped[1])
        self.assertEqual(capped[1]["text"], "second")
        self.assertEqual(capped[1]["startSeconds"], 3.0)
        self.assertEqual(capped[1]["endSeconds"], 4.0)
        progress.assert_called_once_with(
            "transcript.caps.warning",
            "Transcript optional detail exceeded field byte caps; omitting detail to preserve transcript",
        )

    def test_caps_enforcement_word_text_boundaries_preserve_display_text(self):
        accepted_text = "x" * 1024
        omitted_text = "x" * 1025
        cues = [
            {
                "startSeconds": 1.0,
                "endSeconds": 2.0,
                "text": accepted_text,
                "words": [{"startSeconds": 1.0, "endSeconds": 2.0, "text": accepted_text}],
            },
            {
                "startSeconds": 3.0,
                "endSeconds": 4.0,
                "text": omitted_text,
                "words": [{"startSeconds": 3.0, "endSeconds": 4.0, "text": omitted_text}],
            },
        ]
        with redirect_stderr(io.StringIO()):
            from unittest.mock import patch
            with patch("wilted_worker.transcript_blocks.reporting.progress") as progress:
                capped = enforce_transcript_caps(cues)

        self.assertEqual(capped[0]["words"][0]["text"], accepted_text)
        self.assertNotIn("words", capped[1])
        self.assertEqual(capped[1]["text"], omitted_text)
        progress.assert_called_once_with(
            "transcript.caps.warning",
            "Transcript optional detail exceeded field byte caps; omitting detail to preserve transcript",
        )

    def test_caps_enforcement_word_raw_text_boundaries_preserve_timed_text(self):
        accepted_raw = "x" * 1024
        omitted_raw = "x" * 1025
        cues = [
            {
                "startSeconds": 1.0,
                "endSeconds": 2.0,
                "text": "first",
                "words": [{"startSeconds": 1.0, "endSeconds": 2.0, "text": "first", "rawText": accepted_raw}],
            },
            {
                "startSeconds": 3.0,
                "endSeconds": 4.0,
                "text": "second",
                "words": [{"startSeconds": 3.0, "endSeconds": 4.0, "text": "second", "rawText": omitted_raw}],
            },
        ]
        with redirect_stderr(io.StringIO()):
            from unittest.mock import patch
            with patch("wilted_worker.transcript_blocks.reporting.progress") as progress:
                capped = enforce_transcript_caps(cues)

        self.assertEqual(capped[0]["words"][0]["rawText"], accepted_raw)
        self.assertNotIn("rawText", capped[1]["words"][0])
        self.assertEqual(capped[1]["words"][0]["text"], "second")
        progress.assert_called_once_with(
            "transcript.caps.warning",
            "Transcript optional detail exceeded field byte caps; omitting detail to preserve transcript",
        )

    def test_caps_enforcement_rejects_speaker_over_swift_byte_cap(self):
        accepted_speaker = "x" * 128
        with redirect_stderr(io.StringIO()):
            accepted = enforce_transcript_caps([
                {"startSeconds": 1.0, "endSeconds": 2.0, "text": "first", "speaker": accepted_speaker},
            ])
            with self.assertRaisesRegex(ValueError, "speaker"):
                enforce_transcript_caps([
                    {"startSeconds": 3.0, "endSeconds": 4.0, "text": "second", "speaker": "x" * 129},
                ])

        self.assertEqual(accepted[0]["speaker"], accepted_speaker)

    def test_grouping_enforces_unicode_byte_caps_before_aggregate_fallback(self):
        accepted_raw = "é" * 4096
        omitted_raw = "é" * 4097
        with redirect_stderr(io.StringIO()):
            from unittest.mock import patch
            with patch("wilted_worker.transcript_blocks.reporting.progress") as progress:
                tokenless = group_tokenless_cues([
                    {"startSeconds": 0.0, "endSeconds": 1.0, "text": "accepted", "speaker": "A", "rawText": accepted_raw},
                    {"startSeconds": 3.0, "endSeconds": 4.0, "text": "omitted", "speaker": "B", "rawText": omitted_raw},
                ])
                timed = group_words_into_blocks([
                    TranscriptWord(start_s=0.0, end_s=1.0, text="é" * 513),
                ], min_words=1)

        self.assertEqual(tokenless[0]["rawText"], accepted_raw)
        self.assertNotIn("rawText", tokenless[1])
        self.assertEqual(tokenless[1]["text"], "omitted")
        self.assertNotIn("words", timed[0])
        self.assertEqual(timed[0]["text"], "é" * 513)
        self.assertEqual(progress.call_count, 2)
        for call in progress.call_args_list:
            self.assertEqual(call.args[0], "transcript.caps.warning")
            self.assertIn("field byte caps", call.args[1])

    def test_caps_enforcement_base_content_exceeding_1mb_raises(self):
        from wilted_worker.transcript_blocks import TranscriptSizeError
        # 200 cues each with 6000 bytes text = 1.2MB base content
        huge_cues = [
            {"startSeconds": float(i), "endSeconds": float(i + 1), "text": "x" * 6000}
            for i in range(200)
        ]
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(TranscriptSizeError):
                enforce_transcript_caps(huge_cues)

    def test_caps_enforcement_over_20k_alternating_speakers_raises(self):
        from wilted_worker.transcript_blocks import TranscriptSizeError
        # 21,000 cues with alternating speakers: cannot be merged
        cues = [
            {"startSeconds": float(i), "endSeconds": float(i + 1), "text": "hi", "speaker": f"Spk{i % 2}"}
            for i in range(20005)
        ]
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(TranscriptSizeError):
                enforce_transcript_caps(cues)

    def test_caps_enforcement_long_same_speaker_over_limit_raises(self):
        from wilted_worker.transcript_blocks import TranscriptSizeError
        # Cues that cannot be merged without exceeding 8192 bytes per cue
        cues = [
            {"startSeconds": float(i), "endSeconds": float(i + 1), "text": "x" * 8000, "speaker": "Host"}
            for i in range(20005)
        ]
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(TranscriptSizeError):
                enforce_transcript_caps(cues)

    def test_caps_enforcement_malformed_non_json_raises(self):
        from wilted_worker.transcript_blocks import TranscriptSizeError
        cues = [{"startSeconds": 0.0, "endSeconds": 1.0, "text": "hello", "bad": object()}]
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(TranscriptSizeError):
                enforce_transcript_caps(cues)


if __name__ == "__main__":
    unittest.main()
