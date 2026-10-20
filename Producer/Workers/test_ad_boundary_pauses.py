"""Tests for ad detector boundary fixes: pauses, brand openers, explicit anchors, self-promo trimming."""
from __future__ import annotations

import json
import re
import unittest

from worker_test_support import *  # noqa: F403
from worker_test_support import load_runtime_ads


class ScriptedBackend:
    """Backend answering classifications by prompt and inspecting response_format."""

    def __init__(
        self,
        label_map: dict[int, str] | None = None,
        *,
        include_map: dict[int, bool] | None = None,
        default_include: bool = False,
        content_start_id: int | None = None,
        start_id: int | None = None,
        ads_module=None,
    ):
        self.label_map = label_map or {}
        self.include_map = include_map or {}
        self.default_include = default_include
        self.content_start_id = content_start_id
        self.start_id = start_id
        self.ads = ads_module
        self.calls: list[tuple[str, str, dict | None]] = []

    def generate(self, system_prompt: str, content: str, *, response_format=None):
        self.calls.append((system_prompt, content, response_format))
        if self.ads and system_prompt in (self.ads._AD_DETECT_SYSTEM_PROMPT, self.ads._AD_DETECT_CORRECTION_PROMPT):
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
                candidate_m = re.search(r"CANDIDATE_ID=(\d+)", content)
                candidate_id = int(candidate_m.group(1)) if candidate_m else None
                ans = self.include_map.get(candidate_id, self.default_include) if candidate_id is not None else self.default_include
                return json.dumps({"include": ans}), 1
            if "content_start_id" in properties:
                if self.content_start_id is not None:
                    return json.dumps({"content_start_id": self.content_start_id}), 1
                permitted = properties["content_start_id"].get("enum", [])
                return json.dumps({"content_start_id": permitted[0] if permitted else 0}), 1
            if "start_id" in properties:
                if self.start_id is not None:
                    return json.dumps({"start_id": self.start_id}), 1
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


