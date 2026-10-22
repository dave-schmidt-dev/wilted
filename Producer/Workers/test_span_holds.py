"""Regression coverage for held ad spans: what an unresolved review keeps and what the ceilings cut."""
from __future__ import annotations

import contextlib
import io
import re
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stderr
from unittest import mock

from wilted_worker import ad_audit
from wilted_worker import ad_removal
from wilted_worker import boundary_review
from wilted_worker import constants
from wilted_worker import cue_timing
from wilted_worker import gpu_admission
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
from worker_test_support import FakeSegment, install_fake_wilted, wp


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


class LocalUnresolvedSeedTests(unittest.TestCase):
    """One unresolved commercial span no cut reaches no longer voids every other cut.

    The 2026-10-22 SmartLess regression: a single unresolved cue of the show's
    own promotion kept four confirmed advertising breaks in the delivered audio.
    """

    CUT = FakeAd(480.0, 540.0, label="sponsor_read")

    def detect(self, seeds, detections=(CUT,)):
        segments = [FakeSegment(i * 60.0, (i + 1) * 60.0, f"cue {i}") for i in range(10)]
        analysis = AdAnalysis(
            detections=tuple(detections),
            audit=AdAnalysisAudit(declined_commercial_evidence_seeds=tuple(seeds)),
        )
        with tempfile.TemporaryDirectory() as scratch:
            audio = Path(scratch) / "source.mp3"
            output = Path(scratch) / "cut.mp3"
            audio.write_bytes(b"original audio")
            install_fake_ads(FakeLLM())

            def render(_audio, destination, _keeps):
                Path(destination).write_bytes(b"rendered cut")

            render_call = mock.Mock(side_effect=render)
            progress = mock.Mock()
            with (
                mock.patch.object(ad_removal._worker_cue_timing, "probe_duration", return_value=600.0),
                mock.patch.object(ad_removal, "analyze_ad_detections", return_value=analysis),
                mock.patch.dict(ad_removal.__dict__, {"render_keep_segments": render_call}),
                mock.patch.object(ad_removal._worker_reporting, "progress", progress),
            ):
                result = ad_removal.detect_and_cut(
                    {"outputPath": str(output)}, audio, [], segments,
                    model_lock=contextlib.nullcontext(),
                )
        stages = [call.args[0] for call in progress.call_args_list]
        return audio, output, result, render_call, stages

    @staticmethod
    def seed(cue, reason="review-unresolved"):
        return DeclinedCommercialEvidenceSeed(
            ids=(cue,), start_s=cue * 60.0, end_s=(cue + 1) * 60.0, reason=reason
        )

    def test_an_isolated_unresolved_span_stays_and_the_confirmed_cut_applies(self):
        _audio, output, result, render, stages = self.detect([self.seed(2)])
        self.assertEqual(result[0], output)
        render.assert_called_once()
        audit = result[4]
        self.assertIsNone(audit["warning"])
        self.assertIsNone(audit["incompleteError"])
        self.assertEqual(
            [(s["reason"], s["ids"]) for s in audit["declinedCommercialEvidenceSeeds"]],
            [("review-unresolved", [2])],
        )
        self.assertIn("ads.detect.seed.kept", stages)
        self.assertNotIn("ads.uncertain", stages)

    def test_doubt_beside_or_about_a_cut_still_keeps_the_whole_original(self):
        cases = (
            ("in the cue just before the cut", [self.seed(7)], (self.CUT,)),
            ("in the cue just after the cut", [self.seed(9)], (self.CUT,)),
            ("dropped after a proposed cut", [self.seed(2, "dropped-after-proposal")], (self.CUT,)),
            ("isolated but beside another", [self.seed(2), self.seed(7)], (self.CUT,)),
            ("isolated with nothing to cut", [self.seed(2)], ()),
        )
        for name, seeds, detections in cases:
            with self.subTest(case=name):
                audio, _output, result, render, stages = self.detect(seeds, detections)
                self.assertEqual(result[:4], (audio, [], [], []))
                self.assertIn("could not safely resolve", result[4]["incompleteError"])
                render.assert_not_called()
                self.assertIn("ads.uncertain", stages)


    def test_an_isolated_unresolved_seed_stays_audible_while_an_independent_confirmed_ad_is_cut(self):
        # The 2026-10-22 SmartLess regression: one unresolved commercial seed
        # that no cut reaches used to keep every confirmed advertisement.
        audio = Path(__file__)
        segments = [FakeSegment(0, 10, "programme before"), FakeSegment(10, 20, "visit acme dot"),
                    FakeSegment(20, 30, "com to get started today"), FakeSegment(30, 40, "programme after")]
        install_fake_wilted(transcriptions={wp.ALIGNED_STT_MODEL: segments})
        install_fake_ads(FakeLLM(commercial_ad_ids=[1, 2], commercial_preservation_answer="invalid JSON"),
                         detections=[FakeAd(400, 420)])

        def render(command, *, timeout_s):
            Path(command[-1]).write_bytes(b"rendered cut")

        with tempfile.TemporaryDirectory() as scratch, redirect_stderr(io.StringIO()), \
                mock.patch.object(ad_audit, "preflight_ad_removal"), \
                mock.patch.object(cue_timing, "probe_duration",
                                  side_effect=lambda path: 600.0 if Path(path) == audio else 580.0), \
                mock.patch.object(gpu_admission, "prepare_ad_model_lock", return_value=contextlib.nullcontext()), \
                mock.patch.object(span_bounds, "resize_oversized_ad_spans", side_effect=lambda _ads, _backend, _segments, spans, *_args, **_kwargs: (spans, frozenset((ad.start_s, ad.end_s) for ad in spans))), \
                mock.patch.object(cue_timing, "_run_render_with_progress", side_effect=render):
            result = wp.run({"protocolVersion": 2, "audioPath": str(audio),
                             "outputPath": str(Path(scratch) / "cut.mp3"), "removeAds": True,
                             "readableTranscript": False})
        self.assertEqual(result["report"]["outcome"], "cut")
        self.assertTrue(result["audioChanged"])
        self.assertEqual(result["removedSeconds"], 20.0)
        audit = result["report"]["audit"]
        self.assertIsNone(audit["warning"])
        self.assertIsNone(audit["incompleteError"])
        self.assertEqual([(s["reason"], s["ids"]) for s in audit["declinedCommercialEvidenceSeeds"]],
                         [("review-unresolved", [1, 2])])


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

    def test_an_unresolved_hold_keeps_the_original_and_reports_why(self):
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
        self.assertEqual(result[:4], (audio, [], [], []))
        self.assertIn("could not safely resolve", result[4]["incompleteError"])
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
