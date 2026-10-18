"""Regression coverage for held ad spans: what an unresolved review keeps and what the ceilings cut."""
from __future__ import annotations

import contextlib
import re
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from wilted_worker import ad_removal
from wilted_worker import boundary_review
from wilted_worker import constants
from wilted_worker import span_bounds
from wilted_worker import tail_recovery
from wilted_worker.ad_audit import (
    AdAnalysis,
    AdAnalysisAudit,
    DeclinedCommercialEvidenceSeed,
    HeldAdSpan,
)
from worker_test_fake_ads import FakeAd, install_fake_ads
from worker_test_fake_llm import FakeLLM
from worker_test_support import FakeSegment


class HeldSeedFallbackTests(unittest.TestCase):
    def run_detection(self, root, seed, held):
        audio = root / "source.mp3"
        output = root / "cut.mp3"
        audio.write_bytes(b"original audio")
        install_fake_ads(FakeLLM())
        analysis = AdAnalysis(
            detections=(FakeAd(400.0, 420.0, label="sponsor_read"),),
            audit=AdAnalysisAudit(
                declined_commercial_evidence_seeds=(seed,),
                held_spans=(held,),
            ),
        )
        segments = [FakeSegment(0.0, 600.0, "one full programme cue")]

        def render(_audio, destination, _keeps):
            Path(destination).write_bytes(b"rendered cut")

        render_call = mock.Mock(side_effect=render)
        with (
            mock.patch.object(ad_removal._worker_cue_timing, "probe_duration", return_value=600.0),
            mock.patch.object(ad_removal, "analyze_ad_detections", return_value=analysis),
            mock.patch.dict(ad_removal.__dict__, {"render_keep_segments": render_call}),
        ):
            result = ad_removal.detect_and_cut(
                {"outputPath": str(output)}, audio, [], segments,
                model_lock=contextlib.nullcontext(),
                with_report=True,
            )
        return audio, output, result, render_call

    def test_only_a_containing_positive_programme_cue_exempts_a_declined_seed(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            seed_in_cue = DeclinedCommercialEvidenceSeed(
                ids=(0,), start_s=22.0, end_s=28.0, reason="review-unresolved"
            )
            positive_cue = HeldAdSpan(20.0, 30.0, "programme-boundary")
            audio, output, result, render = self.run_detection(root, seed_in_cue, positive_cue)
            self.assertEqual(result[0], output)
            self.assertNotEqual(result[0], audio)
            render.assert_called_once()

        failing_cases = (
            (
                "seed outside cue",
                DeclinedCommercialEvidenceSeed(
                    ids=(0,), start_s=40.0, end_s=48.0, reason="review-unresolved"
                ),
                HeldAdSpan(20.0, 30.0, "programme-boundary"),
            ),
            (
                "unresolved boundary is not positive proof",
                DeclinedCommercialEvidenceSeed(
                    ids=(0,), start_s=22.0, end_s=28.0, reason="review-unresolved"
                ),
                HeldAdSpan(20.0, 30.0, "boundary-review-unresolved"),
            ),
        )
        for name, seed, held in failing_cases:
            with self.subTest(case=name), tempfile.TemporaryDirectory() as scratch:
                audio, _output, result, render = self.run_detection(Path(scratch), seed, held)
                self.assertEqual(result[0], audio)
                self.assertEqual(result[1:3], ([], []))
                render.assert_not_called()

    def test_trimmed_mixed_tail_is_kept_during_later_reextension(self):
        llm = FakeLLM(boundary_starts_program=True)
        llm.load()
        ads = install_fake_ads(llm)
        segments = [
            FakeSegment(index * 20.0, (index + 1) * 20.0, f"cue {index}")
            for index in range(10)
        ]
        initial = FakeAd(6.72, 200.0)
        held = []

        trimmed = tail_recovery.trim_straddling_span_tails(
            ads, llm, segments, [initial], re.compile(r"(?!)"), held_spans=held
        )

        self.assertEqual([(ad.start_s, ad.end_s) for ad in trimmed], [(6.72, 180.0)])
        self.assertIn((180.0, 200.0, "programme-boundary"), [
            (span.start_s, span.end_s, span.reason) for span in held
        ])
        reextended = FakeAd(6.72, 200.0)
        self.assertEqual(boundary_review.reject_programme_conflicts([reextended], held), [])


class SpanCeilingTests(unittest.TestCase):
    def test_rescan_ad_evidence_alone_needs_fresh_full_fragment_confirmation(self):
        segments = [FakeSegment(i * 20.0, (i + 1) * 20.0, f"cue {i}") for i in range(5)]
        ad = FakeAd(0.0, 100.0)
        ads = install_fake_ads(FakeLLM())
        ask = mock.Mock(side_effect=[1, 2])
        with mock.patch.dict(span_bounds.__dict__, {"_constrained_id": ask}):
            self.assertFalse(span_bounds._rescan_unconfirmed_oversized_span(ads, None, segments, ad))
        self.assertEqual(ask.call_count, 2)

        ask = mock.Mock(side_effect=[1, -1])
        with mock.patch.dict(span_bounds.__dict__, {"_constrained_id": ask}):
            self.assertTrue(span_bounds._rescan_unconfirmed_oversized_span(ads, None, segments, ad))
        self.assertEqual(ask.call_count, 2)

    def test_aggregate_unreviewed_share_is_reviewed_without_changing_caps(self):
        self.assertEqual(constants.MAXIMUM_SINGLE_AD_SHARE, 0.5)
        self.assertEqual(constants.MAXIMUM_UNCONFIRMED_AD_SHARE, 0.5)
        self.assertEqual(constants.MAXIMUM_TOTAL_AD_SHARE, 0.6)
        self.assertEqual(constants.MINIMUM_PROGRAMME_SHARE, 0.3)

        ads = [FakeAd(0.0, 30.0), FakeAd(30.0, 60.0)]
        with mock.patch.object(
            span_bounds, "_resize_one_oversized_span", return_value=("confirmed", ads[0])
        ) as review, mock.patch.object(span_bounds, "_rescan_unconfirmed_oversized_span", return_value=False):
            resized, confirmed = span_bounds.resize_oversized_ad_spans(
                object(), object(), [FakeSegment(i * 10.0, (i + 1) * 10.0, "cue") for i in range(10)],
                ads, 100.0,
            )
        self.assertEqual(review.call_count, 1)
        self.assertIn((ads[0].start_s, ads[0].end_s), confirmed)
        self.assertEqual([(ad.start_s, ad.end_s) for ad in resized], [(0.0, 30.0), (30.0, 60.0)])

    def test_failed_review_in_the_aggregate_pass_holds_its_span(self):
        segments = [FakeSegment(i * 10.0, (i + 1) * 10.0, f"cue {i}") for i in range(10)]
        spans = [FakeAd(0.0, 30.0), FakeAd(30.0, 60.0)]
        held = []
        ask = mock.Mock(side_effect=[RuntimeError("backend down"), -1, -1])
        with mock.patch.dict(boundary_review.__dict__, {"_constrained_id": ask}), \
                mock.patch.object(span_bounds, "_rescan_unconfirmed_oversized_span", return_value=False):
            _resized, confirmed = span_bounds.resize_oversized_ad_spans(
                install_fake_ads(FakeLLM()), object(), segments, spans, 100.0, held_spans=held,
            )
        self.assertEqual(confirmed, {(30.0, 60.0)})
        self.assertEqual([(span.start_s, span.end_s, span.reason) for span in held],
                         [(0.0, 30.0, "boundary-review-unresolved")])

    def test_an_unresolved_hold_keeps_the_original_without_a_report(self):
        with tempfile.TemporaryDirectory() as scratch:
            audio = Path(scratch) / "source.mp3"
            audio.write_bytes(b"original audio")
            install_fake_ads(FakeLLM())
            analysis = AdAnalysis(
                detections=(FakeAd(400.0, 420.0, label="sponsor_read"),),
                audit=AdAnalysisAudit(held_spans=(HeldAdSpan(100.0, 300.0, "boundary-review-unresolved"),)),
            )
            render = mock.Mock()
            with (
                mock.patch.object(ad_removal._worker_cue_timing, "probe_duration", return_value=600.0),
                mock.patch.object(ad_removal, "analyze_ad_detections", return_value=analysis),
                mock.patch.dict(ad_removal.__dict__, {"render_keep_segments": render}),
            ):
                result = ad_removal.detect_and_cut(
                    {"outputPath": str(Path(scratch) / "cut.mp3")}, audio, [],
                    [FakeSegment(0.0, 600.0, "one full programme cue")],
                    model_lock=contextlib.nullcontext(),
                )
        self.assertEqual(result, (audio, [], []))
        render.assert_not_called()

    def test_existing_single_span_and_total_share_ceilings_still_hold(self):
        too_large = FakeAd(0.0, 51.0)
        self.assertEqual(span_bounds.reject_implausible_ad_spans([too_large], 100.0), [])

        held = []
        above_total_ceiling = [FakeAd(0.0, 30.0), FakeAd(30.0, 31.0)]
        result = span_bounds.enforce_total_ad_share_ceiling(above_total_ceiling, 50.0, held)
        self.assertEqual(result, [])
        self.assertEqual([span.reason for span in held], ["total-share-ceiling"] * 2)


if __name__ == "__main__":
    unittest.main()
