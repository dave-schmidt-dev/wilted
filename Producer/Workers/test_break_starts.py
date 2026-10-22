"""Podcast worker tests: the reviewed late break-start extension.

A verified cut sometimes starts a cue or more after its break begins: a
host-read lead-in, a postroll's first spot, or a mid-roll introduction. These
tests pin the backward review: which cuts are eligible, which cues form the
lead-in window and where it stops, what the model is shown and allowed to
answer, and what every refusal leaves behind. The fixtures are synthetic and
the model is a recording double.
"""
from __future__ import annotations

import io
import json
import unittest
from contextlib import redirect_stderr
from dataclasses import dataclass

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import break_starts as _worker_break_starts
from wilted_worker import prompts as _worker_prompts
from wilted_worker.ad_outcome import decide_ad_outcome
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, wp


class RecordingBackend:
    """A backend double that records every request and replays canned answers."""

    def __init__(self, responses=()):
        self.responses = list(responses)
        self.calls = []

    def generate(self, system_prompt, user_content, *, response_format=None):
        self.calls.append({
            "prompt": system_prompt,
            "content": user_content,
            "response_format": response_format,
        })
        response = self.responses.pop(0) if self.responses else "[]"
        if isinstance(response, Exception):
            raise response
        return response, 1


@dataclass
class BreakStartLLM(FakeLLM):
    """`FakeLLM` plus an answer for the late break-start review."""

    break_start_id: int | None = None
    break_start_answer: str | None = None

    def generate(self, system_prompt, user_content, *, response_format=None, prepared_prompt=None):
        if system_prompt == _worker_prompts.AD_BREAK_START_PROMPT:
            self.requests.append(response_format)
            self.request_contents.append(user_content)
            self.request_prompts.append(system_prompt)
            if self.break_start_answer is not None:
                return self.break_start_answer, 1
            if self.break_start_id is not None:
                return json.dumps({"ad_start_id": self.break_start_id}), 1
            return self.answer, 1
        return super().generate(
            system_prompt, user_content,
            response_format=response_format, prepared_prompt=prepared_prompt,
        )


