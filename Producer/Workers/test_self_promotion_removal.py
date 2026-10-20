"""Tests for per-request remove-self-promotion flag in ad detector and worker."""
from __future__ import annotations

import contextlib
import json
import re
import unittest
from pathlib import Path
from unittest import mock

from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import prompts as _worker_prompts
from wilted_worker import reporting as _worker_reporting
from worker_test_support import *  # noqa: F403
from worker_test_support import load_runtime_ads, wp


class ScriptedBackend:
    """Backend answering classifications by prompt and inspecting response_format."""

    def __init__(self, label_map: dict[int, str], ads_module):
        self.label_map = label_map
        self.ads = ads_module
        self.calls: list[tuple[str, str, dict | None]] = []

    def generate(self, system_prompt: str, content: str, *, response_format=None):
        self.calls.append((system_prompt, content, response_format))
        if system_prompt in (
            self.ads._AD_DETECT_SYSTEM_PROMPT,
            self.ads._AD_DETECT_CORRECTION_PROMPT,
            # A flag-on analysis forwards the variants in their place.
            _worker_prompts.SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT,
            _worker_prompts.SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT,
        ):
            found_ids = [int(m) for m in re.findall(r"\[ID (\d+)\]", content)]
            ads_list = [
                [seg_id, self.label_map[seg_id]]
                for seg_id in found_ids
                if seg_id in self.label_map and self.label_map[seg_id]
            ]
            return json.dumps({"ads": ads_list}), 1

        if response_format is not None:
            schema = response_format.get("schema", {})
            properties = schema.get("properties", {})
            if "include" in properties:
                return json.dumps({"include": False}), 1
            if "starts_program" in properties or "starts_program" in system_prompt:
                return json.dumps({"starts_program": False}), 1
            if "carries_program" in properties or "carries_program" in system_prompt:
                return json.dumps({"carries_program": False}), 1
            if "content_start_id" in properties:
                permitted = properties["content_start_id"].get("enum", [])
                return json.dumps({"content_start_id": permitted[0] if permitted else 0}), 1
            if "start_id" in properties:
                permitted = properties["start_id"].get("enum", [])
                return json.dumps({"start_id": permitted[-1] if permitted else 0}), 1
            if "program_start_id" in properties:
                permitted = properties["program_start_id"].get("enum", [])
                ans = 0 if 0 in permitted else (-1 if -1 in permitted else (permitted[0] if permitted else -1))
                return json.dumps({"program_start_id": ans}), 1
            if "advertising_start_id" in properties:
                permitted = properties["advertising_start_id"].get("enum", [])
                ans = -1 if -1 in permitted else (permitted[-1] if permitted else -1)
                return json.dumps({"advertising_start_id": ans}), 1
            if "labels" in properties:
                labels_dict = {str(k): "programme" for k in properties["labels"].get("properties", {})}
                return json.dumps({"labels": labels_dict}), 1
            if "classification" in properties:
                return json.dumps({"classification": "programme"}), 1
            if "ad_ids" in properties:
                return json.dumps({"ad_ids": []}), 1

        return json.dumps({}), 1