class AdBoundaryPausesTests(unittest.TestCase):
    """Tests for detector boundary fixes C, B, A, and D."""

    @classmethod
    def setUpClass(cls):
        cls.ads, cls.Segment = load_runtime_ads()

    # -------------------------------------------------------------------------
    # Rule C tests
    # -------------------------------------------------------------------------

    def test_c_left_extension_stopped_at_programme_pause(self):
        """Run of 5 cues after 4.5 s pause; probe include=True for cue before it -> start stays."""
        segs = [
            self.Segment(0.0, 10.0, "The hosts discuss compiler design and performance."),
            self.Segment(14.5, 20.0, "Kestrel makes reliable automated coding infrastructure."),
            self.Segment(20.0, 25.0, "Deploy harnesses and inspect logs easily."),
            self.Segment(25.0, 30.0, "Engineering teams use Kestrel to stay fast."),
            self.Segment(30.0, 35.0, "Try it now with your organization."),
            self.Segment(35.0, 40.0, "Visit kestrel dot com slash speed."),
            self.Segment(40.0, 50.0, "Now returning to our regular discussion on data flow."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=1, end_id=5, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={0: True}, ads_module=self.ads)

        with self.assertLogs("wilted.ads", level="INFO") as cm:
            result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 14.5)
        self.assertEqual(result.end_s, 40.0)
        self.assertTrue(
            any(
                "Left extension of run 1-5 stopped at a 4.5 s pause before ID 1" in msg
                for msg in cm.output
            )
        )

    def test_c_control_short_gap_extends_across_boundary(self):
        """Control: same probe include=True with 0.3 s gap -> extends across boundary."""
        segs = [
            self.Segment(0.0, 14.2, "The hosts discuss compiler design and performance."),
            self.Segment(14.5, 20.0, "Kestrel makes reliable automated coding infrastructure."),
            self.Segment(20.0, 25.0, "Deploy harnesses and inspect logs easily."),
            self.Segment(25.0, 30.0, "Engineering teams use Kestrel to stay fast."),
            self.Segment(30.0, 35.0, "Try it now with your organization."),
            self.Segment(35.0, 40.0, "Visit kestrel dot com slash speed."),
            self.Segment(40.0, 50.0, "Now returning to our regular discussion on data flow."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=1, end_id=5, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={0: True}, ads_module=self.ads)

        result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 0.0)
        self.assertEqual(result.end_s, 40.0)

    def test_c_verify_pod_start_clamped_at_pause(self):
        """C via _verify_pod_start returning an ID across a pause -> clamped."""
        segs = [
            self.Segment(0.0, 10.0, "The hosts discuss software architectures."),
            self.Segment(14.5, 20.0, "visit kestrel dot com today for a free trial"),
            self.Segment(20.0, 25.0, "terms and conditions apply"),
            self.Segment(25.0, 35.0, "and now back to the topic"),
            self.Segment(35.0, 45.0, "further program discussion continues"),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=1, end_id=2, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(start_id=0, content_start_id=3, ads_module=self.ads)

        with self.assertLogs("wilted.ads", level="INFO") as cm:
            result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 14.5)
        self.assertTrue(
            any(
                "Left extension of run 1-2 stopped at a 4.5 s pause before ID 1" in msg
                for msg in cm.output
            )
        )

    # -------------------------------------------------------------------------
    # Rule B tests
    # -------------------------------------------------------------------------

    def test_b_positive_brand_opener_joined_after_pause(self):
        """Opener cue contiguous with run, 4.7 s pause before it, names Kestrel -> moves to opener."""
        segs = [
            self.Segment(0.0, 10.0, "Host discussion about compilers and runtimes."),
            self.Segment(14.7, 20.0, "A new study from Kestrel and a university found promising results."),
            self.Segment(20.2, 25.0, "Check out the full report at kestrel dot com slash ai."),
            self.Segment(25.0, 30.0, "Improve developer workflows with automated evaluation."),
            self.Segment(30.0, 40.0, "We resume the technical interview."),
            self.Segment(40.0, 50.0, "Continuing the show conversation."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=2, end_id=3, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={1: False}, content_start_id=4, ads_module=self.ads)

        with self.assertLogs("wilted.ads", level="INFO") as cm:
            result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 14.7)
        self.assertTrue(
            any(
                "Joined brand opener 1 to ad run 2-3" in msg
                for msg in cm.output
            )
        )

    def test_b_positive_at_start_of_transcript_c_zero(self):
        """Opener cue at c == 0 contiguous with run, names Kestrel -> joined."""
        segs = [
            self.Segment(0.0, 5.0, "A new study from Kestrel showed faster test execution."),
            self.Segment(5.2, 10.0, "Read more at kestrel dot com today."),
            self.Segment(10.0, 15.0, "Get started in minutes with their cloud suite."),
            self.Segment(15.0, 25.0, "Welcome to the podcast everyone."),
            self.Segment(25.0, 35.0, "Today we have an extraordinary guest."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=1, end_id=2, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={0: False}, content_start_id=3, ads_module=self.ads)

        with self.assertLogs("wilted.ads", level="INFO") as cm:
            result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 0.0)
        self.assertTrue(
            any(
                "Joined brand opener 0 to ad run 1-2" in msg
                for msg in cm.output
            )
        )

    def test_b_negative_no_pause_before_opener(self):
        """B negative: no pause before the opener (0.3 s gap)."""
        segs = [
            self.Segment(0.0, 10.0, "Editorial discussion."),
            self.Segment(10.3, 15.0, "A new study from Kestrel showed great progress."),
            self.Segment(15.2, 20.0, "Visit kestrel dot com today for more details."),
            self.Segment(20.0, 25.0, "Sign up and save on your plan."),
            self.Segment(25.0, 35.0, "Continuing the show."),
            self.Segment(35.0, 45.0, "More discussion follows."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=2, end_id=3, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={1: False}, content_start_id=4, ads_module=self.ads)

        result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 15.2)

    def test_b_negative_opener_not_contiguous(self):
        """B negative: opener not contiguous with run (0.8 s gap >= 0.5 s)."""
        segs = [
            self.Segment(0.0, 10.0, "Editorial discussion."),
            self.Segment(14.7, 20.0, "A new study from Kestrel showed great progress."),
            self.Segment(20.8, 25.0, "Visit kestrel dot com today for more details."),
            self.Segment(25.0, 30.0, "Sign up and save on your plan."),
            self.Segment(30.0, 40.0, "Continuing the show."),
            self.Segment(40.0, 50.0, "More discussion follows."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=2, end_id=3, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={1: False}, content_start_id=4, ads_module=self.ads)

        result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 20.8)

    def test_b_negative_brand_mentioned_no_web_address_in_first_two_cues(self):
        """B negative: brand mentioned in opener but no web address in run's first two cues."""
        segs = [
            self.Segment(0.0, 10.0, "Editorial discussion."),
            self.Segment(14.7, 20.0, "A new study from Kestrel showed great progress."),
            self.Segment(20.2, 25.0, "Kestrel delivers powerful tools for modern teams."),
            self.Segment(25.0, 30.0, "Their customer service is always available."),
            self.Segment(30.0, 40.0, "Continuing the show."),
            self.Segment(40.0, 50.0, "More discussion follows."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=2, end_id=3, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={1: False}, content_start_id=4, ads_module=self.ads)

        result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 20.2)

    def test_b_negative_opener_is_credit(self):
        """B negative: opener is a credit ('thanks to our partner Kestrel...')."""
        segs = [
            self.Segment(0.0, 10.0, "Editorial discussion."),
            self.Segment(14.7, 20.0, "Thanks to our partner Kestrel for supporting the show."),
            self.Segment(20.2, 25.0, "Visit kestrel dot com today for more details."),
            self.Segment(25.0, 30.0, "Sign up and save on your plan."),
            self.Segment(30.0, 40.0, "Continuing the show."),
            self.Segment(40.0, 50.0, "More discussion follows."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=2, end_id=3, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={1: False}, content_start_id=4, ads_module=self.ads)

        result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 20.2)

    def test_b_negative_brand_only_in_run_third_cue(self):
        """B negative: the brand web address appears only in the run's third cue."""
        segs = [
            self.Segment(0.0, 10.0, "Editorial discussion."),
            self.Segment(14.7, 20.0, "A new study from Kestrel showed great progress."),
            self.Segment(20.2, 25.0, "We have an exciting announcement about cloud tech."),
            self.Segment(25.0, 30.0, "Our infrastructure is getting faster every month."),
            self.Segment(30.0, 35.0, "Visit kestrel dot com to read the full benchmark."),
            self.Segment(35.0, 45.0, "Continuing the show."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=2, end_id=4, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={1: False}, ads_module=self.ads)

        result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)

        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 20.2)

    def test_b_never_extends_by_more_than_one_cue(self):
        """B never extends by more than one cue even if previous cue also mentions the brand."""
        segs = [
            self.Segment(0.0, 10.0, "Editorial discussion."),
            self.Segment(14.7, 17.0, "Earlier Kestrel research was published."),
            self.Segment(17.1, 20.0, "A new study from Kestrel showed great progress."),
            self.Segment(20.2, 25.0, "Visit kestrel dot com today for more details."),
            self.Segment(25.0, 30.0, "Sign up and save on your plan."),
            self.Segment(30.0, 40.0, "Continuing the show."),
            self.Segment(40.0, 50.0, "More discussion follows."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=3, end_id=4, confidence=0.9, label="sponsor_read")
        backend = ScriptedBackend(include_map={2: False, 1: False}, content_start_id=5, ads_module=self.ads)

        result = self.ads._verify_ad_boundaries(coarse_run, segs, backend)
        self.assertIsNotNone(result)
        self.assertEqual(result.start_s, 20.2)

    # -------------------------------------------------------------------------
    # Rule A tests
    # -------------------------------------------------------------------------

    def test_a_prefix_spot_before_sponsor_anchor_recovered_and_merged(self):
        """Run of 8 cues (cues 0-2 harborline com spot, cue 3 explicit host read) -> prefix + anchor merged."""
        segs = [
            self.Segment(0.0, 10.0, "This portion is supported by harborline com for cloud security."),
            self.Segment(10.0, 20.0, "Harborline monitors real-time telemetry across clusters."),
            self.Segment(20.0, 30.0, "Check out harborline com to secure your systems."),
            self.Segment(30.0, 40.0, "Today's sponsor is Acme Corporation."),
            self.Segment(40.0, 50.0, "Acme provides reliable backup power solutions."),
            self.Segment(50.0, 60.0, "Their batteries keep critical servers running."),
            self.Segment(60.0, 70.0, "Visit acme dot com today for a free quote."),
            self.Segment(70.0, 80.0, "Terms and conditions apply."),
            self.Segment(80.0, 90.0, "And now back to the discussion on cloud infrastructure."),
            self.Segment(90.0, 100.0, "We continue where we left off."),
        ]
        label_map = {i: "sponsor_read" for i in range(8)}
        backend = ScriptedBackend(label_map=label_map, content_start_id=8, ads_module=self.ads)

        with self.assertLogs("wilted.ads", level="INFO") as cm:
            detections = self.ads.detect_ads(segs, backend)

        self.assertEqual(len(detections), 1)
        self.assertEqual(detections[0].start_s, 0.0)
        self.assertEqual(detections[0].end_s, 80.0)
        self.assertTrue(
            any(
                "Verifying run 0-2 before sponsor anchor at 3" in msg
                for msg in cm.output
            )
        )

    def test_a_short_prefix_without_promo_evidence_discarded_flag_off(self):
        """Prefix of 1-2 cues without promotional evidence is discarded (flag off)."""
        segs = [
            self.Segment(0.0, 10.0, "We had a lot of thoughts on that paper."),
            self.Segment(10.0, 20.0, "Some general discussion continuing."),
            self.Segment(20.0, 30.0, "Today's sponsor is Acme Corporation."),
            self.Segment(30.0, 40.0, "Visit acme dot com today."),
            self.Segment(40.0, 50.0, "Terms apply."),
            self.Segment(50.0, 60.0, "Back to the interview."),
        ]
        label_map = {0: "sponsor_read", 1: "sponsor_read", 2: "sponsor_read", 3: "sponsor_read", 4: "sponsor_read"}
        backend = ScriptedBackend(label_map=label_map, content_start_id=5, ads_module=self.ads)

        detections = self.ads.detect_ads(segs, backend, remove_self_promotion=False)

        # Prefix cues 0-1 lack promotional cues -> discarded; only anchor pod 2-4 survives
        self.assertEqual(len(detections), 1)
        self.assertEqual(detections[0].start_s, 20.0)
        self.assertEqual(detections[0].end_s, 50.0)

    def test_a_run_starting_after_anchor_claimed_whole(self):
        """A run starting after the anchor is claimed whole with no extra boundary verification."""
        segs = [
            self.Segment(0.0, 10.0, "Introductory remarks."),
            self.Segment(10.0, 20.0, "Today's sponsor is Acme Corporation."),
            self.Segment(20.0, 30.0, "Acme builds robust hardware."),
            self.Segment(30.0, 40.0, "Visit acme dot com."),
            self.Segment(40.0, 50.0, "Now returning to our guest."),
        ]
        label_map = {2: "sponsor_read", 3: "sponsor_read"}
        backend = ScriptedBackend(label_map=label_map, content_start_id=4, ads_module=self.ads)

        detections = self.ads.detect_ads(segs, backend)

        self.assertEqual(len(detections), 1)
        self.assertEqual(detections[0].start_s, 10.0)
        self.assertEqual(detections[0].end_s, 40.0)

    # -------------------------------------------------------------------------
    # Rule D tests
    # -------------------------------------------------------------------------

    def test_d_flag_on_preserves_sponsor_pod_edge_cues(self):
        """Flag on: a 4-cue pod labelled self_promo whose edge cues have no house/sparse/CTA cue keeps every cue."""
        segs = [
            self.Segment(0.0, 10.0, "The hosts discuss operating systems."),
            self.Segment(10.0, 20.0, "A new study from Kestrel found that automated tests save time."),
            self.Segment(20.0, 30.0, "Their platform automates edge case generation."),
            self.Segment(30.0, 40.0, "Teams using Kestrel ship software faster."),
            self.Segment(40.0, 50.0, "See for yourself at kestrel dot com."),
            self.Segment(50.0, 60.0, "And now back to the discussion."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=1, end_id=4, confidence=0.9, label="self_promo")

        trimmed = self.ads._trim_self_promo_run_edges(coarse_run, segs)

        self.assertIsNotNone(trimmed)
        self.assertEqual(trimmed.start_id, 1)
        self.assertEqual(trimmed.end_id, 4)

    def test_d_flag_on_trims_show_identity_tagline(self):
        """Flag on: an edge tagline is trimmed when it matches _SHOW_IDENTITY_RE without house cues."""
        segs = [
            self.Segment(0.0, 10.0, "The hosts discuss operating systems."),
            self.Segment(10.0, 20.0, "The Daily Brief is a daily podcast about technology and ai."),
            self.Segment(20.0, 30.0, "Join our Patreon at patreon dot com slash show."),
            self.Segment(30.0, 40.0, "Get ad free episodes and bonus discussions."),
            self.Segment(40.0, 50.0, "Subscribe today."),
            self.Segment(50.0, 60.0, "And now back to the discussion."),
        ]
        coarse_run = self.ads._CoarseAdRun(start_id=1, end_id=4, confidence=0.9, label="self_promo")

        trimmed = self.ads._trim_self_promo_run_edges(coarse_run, segs)

        self.assertIsNotNone(trimmed)
        self.assertEqual(trimmed.start_id, 2)
        self.assertEqual(trimmed.end_id, 4)


if __name__ == "__main__":
    unittest.main()
