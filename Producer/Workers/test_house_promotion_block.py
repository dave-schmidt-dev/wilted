"""Tests for bounding show opening promotion blocks with remove_self_promotion."""
from __future__ import annotations

import json
import re
import unittest

from worker_test_support import load_runtime_ads


class ScriptedBackend:
    """Backend answering classifications by prompt and inspecting response_format."""

    def __init__(
        self,
        label_map: dict[int, str] | None = None,
        *,
        include_map: dict[int, bool] | None = None,
        default_include: bool = False,
        content_start_id: int | str | None = None,
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
        if self.ads and system_prompt in (
            self.ads._AD_DETECT_SYSTEM_PROMPT,
            self.ads._AD_DETECT_CORRECTION_PROMPT,
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
                candidate_m = re.search(r"CANDIDATE_ID=(\d+)", content)
                candidate_id = int(candidate_m.group(1)) if candidate_m else None
                ans = (
                    self.include_map.get(candidate_id, self.default_include)
                    if candidate_id is not None
                    else self.default_include
                )
                return json.dumps({"include": ans}), 1
            if "content_start_id" in properties:
                permitted = properties["content_start_id"].get("enum", [])
                if self.content_start_id == "window_max":
                    ans = permitted[-1] if permitted else 0
                elif self.content_start_id is not None:
                    ans = self.content_start_id
                else:
                    ans = permitted[0] if permitted else 0
                return json.dumps({"content_start_id": ans}), 1
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


class HousePromotionBlockTests(unittest.TestCase):
    """Tests for show opening house-promotion block bounding and roll-call seeding."""

    @classmethod
    def setUpClass(cls):
        cls.ads, cls.Segment = load_runtime_ads()

    def test_fixture_a_clamp_and_flag_off_parity(self):
        """Fixture A: clamp shortens verifier's late answer to last contiguous plug cue."""
        cues = [
            self.Segment(0.0, 10.0, "Welcome to the Audio Forge workshop on DSP filtering algorithms."),
            self.Segment(10.0, 20.0, "Today we analyze resonance damping across multiple filter poles."),
            # 13.0 s pause before the roll call cue
            self.Segment(
                33.0,
                45.0,
                "Quick announcements before we begin, thank you to today's sponsors WidgetCorp and GizmoWorks, "
                "visit patreon.com for an ad-free version of the show, or subscribe.",
            ),
            # Four contiguous plug cues (gaps 0)
            self.Segment(45.0, 55.0, "We are hosting an interactive webinar on state-variable architectures."),
            self.Segment(55.0, 65.0, "Make sure to register on our website for the circuit schematics."),
            self.Segment(65.0, 75.0, "Applications for our summer hardware cohort are open this week."),
            self.Segment(75.0, 85.0, "Our design cohort offers practical laboratory instruction."),
            # 1.6 s gap to programme cues without house words
            self.Segment(86.6, 95.0, "Now beginning our exploration into operational amplifiers."),
            self.Segment(95.0, 105.0, "Gain bandwidth products limit high-frequency closed-loop performance."),
            self.Segment(105.0, 115.0, "Bipolar input pairs introduce predictable input bias currents."),
            self.Segment(115.0, 125.0, "Slew rate constraints produce non-linear distortion on fast transients."),
            self.Segment(125.0, 135.0, "Feedback phase margins prevent parasitic oscillations under capacitive loads."),
            self.Segment(135.0, 145.0, "Decoupling capacitors suppress supply rail resonance near the stage."),
        ]

        # Flag on: verifier answers 8 cues past the roll call (cue 2 + 8 = cue 10).
        backend_on = ScriptedBackend(label_map={2: "self_promo"}, content_start_id=10, ads_module=self.ads)
        with self.assertLogs("wilted.ads", level="INFO") as cm:
            detections_on = self.ads.detect_ads(cues, backend_on, remove_self_promotion=True)

        self.assertEqual(len(detections_on), 1)
        self.assertEqual(detections_on[0].start_s, 33.0)
        self.assertEqual(detections_on[0].end_s, 85.0)
        self.assertTrue(
            any(
                "House promotion run 2-2 ends at its last house cue 6, not 9" in msg
                for msg in cm.output
            )
        )

        # Same fixture flag off: today's result (unclamped) and identical backend call sequence.
        backend_off = ScriptedBackend(label_map={2: "self_promo"}, content_start_id=10, ads_module=self.ads)
        detections_off = self.ads.detect_ads(cues, backend_off, remove_self_promotion=False)

        self.assertEqual(len(detections_off), 1)
        self.assertEqual(detections_off[0].start_s, 33.0)
        self.assertEqual(detections_off[0].end_s, 115.0)

        # Baseline run without passing house_roll_call to verify identical backend calls
        backend_baseline = ScriptedBackend(label_map={2: "self_promo"}, content_start_id=10, ads_module=self.ads)
        self.ads.detect_ads(cues, backend_baseline, remove_self_promotion=False)
        self.assertEqual(backend_off.calls, backend_baseline.calls)

    def test_fixture_b_unsafe_window_edge_fallback(self):
        """Fixture B: verifier at window edge keeps detection to roll call only."""
        cues = [
            self.Segment(
                0.0,
                15.0,
                "Quick announcements before we begin, thank you to today's sponsors Acme and Beta, "
                "visit patreon.com for an ad-free version of the show, or subscribe.",
            ),
            # Contiguous programme cue mentioning webinar
            self.Segment(
                15.0,
                30.0,
                "In this broadcast we review an academic webinar on distributed actor systems.",
            ),
            self.Segment(30.0, 45.0, "Supervision trees isolate crash domains across worker processes."),
            self.Segment(45.0, 60.0, "Message passing semantics prevent concurrent memory mutation."),
            self.Segment(60.0, 75.0, "Mailbox boundaries define backpressure limits under heavy load."),
            self.Segment(75.0, 90.0, "Heartbeat monitoring restarts partitioned nodes automatically."),
        ]

        # Flag on: verifier answers window max (unsafe window edge)
        backend_on = ScriptedBackend(
            label_map={0: "self_promo"}, content_start_id="window_max", ads_module=self.ads
        )
        with self.assertLogs("wilted.ads", level="INFO") as cm:
            detections_on = self.ads.detect_ads(cues, backend_on, remove_self_promotion=True)

        self.assertEqual(len(detections_on), 1)
        self.assertEqual(detections_on[0].start_s, 0.0)
        self.assertEqual(detections_on[0].end_s, 15.0)
        self.assertTrue(
            any(
                "House promotion run 0-0 kept to its own cues after the content-start verifier failed" in msg
                for msg in cm.output
            )
        )

        # Flag off: run is suppressed as today
        backend_off = ScriptedBackend(
            label_map={0: "self_promo"}, content_start_id="window_max", ads_module=self.ads
        )
        detections_off = self.ads.detect_ads(cues, backend_off, remove_self_promotion=False)
        self.assertEqual(len(detections_off), 0)

    def test_fixture_c_unlabeled_roll_call_seeding(self):
        """Fixture C: unlabeled roll call is seeded and cut when remove_self_promotion is True."""
        cues = [
            self.Segment(0.0, 20.0, "Welcome to the Kernel Internals seminar on memory management."),
            # 6.5 s pause before roll call cue
            self.Segment(
                26.5,
                40.0,
                "Before we begin, thank you to today's sponsors, and join our Patreon for ad-free downloads.",
            ),
            # 1.3 s gap to programme cue
            self.Segment(41.3, 55.0, "Virtual memory paging relies on multi-level translation tables."),
            self.Segment(55.0, 70.0, "Page faults transfer execution into the kernel exception handler."),
            self.Segment(70.0, 85.0, "Translation lookaside buffers cache recent virtual address mappings."),
        ]

        # Flag on: classifier labels nothing, but seed triggers and cuts exactly the roll call
        backend_on = ScriptedBackend(label_map={}, content_start_id=2, ads_module=self.ads)
        with self.assertLogs("wilted.ads", level="INFO") as cm:
            detections_on = self.ads.detect_ads(cues, backend_on, remove_self_promotion=True)

        self.assertEqual(len(detections_on), 1)
        self.assertEqual(detections_on[0].start_s, 26.5)
        self.assertEqual(detections_on[0].end_s, 40.0)
        self.assertTrue(any("Seeding house roll call 1" in msg for msg in cm.output))

        # Flag off: no seeding, no detection
        backend_off = ScriptedBackend(label_map={}, content_start_id=2, ads_module=self.ads)
        detections_off = self.ads.detect_ads(cues, backend_off, remove_self_promotion=False)
        self.assertEqual(len(detections_off), 0)

    def test_unlabeled_roll_call_is_seeded_beside_a_labelled_sponsor_pod(self):
        """A labelled pod elsewhere in the episode must not stop the missed roll call being seeded."""
        cues = [
            self.Segment(0.0, 20.0, "Welcome to the Kernel Internals seminar on memory management."),
            self.Segment(
                26.5,
                40.0,
                "Before we begin, thank you to today's sponsors, and join our Patreon for ad-free downloads.",
            ),
            self.Segment(41.3, 55.0, "Virtual memory paging relies on multi-level translation tables."),
            self.Segment(55.0, 70.0, "Page faults transfer execution into the kernel exception handler."),
            self.Segment(74.0, 90.0, "Kestrel keeps your build cache warm across every branch."),
            self.Segment(90.0, 105.0, "Teams using Kestrel ship twice as often, according to a new survey."),
            self.Segment(105.0, 120.0, "Start free today at kestrel dot com slash kernel."),
            self.Segment(124.0, 140.0, "Back to the scheduler and how it picks the next runnable task."),
            self.Segment(140.0, 155.0, "Run queues are kept per core to avoid lock contention."),
        ]
        label_map = {4: "sponsor_read", 5: "sponsor_read", 6: "sponsor_read"}
        backend = ScriptedBackend(label_map=label_map, content_start_id=2, ads_module=self.ads)
        with self.assertLogs("wilted.ads", level="INFO") as cm:
            detections = self.ads.detect_ads(cues, backend, remove_self_promotion=True)

        self.assertTrue(any("Seeding house roll call 1" in msg for msg in cm.output))
        self.assertTrue(any(ad.start_s == 26.5 and ad.end_s == 40.0 for ad in detections))
        self.assertFalse(any(ad.start_s < 74.0 < ad.end_s and ad.start_s < 41.3 for ad in detections))

    def test_negatives(self):
        """Negatives: weak-only cues not seeded, weak-only runs unclamped/suppressed, no double-seeding."""
        # 1. Cue with two weak house words only ("register for our webinar") is not seeded
        weak_cues = [
            self.Segment(0.0, 10.0, "Welcome to the broadcast."),
            self.Segment(15.0, 25.0, "Be sure to register for our webinar next Tuesday."),
            self.Segment(30.0, 40.0, "Now let us turn to today's architectural case study."),
        ]
        self.assertFalse(self.ads._house_roll_call(weak_cues[1].text))
        backend_weak = ScriptedBackend(label_map={}, ads_module=self.ads)
        detections_weak = self.ads.detect_ads(weak_cues, backend_weak, remove_self_promotion=True)
        self.assertEqual(len(detections_weak), 0)

        # 2. A self_promo run whose cue lacks a strong pattern ("subscribe to the newsletter")
        #    keeps today's verifier handling (unclamped answer, and suppression on failure)
        promo_cues = [
            self.Segment(0.0, 10.0, "Welcome to the show."),
            self.Segment(15.0, 25.0, "Please subscribe to the newsletter for release notes and guides."),
            self.Segment(25.0, 35.0, "Chapter one covers lexical analysis and token streams."),
            self.Segment(35.0, 45.0, "Chapter two covers parsing grammar derivations."),
            self.Segment(45.0, 55.0, "Chapter three covers intermediate code representation."),
            self.Segment(55.0, 65.0, "Chapter four covers register allocation strategies."),
        ]
        self.assertFalse(self.ads._house_roll_call(promo_cues[1].text))

        # 2a. Unclamped answer: verifier answers cue 4 -> ends at cue 3 (45.0) unclamped
        backend_promo_success = ScriptedBackend(
            label_map={1: "self_promo"}, content_start_id=4, ads_module=self.ads
        )
        with self.assertNoLogs("wilted.ads", level="INFO"):
            detections_promo = self.ads.detect_ads(promo_cues, backend_promo_success, remove_self_promotion=True)
        self.assertEqual(len(detections_promo), 1)
        self.assertEqual(detections_promo[0].end_s, 45.0)

        # 2b. Suppression on failure: verifier answers window edge -> suppressed
        backend_promo_fail = ScriptedBackend(
            label_map={1: "self_promo"}, content_start_id="window_max", ads_module=self.ads
        )
        with self.assertLogs("wilted.ads", level="INFO") as cm:
            detections_fail = self.ads.detect_ads(promo_cues, backend_promo_fail, remove_self_promotion=True)
        self.assertEqual(len(detections_fail), 0)
        self.assertFalse(any("kept to its own cues after the content-start verifier failed" in msg for msg in cm.output))

        # 3. Roll call already inside an eligible run is not seeded twice
        roll_call_cues = [
            self.Segment(0.0, 10.0, "Introduction to our discussion."),
            self.Segment(
                15.0,
                25.0,
                "Quick announcements: thank you to today's sponsors, visit patreon.com for ad-free episodes.",
            ),
            self.Segment(25.0, 35.0, "Now onto our technical discussion."),
        ]
        backend_seeded = ScriptedBackend(
            label_map={1: "self_promo"}, content_start_id=2, ads_module=self.ads
        )
        with self.assertLogs("wilted.ads", level="INFO") as cm:
            detections_seeded = self.ads.detect_ads(roll_call_cues, backend_seeded, remove_self_promotion=True)
        self.assertEqual(len(detections_seeded), 1)
        self.assertFalse(any("Seeding house roll call" in msg for msg in cm.output))

    def test_house_roll_call_helper(self):
        """Direct tests for _house_roll_call definition."""
        # Weak only: false
        self.assertFalse(self.ads._house_roll_call("register for our webinar"))
        self.assertFalse(self.ads._house_roll_call("subscribe to our newsletter"))
        self.assertFalse(self.ads._house_roll_call("cohort registration is open"))

        # Single strong cue: false (needs at least two distinct cues)
        self.assertFalse(self.ads._house_roll_call("thank you to today's sponsors"))
        self.assertFalse(self.ads._house_roll_call("thank you to today's sponsors and thank you to our sponsors"))
        self.assertFalse(self.ads._house_roll_call("support us on patreon"))
        self.assertFalse(self.ads._house_roll_call("listen to the ad-free version"))

        # Strong cue + weak cue: true
        self.assertTrue(self.ads._house_roll_call("thank you to today's sponsors, register on our website"))
        self.assertTrue(self.ads._house_roll_call("patreon supporters get access to our webinar"))
        self.assertTrue(self.ads._house_roll_call("subscribe for ad-free episodes"))

        # Multiple strong cues: true
        self.assertTrue(self.ads._house_roll_call("thank you to our sponsors, find the ad-free feed on patreon"))

    def test_house_extent_end_helper(self):
        """Direct tests for _house_extent_end definition."""
        cues = [
            self.Segment(0.0, 10.0, "thank you to today's sponsors and patreon"),
            self.Segment(10.0, 20.0, "join our webinar"),
            self.Segment(20.0, 30.0, "register now"),
            # Pause >= 2.0s breaks extent
            self.Segment(33.0, 40.0, "summer cohort"),
            self.Segment(40.0, 50.0, "regular programme"),
        ]
        self.assertEqual(self.ads._house_extent_end(0, cues), 2)
        # Starting at 3, next cue 4 has no house word so ends at 3
        self.assertEqual(self.ads._house_extent_end(3, cues), 3)


if __name__ == "__main__":
    unittest.main()
