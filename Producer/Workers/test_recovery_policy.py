"""Known ad-kind safeguards around commercial recovery."""
from __future__ import annotations

import io
import unittest
from contextlib import redirect_stderr
from unittest import mock

from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import commercial_seeds as _worker_commercial_seeds
from wilted_worker import prompts as _worker_prompts
from wilted_worker import recovery_policy as _worker_recovery_policy
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment, wp


class KnownAdKindRecoveryTests(unittest.TestCase):
    """Exercise metadata-based house safeguards through worker recovery paths."""

    def _analysis(self, detections, remove_self_promotion: bool):
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        received_mode = []

        def detect(_segments, _backend, **kwargs):
            received_mode.append(bool(kwargs.get("remove_self_promotion", False)))
            return list(detections)

        ads.detect_ads = detect
        segments = [
            FakeSegment(0.0, 10.0, "editorial before"),
            FakeSegment(10.0, 20.0, "house announcement"),
            FakeSegment(20.0, 30.0, "editorial after"),
        ]
        with redirect_stderr(io.StringIO()):
            analysis = wp.analyze_ad_detections(
                ads, llm, segments, 100.0,
                remove_self_promotion=remove_self_promotion,
            )
        return analysis, ads, llm, received_mode

    def test_paid_candidate_recovers_in_both_setting_modes(self):
        segments = [
            FakeSegment(0.0, 10.0, "editorial before the break"),
            FakeSegment(10.0, 20.0, "Acme Cloud sponsors today's programme"),
            FakeSegment(20.0, 30.0, "Get started at acme dot com for twenty percent off"),
            FakeSegment(30.0, 40.0, "editorial resumes after the break"),
        ]
        observed_recovery_modes = []
        for remove_self_promotion in (False, True):
            with self.subTest(remove_self_promotion=remove_self_promotion):
                llm = FakeLLM(
                    commercial_ad_ids=[1, 2],
                    commercial_programme_ids=[0, 3],
                )
                llm.load()
                ads = install_fake_ads(llm)
                ads.detect_ads = lambda _segments, _backend, **_kwargs: []
                evidence = _worker_commercial_seeds.recover_commercial_evidence_reads
                sparse = _worker_commercial_seeds.recover_sparse_commercial_reads

                def capture_evidence(*args, **kwargs):
                    observed_recovery_modes.append(("evidence", args[5]))
                    return evidence(*args, **kwargs)

                def capture_sparse(*args, **kwargs):
                    observed_recovery_modes.append(("sparse", args[6]))
                    return sparse(*args, **kwargs)

                with redirect_stderr(io.StringIO()), mock.patch.object(
                    _worker_commercial_seeds,
                    "recover_commercial_evidence_reads",
                    capture_evidence,
                ), mock.patch.object(
                    _worker_commercial_seeds,
                    "recover_sparse_commercial_reads",
                    capture_sparse,
                ):
                    analysis = wp.analyze_ad_detections(
                        ads, llm, segments, 500.0,
                        remove_self_promotion=remove_self_promotion,
                    )

                self.assertEqual(len(analysis.detections), 1)
                recovered = analysis.detections[0]
                self.assertEqual((recovered.start_s, recovered.end_s), (10.0, 30.0))
                self.assertEqual(recovered.label, "sponsor_read")
                self.assertEqual(recovered.kinds, ("paid advertising",))
                preservation_prompt = (
                    _worker_prompts.SELF_PROMOTION_COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT
                    if remove_self_promotion
                    else _worker_prompts.COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT
                )
                self.assertIn(preservation_prompt, llm.request_prompts)

        self.assertEqual(
            observed_recovery_modes,
            [("evidence", False), ("sparse", False), ("evidence", True), ("sparse", True)],
        )

    def test_unclassified_own_promotion_keeps_baseline_paid_recovery(self):
        segments = [
            FakeSegment(0.0, 10.0, "editorial before the break"),
            FakeSegment(10.0, 20.0, "Visit ourshow dot com slash live for our event tickets"),
            FakeSegment(20.0, 30.0, "Get started today for the live event"),
            FakeSegment(30.0, 40.0, "editorial resumes after the break"),
        ]
        llm = FakeLLM(commercial_ad_ids=[1, 2], commercial_programme_ids=[0, 3])
        llm.load()
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend, **_kwargs: []

        with redirect_stderr(io.StringIO()):
            analysis = wp.analyze_ad_detections(
                ads, llm, segments, 500.0, remove_self_promotion=False,
            )

        # This records the unresolved ownership gap: no known house kind was
        # present, so generic commercial recovery retains its baseline behavior.
        self.assertEqual(len(analysis.detections), 1)
        self.assertEqual(analysis.detections[0].label, "sponsor_read")
        self.assertEqual(analysis.detections[0].kinds, ("paid advertising",))

    def test_known_house_detection_is_kept_or_cut_by_setting(self):
        house = FakeAd(10.0, 20.0, label="sponsor_read", kinds=("house promotion",))

        kept, _, _, false_mode = self._analysis([house], False)
        self.assertEqual(kept.detections, ())
        self.assertEqual(false_mode, [False])
        self.assertIn(
            "house-promotion-disabled",
            {held.reason for held in kept.audit.held_spans},
        )

        removed, _, _, true_mode = self._analysis([house], True)
        self.assertEqual(removed.detections, (house,))
        self.assertEqual(true_mode, [True])

    def test_house_label_blocks_paid_kind_laundering(self):
        mislabeled = FakeAd(
            10.0, 20.0, label="self_promo", kinds=("paid advertising",)
        )
        analysis, _, _, _ = self._analysis([mislabeled], False)
        self.assertEqual(analysis.detections, ())
        self.assertIn(
            "house-promotion-disabled",
            {held.reason for held in analysis.audit.held_spans},
        )

    def test_house_only_anchor_keeps_its_kind_when_expanded(self):
        segments = [
            FakeSegment(0.0, 5.0, "editorial before"),
            FakeSegment(10.0, 18.0, "Join our newsletter at oursite dot com"),
            FakeSegment(18.0, 24.0, "More details at oursite dot com"),
            FakeSegment(34.0, 40.0, "editorial after"),
        ]
        original = FakeAd(
            10.0, 18.0, label="sponsor_read", confidence=0.9,
            kinds=("house promotion",),
        )
        backend = FakeLLM(commercial_programme_ids=[0, 3])
        backend.load()
        ads = install_fake_ads(backend)

        class EmptyAudit:
            candidates = ()

        with redirect_stderr(io.StringIO()):
            kept = _worker_commercial_seeds.recover_sparse_commercial_reads(
                ads, backend, segments, [original], 100.0, EmptyAudit(),
                remove_self_promotion=False,
            )
        self.assertEqual(kept, [original])

        backend_true = FakeLLM(commercial_programme_ids=[0, 3])
        backend_true.load()
        ads_true = install_fake_ads(backend_true)
        with redirect_stderr(io.StringIO()):
            expanded = _worker_commercial_seeds.recover_sparse_commercial_reads(
                ads_true, backend_true, segments, [original], 100.0, EmptyAudit(),
                remove_self_promotion=True,
            )
        self.assertEqual(len(expanded), 1)
        self.assertEqual((expanded[0].start_s, expanded[0].end_s), (10.0, 24.0))
        self.assertEqual(expanded[0].kinds, ("house promotion",))
        self.assertEqual(expanded[0].label, "self_promo")

    def test_merge_keeps_union_of_existing_paid_and_house_kinds(self):
        segments = [
            FakeSegment(0.0, 5.0, "editorial before"),
            FakeSegment(10.0, 18.0, "Get started at acme dot com for an offer"),
            FakeSegment(18.0, 24.0, "More details at oursite dot com"),
            FakeSegment(34.0, 40.0, "editorial after"),
        ]
        paid = FakeAd(
            10.0, 18.0, label="sponsor_read", confidence=0.9,
            kinds=("paid advertising",),
        )
        house = FakeAd(
            18.0, 24.0, label="self_promo", confidence=0.8,
            kinds=("house promotion",),
        )
        backend = FakeLLM(commercial_programme_ids=[0, 3])
        backend.load()
        ads = install_fake_ads(backend)

        class EmptyAudit:
            candidates = ()

        with redirect_stderr(io.StringIO()):
            merged = _worker_commercial_seeds.recover_sparse_commercial_reads(
                ads, backend, segments, [paid, house], 100.0, EmptyAudit(),
                remove_self_promotion=True,
            )
        self.assertEqual(len(merged), 1)
        self.assertEqual((merged[0].start_s, merged[0].end_s), (10.0, 24.0))
        self.assertEqual(merged[0].kinds, ("house promotion", "paid advertising"))
        self.assertEqual(merged[0].label, "sponsor_read")

    def test_blocked_house_region_subtracts_existing_paid_core(self):
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        house = FakeAd(20.0, 60.0, label="self_promo", kinds=("house promotion",))
        paid = FakeAd(55.0, 80.0, label="sponsor_read", kinds=("paid advertising",))
        held = []
        stream = io.StringIO()
        with redirect_stderr(stream):
            kept = _worker_recovery_policy.enforce_known_house_kind_policy(
                [house, paid], ads, 100.0, False, held,
            )
        self.assertEqual(kept, [paid])
        self.assertEqual(
            [(item.start_s, item.end_s, item.reason) for item in held],
            [(20.0, 55.0, "house-promotion-disabled")],
        )

        later = FakeAd(20.0, 80.0, label="sponsor_read", kinds=("paid advertising",))
        projected = _worker_recovery_policy.project_detections_around_blocked_house_regions(
            [later], ads, held,
        )
        self.assertEqual([(item.start_s, item.end_s) for item in projected], [(55.0, 80.0)])
        self.assertEqual(projected[0].kinds, ("paid advertising",))

    def test_initial_house_is_filtered_before_share_and_resize_guards(self):
        segments = [
            FakeSegment(0.0, 20.0, "editorial before"),
            FakeSegment(20.0, 60.0, "known house promotion"),
            FakeSegment(60.0, 85.0, "paid sponsor segment"),
            FakeSegment(85.0, 100.0, "editorial after"),
        ]
        detections = [
            FakeAd(20.0, 60.0, label="self_promo", kinds=("house promotion",)),
            FakeAd(60.0, 85.0, label="sponsor_read", kinds=("paid advertising",)),
        ]
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend, **_kwargs: detections

        resize = _worker_ad_removal._worker_span_bounds.resize_oversized_ad_spans
        resize_inputs = []

        def capture_resize(*args, **kwargs):
            resize_inputs.append(tuple(args[3]))
            return resize(*args, **kwargs)

        with redirect_stderr(io.StringIO()), mock.patch.object(
            _worker_ad_removal._worker_preroll_passage_review,
            "recover_source_checked_preroll",
            lambda _ads, _backend, _segments, current, *_args, **_kwargs: [*current, detections[0]],
        ), mock.patch.object(
            _worker_ad_removal._worker_span_bounds,
            "resize_oversized_ad_spans",
            capture_resize,
        ):
            analysis = wp.analyze_ad_detections(
                ads, llm, segments, 100.0, remove_self_promotion=False,
            )

        self.assertEqual(len(resize_inputs), 1)
        self.assertEqual(resize_inputs[0], (detections[1],))
        self.assertEqual([(ad.start_s, ad.end_s) for ad in analysis.detections], [(60.0, 85.0)])
        held_reasons = {held.reason for held in analysis.audit.held_spans}
        self.assertIn("house-promotion-disabled", held_reasons)
        self.assertNotIn("total-share-ceiling", held_reasons)

    def test_late_extension_is_clipped_without_losing_paid_core(self):
        segments = [
            FakeSegment(0.0, 20.0, "editorial before"),
            FakeSegment(20.0, 50.0, "known house promotion"),
            FakeSegment(50.0, 70.0, "paid sponsor segment"),
            FakeSegment(70.0, 100.0, "editorial after"),
        ]
        house = FakeAd(20.0, 50.0, label="self_promo", kinds=("house promotion",))
        paid = FakeAd(50.0, 70.0, label="sponsor_read", kinds=("paid advertising",))
        llm = FakeLLM()
        llm.load()
        ads = install_fake_ads(llm)
        ads.detect_ads = lambda _segments, _backend, **_kwargs: [house, paid]

        def expand_late(*args, **kwargs):
            return [FakeAd(40.0, 70.0, label="sponsor_read", kinds=("paid advertising",))]

        with redirect_stderr(io.StringIO()), mock.patch.object(
            _worker_ad_removal._worker_break_starts,
            "recover_late_break_starts",
            expand_late,
        ):
            analysis = wp.analyze_ad_detections(
                ads, llm, segments, 100.0, remove_self_promotion=False,
            )

        self.assertEqual([(ad.start_s, ad.end_s) for ad in analysis.detections], [(50.0, 70.0)])
        self.assertEqual(analysis.detections[0].kinds, ("paid advertising",))
        self.assertIn(
            "house-promotion-disabled",
            {held.reason for held in analysis.audit.held_spans},
        )


if __name__ == "__main__":
    unittest.main()
