"""Profile guidance remains a bounded hint and learns only from primary labels."""
from __future__ import annotations

import json
import re
import unittest

from worker_test_support import load_runtime_ads
from wilted_worker.ad_audit import AuditingBackend
from wilted_worker.feed_profile_runtime import (
    MAX_PROFILE_CALLS,
    _slot_windows,
    independent_primary_observation,
    recover_profile_candidates,
)


class ScriptedProfileBackend:
    """Small local model double for profile classification and preservation."""

    def __init__(self, ads, *, ad_ids=(), labels=None, opening_id=None, confirm_id=-1):
        self.ads = ads
        self.ad_ids = set(ad_ids)
        self.ad_labels = {}
        self.labels = labels
        self.opening_id = opening_id
        self.confirm_id = confirm_id
        self.requests = []
        self.loaded = True
        self.malformed_classifications = False
        self.measurements = 0

    def measure_prompt(self, system_prompt, user_content, *, response_format=None):
        self.measurements += 1
        return (100, 4096, 64)

    def generate(self, system_prompt, user_content, *, response_format=None, prepared_prompt=None):
        self.requests.append((system_prompt, user_content, response_format))
        field = (response_format or {}).get("field")
        properties = ((response_format or {}).get("schema") or {}).get("properties", {})
        from wilted_worker.prompts import SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT, SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT
        if system_prompt in {
            self.ads._AD_DETECT_SYSTEM_PROMPT, self.ads._AD_DETECT_CORRECTION_PROMPT,
            SELF_PROMOTION_AD_DETECT_SYSTEM_PROMPT, SELF_PROMOTION_AD_DETECT_CORRECTION_PROMPT,
        }:
            if self.malformed_classifications:
                return "not-json", 1
            ids = [int(value) for value in re.findall(r"\[ID (\d+)\]", user_content)]
            return json.dumps({"ads": [
                [index, self.ad_labels.get(index, "sponsor_read")]
                for index in ids if index in self.ad_ids
            ]}), 1
        if "program_start_id" in properties:
            permitted = properties["program_start_id"].get("enum", [])
            value = self.opening_id if self.opening_id in permitted else 0
            return json.dumps({"program_start_id": value}), 1
        if "program_id" in properties:
            permitted = properties["program_id"].get("enum", [])
            value = self.confirm_id if self.confirm_id in permitted else permitted[0]
            return json.dumps({"program_id": value}), 1
        if "labels" in properties:
            ids = properties["labels"].get("required", [])
            return json.dumps({"labels": {
                str(index): (self.labels or {}).get(int(index), "programme") for index in ids
            }}), 1
        raise AssertionError(f"Unexpected profile prompt: {system_prompt[:60]}")


class FeedProfileRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ads, cls.Segment = load_runtime_ads()

    def profile(self, start=3000, end=6000, position="mid", entry=None, returning=None):
        return {
            "schemaVersion": 1,
            "feedID": "feed-exact-1",
            "revision": 1,
            "sampleCount": 1,
            "slots": [{
                "position": position,
                "startBasisPoints": start,
                "endBasisPoints": end,
                "entryPhrases": [entry] if entry else [],
                "returnPhrases": [returning] if returning else [],
            }],
        }

    def segments(self, count=10):
        return [self.Segment(index * 10, (index + 1) * 10, f"programme cue {index}")
                for index in range(count)]

    def test_slot_window_follows_position_and_keeps_partially_covered_cues(self):
        segments = self.segments()
        existing = [self.ads.AdSegment(42, 48, 0.9, "sponsor_read")]
        windows = _slot_windows(self.profile(), segments, 100, existing)
        self.assertEqual(len(windows), 1)
        ids, _rendered, slot = windows[0]
        self.assertEqual(ids, (3, 4, 5))
        self.assertEqual(slot["position"], "mid")

    def test_literal_marker_can_shift_the_profile_window_within_a_bounded_range(self):
        segments = self.segments(12)
        segments[3] = self.Segment(28, 38, "Sponsored phrase begins for this episode")
        windows = _slot_windows(
            self.profile(2000, 3000, entry="Sponsored phrase begins"), segments, 120, ()
        )
        self.assertEqual(len(windows), 1)
        self.assertIn(3, windows[0][0])
        self.assertEqual(windows[0][2]["entryPhrases"], ["Sponsored phrase begins"])

    def test_primary_observation_is_bounded_and_uses_the_real_return_cue(self):
        segments = self.segments(5)
        segments[1] = self.Segment(10, 20, "A sponsor read begins with Acme products")
        segments[2] = self.Segment(20, 30, "Buy Acme now at acme.com")
        segments[3] = self.Segment(30, 40, "The hosts return to their conversation")
        raw = ScriptedProfileBackend(self.ads, ad_ids={1, 2})
        audited = AuditingBackend(raw, self.ads, len(segments))
        rendered = self.ads._render_segments_bounded([0, 1, 2, 3, 4], segments)
        audited.generate(
            self.ads._AD_DETECT_SYSTEM_PROMPT, rendered,
            response_format=self.ads._AD_DETECT_RESPONSE_FORMAT,
        )
        observation = independent_primary_observation(
            audited, segments, feed_id="feed-exact-1", episode_id="episode-1",
            source_hash="a" * 64, total_seconds=50,
        )
        self.assertEqual(observation["sourceHash"], "a" * 64)
        self.assertEqual(observation["slots"][0]["position"], "mid")
        self.assertEqual(observation["slots"][0]["returnPhrases"], ["The hosts return to their conversation"])
        self.assertNotIn("acme.com", json.dumps(observation))

    def test_profile_scans_only_uncovered_current_cues_and_requires_full_preservation(self):
        segments = self.segments()
        segments[3] = self.Segment(30, 40, "A current sponsor read for Acme")
        segments[4] = self.Segment(40, 50, "Buy Acme at acme.com today")
        segments[5] = self.Segment(50, 60, "Acme sponsors this episode")
        ads = self.ads
        raw = ScriptedProfileBackend(ads, ad_ids={3, 4, 5}, labels={
            2: "programme", 3: "commercial", 4: "commercial", 5: "commercial", 6: "programme",
        })
        baseline = AuditingBackend(raw, ads, len(segments))
        existing = [ads.AdSegment(42, 48, 0.9, "sponsor_read")]
        recovery = recover_profile_candidates(
            ads, baseline, segments, 300, self.profile(1000, 2000, entry="previous sampled opening"), existing_detections=existing,
        )
        self.assertEqual([(item.start_s, item.end_s) for item in recovery.detections], [(30.0, 60.0)])
        self.assertLessEqual(recovery.requests, MAX_PROFILE_CALLS)
        self.assertLessEqual(recovery.windows, 4)
        # Preservation sees current cues only and receives no expected-slot data.
        from wilted_worker.prompts import COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT
        preservation = [row for row in raw.requests if row[0] == COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT]
        self.assertEqual(len(preservation), 1)
        self.assertNotIn("startBasisPoints", preservation[0][1])
        self.assertNotIn("previous sampled opening", preservation[0][1])

    def test_preroll_q1_uses_profile_hint_but_cold_open_q2_sees_blind_right_context(self):
        segments = self.segments(8)
        segments[0] = self.Segment(0, 10, "A paid spot begins")
        segments[1] = self.Segment(10, 20, "The product is available now")
        segments[2] = self.Segment(20, 30, "Visit acme.com to learn more")
        segments[3] = self.Segment(30, 40, "The hosts begin their episode")
        raw = ScriptedProfileBackend(
            self.ads, ad_ids={0, 1, 2}, labels={0: "commercial", 1: "commercial", 2: "commercial"},
            opening_id=3, confirm_id=0,
        )
        baseline = AuditingBackend(raw, self.ads, len(segments))
        recovery = recover_profile_candidates(
            self.ads, baseline, segments, 80, self.profile(0, 4000, "pre", "A paid spot begins"),
        )
        self.assertEqual(recovery.detections, ())
        opening = next(row for row in raw.requests if "program_start_id" in row[2]["schema"]["properties"])
        confirmation = next(row for row in raw.requests if "program_id" in row[2]["schema"]["properties"])
        self.assertIn("Ad placement profile search hint", opening[1])
        self.assertIn('"entryPhrases"', opening[1])
        self.assertNotIn("Ad placement profile search hint", confirmation[1])
        self.assertIn("hosts begin their episode", confirmation[1])
        self.assertIn("Candidate IDs to assess: 0, 1, 2", confirmation[1])
        self.assertIn("Following IDs are comparison context only: 3, 4, 5, 6, 7", confirmation[1])
        self.assertEqual(list(confirmation[2]["schema"]["properties"]), ["program_id"])
        self.assertIn(0, confirmation[2]["schema"]["properties"]["program_id"]["enum"])
        self.assertIn(-1, confirmation[2]["schema"]["properties"]["program_id"]["enum"])

    def test_profile_call_budget_exhaustion_keeps_the_candidate(self):
        segments = self.segments(64)
        raw = ScriptedProfileBackend(self.ads, ad_ids=set(range(64)))
        raw.malformed_classifications = True
        baseline = AuditingBackend(raw, self.ads, len(segments))
        profile = self.profile(0, 10_000, "mid")
        recovery = recover_profile_candidates(
            self.ads, baseline, segments, 1000, profile,
        )
        self.assertEqual(recovery.detections, ())
        self.assertEqual(recovery.requests, MAX_PROFILE_CALLS)
        self.assertGreaterEqual(raw.measurements, MAX_PROFILE_CALLS)

    def test_profile_window_overflow_keeps_full_source_cues(self):
        segments = self.segments()
        segments[3] = self.Segment(30, 40, "a" * 13_000)
        raw = ScriptedProfileBackend(self.ads, ad_ids={3})
        baseline = AuditingBackend(raw, self.ads, len(segments))
        recovery = recover_profile_candidates(
            self.ads, baseline, segments, 100, self.profile(),
        )
        self.assertEqual(recovery.detections, ())
        self.assertEqual(recovery.windows, 0)
        self.assertEqual(raw.requests, [])

    def test_self_promotion_profile_uses_the_current_removal_setting(self):
        segments = self.segments()
        segments[3] = self.Segment(30, 40, "The show has a paid newsletter")
        segments[4] = self.Segment(40, 50, "Subscribe to our member edition")
        segments[5] = self.Segment(50, 60, "We return to the discussion")
        profile = self.profile(1000, 2000)
        raw = ScriptedProfileBackend(self.ads, ad_ids={3, 4})
        raw.ad_labels = {3: "self_promo", 4: "self_promo"}
        raw.labels = {2: "programme", 3: "commercial", 4: "commercial", 5: "programme"}
        baseline = AuditingBackend(raw, self.ads, len(segments))
        off = recover_profile_candidates(
            self.ads, baseline, segments, 300, profile, remove_self_promotion=False,
        )
        self.assertEqual(off.detections, ())
        on = recover_profile_candidates(
            self.ads, baseline, segments, 300, profile, remove_self_promotion=True,
        )
        self.assertEqual([item.label for item in on.detections], ["self_promo"])

    def test_profile_calls_do_not_change_independent_primary_observation(self):
        segments = self.segments(6)
        raw = ScriptedProfileBackend(self.ads, ad_ids={1, 2})
        baseline = AuditingBackend(raw, self.ads, len(segments))
        baseline.generate(
            self.ads._AD_DETECT_SYSTEM_PROMPT,
            self.ads._render_segments_bounded(list(range(6)), segments),
            response_format=self.ads._AD_DETECT_RESPONSE_FORMAT,
        )
        kwargs = dict(feed_id="feed-exact-1", episode_id="episode-1", source_hash="b" * 64,
                      total_seconds=60)
        before = independent_primary_observation(baseline, segments, **kwargs)
        recover_profile_candidates(
            self.ads, baseline, segments, 60, self.profile(1000, 6000),
        )
        after = independent_primary_observation(baseline, segments, **kwargs)
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