class SelfPromotionRemovalTests(unittest.TestCase):
    """Tests for feed-level remove-self-promotion flag."""

    @classmethod
    def setUpClass(cls):
        cls.ads, cls.Segment = load_runtime_ads()

    def make_fixture(self):
        """Construct the AIDB 2026-09-25 opening fixture."""
        cues = [
            self.Segment(
                0.0, 20.0,
                "Today we consider how autonomous software agents collaborate on complex engineering tasks.",
            ),
            self.Segment(
                20.0, 32.0,
                "the daily brief is a daily podcast and video about the most important news and discussions in ai",
            ),
            self.Segment(
                32.0, 44.0,
                "today we look at how teams build agents together",
            ),
            self.Segment(
                50.0, 70.0,
                "all right friends quick announcements before we dive in thank you to today's sponsors kpmg "
                "blitzy harbor and hyper agent to get an ad free version of the show go to patreon dot com "
                "slash the show or subscribe on apple podcasts",
            ),
            self.Segment(
                70.0, 90.0,
                "this thursday we have a free live webinar on building your own benchmark register and you get "
                "all the materials",
            ),
            self.Segment(
                90.0, 110.0,
                "the next cohort of our executive agent training program starts october fifth",
            ),
        ]
        programme_texts = [
            "welcome back to the show today we dive into multi agent systems and coordination architectures",
            "we explore how communication protocols enable coordination between specialized worker sessions",
            "let us examine the architecture of distributed task planning and execution across workflows",
            "furthermore evaluating agent reliability requires robust automated benchmarks",
            "several new benchmarks test reasoning in realistic sandbox environments",
            "we also consider how memory persistence influences long horizon task execution",
            "different frameworks approach memory management with different latency trade offs",
            "the role of human oversight remains critical across these autonomous systems",
            "safeguards and verification gates prevent cascading errors during unattended operation",
            "thank you for tuning in to this deep dive into modern agentic workflows and design principles",
        ]
        start = 116.0
        for text in programme_texts:
            end = start + 10.0
            cues.append(self.Segment(start, end, text))
            start = end
        label_map = {1: "self_promo", 3: "self_promo", 4: "self_promo", 5: "self_promo"}
        return cues, label_map

    def test_house_promotion_cues_does_not_match_tagline_text(self):
        tagline = (
            "the daily brief is a daily podcast and video about the most important news and discussions in ai"
        )
        self.assertFalse(any(p.search(tagline) for p in self.ads._HOUSE_PROMOTION_CUES))

    def test_detector_flag_on_cuts_roll_call_and_keeps_tagline_and_content(self):
        cues, label_map = self.make_fixture()
        backend = ScriptedBackend(label_map, self.ads)
        detections = self.ads.detect_ads(cues, backend, remove_self_promotion=True)
        self.assertEqual(len(detections), 1)
        ad = detections[0]
        self.assertEqual(ad.start_s, 50.0)
        self.assertEqual(ad.end_s, 110.0)
        self.assertEqual(ad.label, "self_promo")
        # Ensure cue 1 (tagline: 20-32s) and all content cues are not covered
        self.assertGreaterEqual(ad.start_s, 44.0)
        self.assertLessEqual(ad.end_s, 116.0)

    def test_detector_flag_off_returns_nothing_and_backend_matches_omitted(self):
        cues, label_map = self.make_fixture()
        backend_off = ScriptedBackend(label_map, self.ads)
        dets_off = self.ads.detect_ads(cues, backend_off, remove_self_promotion=False)
        self.assertEqual(dets_off, [])

        backend_omitted = ScriptedBackend(label_map, self.ads)
        dets_omitted = self.ads.detect_ads(cues, backend_omitted)
        self.assertEqual(dets_omitted, [])
        self.assertEqual(backend_off.calls, backend_omitted.calls)

    def test_detector_one_cue_roll_call_alone_survives_when_on_and_discarded_when_off(self):
        cues, _ = self.make_fixture()
        label_map = {3: "self_promo"}

        backend_on = ScriptedBackend(label_map, self.ads)
        dets_on = self.ads.detect_ads(cues, backend_on, remove_self_promotion=True)
        self.assertEqual(len(dets_on), 1)
        self.assertEqual(dets_on[0].start_s, 50.0)
        self.assertEqual(dets_on[0].end_s, 70.0)

        backend_off = ScriptedBackend(label_map, self.ads)
        dets_off = self.ads.detect_ads(cues, backend_off, remove_self_promotion=False)
        self.assertEqual(dets_off, [])

    def test_detector_one_cue_tagline_alone_discarded_when_on(self):
        cues, _ = self.make_fixture()
        label_map = {1: "self_promo"}
        backend = ScriptedBackend(label_map, self.ads)
        dets = self.ads.detect_ads(cues, backend, remove_self_promotion=True)
        self.assertEqual(dets, [])

    def test_detector_adjacent_tagline_trimmed_when_on(self):
        cues, _ = self.make_fixture()
        # Remove cue 2 so tagline (cue 1) directly precedes roll call (cue 3)
        adjacent_cues = [cues[0], cues[1], cues[3], cues[4], cues[5], *cues[6:]]
        # In adjacent_cues: index 1 is cue 1, index 2 is cue 3, index 3 is cue 4, index 4 is cue 5
        label_map = {1: "self_promo", 2: "self_promo", 3: "self_promo", 4: "self_promo"}
        backend = ScriptedBackend(label_map, self.ads)
        detections = self.ads.detect_ads(adjacent_cues, backend, remove_self_promotion=True)
        self.assertEqual(len(detections), 1)
        self.assertEqual(detections[0].start_s, 50.0)
        self.assertEqual(detections[0].end_s, 110.0)
        self.assertEqual(detections[0].label, "self_promo")

    def test_worker_analyze_ad_detections_real_detector(self):
        cues, label_map = self.make_fixture()
        total_seconds = cues[-1].end_s

        backend_on = ScriptedBackend(label_map, self.ads)
        analysis_on = _worker_ad_removal.analyze_ad_detections(
            self.ads, backend_on, cues, total_seconds, remove_self_promotion=True
        )
        self.assertEqual(len(analysis_on.detections), 1)
        self.assertEqual(analysis_on.detections[0].start_s, 50.0)
        self.assertEqual(analysis_on.detections[0].end_s, 110.0)

        _, keeps_on = wp.build_effective_cut_map(analysis_on.detections, total_seconds)
        keep_intervals = [(k.start_s, k.end_s) for k in keeps_on]
        self.assertEqual(keep_intervals, [(0.0, 50.0), (110.0, total_seconds)])

        backend_off = ScriptedBackend(label_map, self.ads)
        analysis_off = _worker_ad_removal.analyze_ad_detections(
            self.ads, backend_off, cues, total_seconds, remove_self_promotion=False
        )
        self.assertEqual(len(analysis_off.detections), 0)

    def test_detect_and_cut_flag_parsing(self):
        segments = [self.Segment(0.0, 10.0, "content passage")]
        test_cases = [
            (True, True),
            ("true", False),
            (1, False),
            (None, False),
            ("absent", False),
        ]
        for val, expected_on in test_cases:
            request = {} if val == "absent" else {"removeSelfPromotion": val}
            with mock.patch("wilted_worker.ad_removal.analyze_ad_detections") as mock_analyze, \
                 mock.patch("wilted_worker.reporting.progress") as mock_progress, \
                 mock.patch("wilted_worker.cue_timing.probe_duration", return_value=10.0), \
                 mock.patch("wilted.llm.create_backend") as mock_create_backend:
                mock_create_backend.return_value = mock.MagicMock()
                mock_analyze.return_value = _worker_ad_removal.AdAnalysis(
                    (), mock.MagicMock(declined_commercial_evidence_seeds=(), held_spans=())
                )
                _worker_ad_removal.detect_and_cut(
                    request, Path("in.mp3"), [], segments, model_lock=contextlib.nullcontext()
                )
                kwargs = mock_analyze.call_args.kwargs
                if expected_on:
                    self.assertIs(kwargs.get("remove_self_promotion"), True)
                else:
                    self.assertNotIn("remove_self_promotion", kwargs)

                progress_stages = [call.args[0] for call in mock_progress.call_args_list]
                if expected_on:
                    self.assertIn("ads.detect.self_promotion", progress_stages)
                else:
                    self.assertNotIn("ads.detect.self_promotion", progress_stages)

    def test_analyze_ad_detections_flag_off_calls_detect_ads_with_two_args_and_no_kwargs(self):
        segments = [self.Segment(0.0, 10.0, "content passage")]
        backend = mock.MagicMock()
        with mock.patch.object(self.ads, "detect_ads", return_value=[]) as mock_detect:
            try:
                _worker_ad_removal.analyze_ad_detections(
                    self.ads, backend, segments, 10.0, remove_self_promotion=False
                )
            except Exception:
                pass
            args, kwargs = mock_detect.call_args
            self.assertEqual(len(args), 2)
            self.assertEqual(kwargs, {})


if __name__ == "__main__":
    unittest.main()