class LateBreakStartTests(unittest.TestCase):
    """A cut's start moves back to the pause that actually opens the break."""

    # in105-shaped postroll: the host lead-in sits after a longer pause than
    # the sponsor cues that follow it, and the verified cut starts at the
    # sponsor.
    SEGMENTS = [
        FakeSegment(0.0, 30.0, "programme one"),
        FakeSegment(30.0, 60.0, "programme two"),
        FakeSegment(65.0, 90.0, "host lead-in to the sponsor"),
        FakeSegment(90.0, 110.0, "sponsor read one"),
        FakeSegment(110.0, 130.0, "sponsor read two"),
        FakeSegment(130.0, 150.0, "programme resumes"),
    ]
    DETECTION = FakeAd(
        90.0, 130.0, label="sponsor", confidence=0.9, kinds=("paid advertising",)
    )

    def recover(
        self, responses=(), detections=None, segments=None, total_seconds=300.0,
        held_spans=None, protected_ids=frozenset(), released_heads=(),
    ):
        backend = RecordingBackend(responses)
        ads_module = install_fake_ads(FakeLLM())
        stream = io.StringIO()
        with redirect_stderr(stream):
            recovered = _worker_break_starts.recover_late_break_starts(
                ads_module,
                backend,
                self.SEGMENTS if segments is None else segments,
                [self.DETECTION] if detections is None else list(detections),
                total_seconds,
                [] if held_spans is None else held_spans,
                protected_ids,
                released_heads,
            )
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        return recovered, backend, events

    @staticmethod
    def stages(events):
        return [event["stage"] for event in events]

    def test_a_postroll_starting_one_cue_late_moves_back_to_the_lead_in(self):
        recovered, backend, events = self.recover([json.dumps({"ad_start_id": 2})])
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(65.0, 130.0)])
        self.assertEqual(recovered[0].label, "sponsor")
        self.assertEqual(recovered[0].confidence, 0.9)
        self.assertEqual(recovered[0].kinds, ("paid advertising",))
        self.assertEqual(len(backend.calls), 1)
        self.assertEqual(backend.calls[0]["response_format"]["field"], "ad_start_id")
        self.assertEqual(backend.calls[0]["response_format"]["ids"], [-1, 2])
        self.assertIn("[3] verified commercial: sponsor read one", backend.calls[0]["content"])
        accepted = [event for event in events if event["stage"] == "ads.detect.break-start"]
        self.assertEqual(len(accepted), 1)
        self.assertIn("90.000-130.000", accepted[0]["detail"])
        self.assertIn("65.000", accepted[0]["detail"])
        self.assertIn("cue ID 2", accepted[0]["detail"])

    def test_a_declined_review_keeps_the_verified_cut(self):
        recovered, backend, events = self.recover([json.dumps({"ad_start_id": -1})])
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(90.0, 130.0)])
        self.assertEqual(len(backend.calls), 1)
        self.assertNotIn("ads.detect.break-start", self.stages(events))

    def test_unanswerable_reviews_keep_the_verified_cut(self):
        for answer in (
            "not json",
            json.dumps({"program_start_id": 2}),
            json.dumps({"ad_start_id": 0}),
            json.dumps({"ad_start_id": True}),
        ):
            with self.subTest(answer=answer):
                recovered, backend, events = self.recover([answer])
                self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(90.0, 130.0)])
                self.assertEqual(len(backend.calls), 1)
                self.assertIn("ads.detect.break-start.skipped", self.stages(events))

    def test_a_backend_exception_keeps_the_verified_cut(self):
        recovered, backend, events = self.recover([RuntimeError("backend down")])
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(90.0, 130.0)])
        self.assertEqual(len(backend.calls), 1)
        self.assertIn("ads.detect.break-start.skipped", self.stages(events))

    def test_no_candidates_means_no_model_call(self):
        with self.subTest("the cut starts at the episode's first cue"):
            _recovered, backend, _events = self.recover(detections=[FakeAd(0.0, 130.0)])
            self.assertEqual(len(backend.calls), 0)
        with self.subTest("no pause is long enough before the cut"):
            segments = [
                FakeSegment(0.0, 30.0, "programme"),
                FakeSegment(30.0, 60.0, "programme"),
                FakeSegment(61.0, 90.0, "sponsor one"),
                FakeSegment(90.0, 120.0, "sponsor two"),
            ]
            _recovered, backend, _events = self.recover(
                detections=[FakeAd(61.0, 120.0)], segments=segments
            )
            self.assertEqual(len(backend.calls), 0)

    def test_the_window_reaches_back_at_most_sixteen_cues(self):
        # Short cues with 4.0 s pauses, so the 90 s bound alone would admit
        # every cue back to cue 1; the 16-cue cap is what excludes it.
        segments = [
            FakeSegment(index * 5.0, index * 5.0 + 1.0, f"cue {index}")
            for index in range(17)
        ]
        segments.extend([
            FakeSegment(85.0, 90.0, "cue 17"),
            FakeSegment(90.0, 91.0, "cue 18"),
            FakeSegment(95.0, 96.0, "cue 19"),
        ])
        recovered, backend, _events = self.recover(
            [json.dumps({"ad_start_id": 1})],
            detections=[FakeAd(90.0, 100.0)],
            segments=segments,
        )
        # Cue 1 would be a candidate too, but it is the seventeenth cue back
        # and never reaches the model.
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(90.0, 100.0)])
        self.assertEqual(backend.calls[0]["response_format"]["ids"], [-1, *range(2, 18)])

    def test_the_window_reaches_back_at_most_ninety_seconds(self):
        at_limit = [
            FakeSegment(0.0, 4.0, "programme"),
            FakeSegment(10.0, 100.0, "long lead-in"),
            FakeSegment(100.0, 120.0, "sponsor one"),
        ]
        recovered, backend, _events = self.recover(
            [json.dumps({"ad_start_id": 1})],
            detections=[FakeAd(100.0, 120.0)],
            segments=at_limit,
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(10.0, 120.0)])
        self.assertEqual(len(backend.calls), 1)

        over_limit = [
            FakeSegment(0.0, 4.0, "programme"),
            FakeSegment(9.0, 100.0, "long lead-in"),
            FakeSegment(100.0, 120.0, "sponsor one"),
        ]
        recovered, backend, _events = self.recover(
            [json.dumps({"ad_start_id": 1})],
            detections=[FakeAd(100.0, 120.0)],
            segments=over_limit,
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(100.0, 120.0)])
        self.assertEqual(len(backend.calls), 0)

    def test_the_window_stops_at_another_cut_an_anchor_or_a_programme_boundary(self):
        segments = [
            FakeSegment(0.0, 20.0, "programme one"),
            FakeSegment(25.0, 50.0, "other cut cue"),
            FakeSegment(55.0, 70.0, "lead-in"),
            FakeSegment(70.0, 90.0, "sponsor one"),
            FakeSegment(90.0, 110.0, "sponsor two"),
        ]
        detection = FakeAd(70.0, 110.0)
        with self.subTest("another detection"):
            _recovered, backend, _events = self.recover(
                detections=[detection, FakeAd(25.0, 50.0)], segments=segments
            )
            self.assertEqual(backend.calls[0]["response_format"]["ids"], [-1, 2])
        with self.subTest("an explicit sponsor anchor"):
            _recovered, backend, _events = self.recover(
                detections=[detection], segments=segments, protected_ids=frozenset({2})
            )
            self.assertEqual(len(backend.calls), 0)
        with self.subTest("a programme-boundary held span"):
            _recovered, backend, _events = self.recover(
                detections=[detection],
                segments=segments,
                held_spans=[_worker_ad_audit.HeldAdSpan(25.0, 50.0, "programme-boundary")],
            )
            self.assertEqual(backend.calls[0]["response_format"]["ids"], [-1, 2])

    def test_a_released_head_stops_the_window_even_after_the_start_moves(self):
        # The edge trim released 60-75 and a later resize moved the start on
        # to 90: the interval, not the start, keeps the sign-off out of reach.
        recovered, backend, _events = self.recover(
            [json.dumps({"ad_start_id": 2})],
            released_heads=((60.0, 75.0),),
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(90.0, 130.0)])
        self.assertEqual(len(backend.calls), 0)

    def test_single_share_overflow_drops_only_the_extension_and_records_no_hold(self):
        segments = [
            FakeSegment(0.0, 20.0, "programme"),
            FakeSegment(29.0, 55.0, "lead-in"),
            FakeSegment(60.0, 75.0, "sponsor one"),
            FakeSegment(75.0, 80.0, "sponsor two"),
        ]
        held_spans = []
        recovered, _backend, events = self.recover(
            [json.dumps({"ad_start_id": 1})],
            detections=[FakeAd(60.0, 80.0)],
            segments=segments,
            total_seconds=100.0,
            held_spans=held_spans,
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(60.0, 80.0)])
        self.assertEqual(held_spans, [])
        skipped = [event for event in events if event["stage"] == "ads.detect.break-start.skipped"]
        self.assertEqual(len(skipped), 1)
        self.assertIn("51%", skipped[0]["detail"])

    def test_total_share_overflow_drops_only_the_extension_and_records_no_hold(self):
        segments = [
            FakeSegment(0.0, 25.0, "first cut cue"),
            FakeSegment(35.0, 50.0, "lead-in"),
            FakeSegment(55.0, 75.0, "sponsor one"),
        ]
        held_spans = []
        recovered, _backend, events = self.recover(
            [json.dumps({"ad_start_id": 1})],
            detections=[FakeAd(0.0, 25.0), FakeAd(55.0, 75.0)],
            segments=segments,
            total_seconds=100.0,
            held_spans=held_spans,
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in recovered], [(0.0, 25.0), (55.0, 75.0)]
        )
        self.assertEqual(held_spans, [])
        skipped = [event for event in events if event["stage"] == "ads.detect.break-start.skipped"]
        self.assertEqual(len(skipped), 1)
        self.assertIn("65%", skipped[0]["detail"])

    def test_a_cut_that_fully_contains_no_cue_is_never_reviewed(self):
        # The cut lives inside cue 1, so it is a fragment and cannot say where
        # the break begins.
        segments = [
            FakeSegment(0.0, 20.0, "programme"),
            FakeSegment(25.0, 60.0, "sponsor read"),
            FakeSegment(65.0, 90.0, "programme after"),
        ]
        recovered, backend, _events = self.recover(
            [json.dumps({"ad_start_id": 0})],
            detections=[FakeAd(30.0, 50.0)],
            segments=segments,
        )
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(30.0, 50.0)])
        self.assertEqual(len(backend.calls), 0)

    def test_a_partially_overlapped_first_cue_is_shown_unmarked(self):
        segments = [
            FakeSegment(0.0, 10.0, "programme"),
            FakeSegment(15.0, 30.0, "host lead-in"),
            FakeSegment(33.0, 50.0, "partially overlapped sponsor cue"),
            FakeSegment(50.0, 60.0, "fully contained sponsor cue"),
            FakeSegment(65.0, 80.0, "programme after"),
        ]
        recovered, backend, _events = self.recover(
            [json.dumps({"ad_start_id": -1})],
            detections=[FakeAd(40.0, 60.0)],
            segments=segments,
        )
        self.assertEqual(len(backend.calls), 1)
        content = backend.calls[0]["content"]
        self.assertIn("[2] partially overlapped sponsor cue", content)
        self.assertNotIn("[2] verified commercial", content)
        self.assertIn("[3] verified commercial: fully contained sponsor cue", content)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in recovered], [(40.0, 60.0)])


class LateBreakStartEndToEndTests(unittest.TestCase):
    """The extension through `analyze_ad_detections`, with the whole recovery path."""

    SEGMENTS = [
        FakeSegment(0.0, 20.0, "programme one"),
        FakeSegment(20.0, 40.0, "programme two"),
        FakeSegment(45.0, 60.0, "host lead-in to the sponsor"),
        FakeSegment(60.0, 80.0, "sponsor read one"),
        FakeSegment(80.0, 100.0, "sponsor read two"),
        FakeSegment(100.0, 120.0, "programme resumes"),
        FakeSegment(160.0, 180.0, "programme later"),
    ]
    DETECTIONS = [
        FakeAd(60.0, 100.0, label="sponsor_read"),
        FakeAd(160.0, 180.0, label="ad_break"),
    ]

    def analyze(self, llm):
        llm.load()
        ads = install_fake_ads(llm, detections=list(self.DETECTIONS))
        stream = io.StringIO()
        with redirect_stderr(stream):
            analysis = wp.analyze_ad_detections(ads, llm, self.SEGMENTS, 300.0)
        events = [json.loads(line) for line in stream.getvalue().splitlines()]
        return analysis, events

    def test_an_accepted_extension_moves_only_the_late_cut(self):
        analysis, events = self.analyze(
            BreakStartLLM(preroll_program_start_id=0, break_start_id=2)
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in analysis.detections],
            [(45.0, 100.0), (160.0, 180.0)],
        )
        self.assertIn("ads.detect.break-start", [event["stage"] for event in events])

    def test_an_invalid_response_leaves_every_cut_and_the_outcome_unchanged(self):
        declined, _events = self.analyze(
            BreakStartLLM(preroll_program_start_id=0, break_start_id=-1)
        )
        invalid, events = self.analyze(
            BreakStartLLM(preroll_program_start_id=0, break_start_answer="not json")
        )
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in declined.detections],
            [(ad.start_s, ad.end_s) for ad in invalid.detections],
        )
        self.assertEqual(
            decide_ad_outcome(declined.audit, declined.detections),
            decide_ad_outcome(invalid.audit, invalid.detections),
        )
        self.assertIn("ads.detect.break-start.skipped", [event["stage"] for event in events])

    def test_a_head_trimmed_start_is_never_reviewed_end_to_end(self):
        # The edge trim hands cue 2's sign-off back to the programme because
        # the pause after it is longer than the one before it. Without the
        # released interval, the late-start review would be offered cue 1 as a
        # candidate and could cut the sign-off again.
        segments = [
            FakeSegment(0.0, 10.0, "programme"),
            FakeSegment(20.0, 40.0, "programme"),
            FakeSegment(45.0, 60.0, "those are the headlines and a full month of free access"),
            FakeSegment(67.0, 90.0, "sponsor read one"),
            FakeSegment(90.0, 110.0, "sponsor read two"),
            FakeSegment(115.0, 130.0, "programme resumes"),
        ]
        llm = BreakStartLLM(preroll_program_start_id=0, break_start_id=1)
        llm.load()
        ads = install_fake_ads(llm, detections=[FakeAd(45.0, 110.0, label="ad_break")])
        with redirect_stderr(io.StringIO()):
            analysis = wp.analyze_ad_detections(ads, llm, segments, 300.0)
        self.assertEqual(
            [(ad.start_s, ad.end_s) for ad in analysis.detections], [(60.0, 110.0)]
        )
        self.assertNotIn(_worker_prompts.AD_BREAK_START_PROMPT, llm.request_prompts)
