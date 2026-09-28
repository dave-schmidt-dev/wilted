"""Podcast worker tests."""
from __future__ import annotations
import ast
import importlib.util
import inspect
import io
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from dataclasses import dataclass, field
from pathlib import Path
from unittest import mock
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import commercial_recovery as _worker_commercial_recovery
from wilted_worker import commercial_seeds as _worker_commercial_seeds
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import edge_recovery as _worker_edge_recovery
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import span_bounds as _worker_span_bounds
from wilted_worker import tail_recovery as _worker_tail_recovery
from wilted_worker import transcript_sources as _worker_transcript_sources
from worker_test_support import *
from worker_test_fake_llm import *
from worker_test_fake_ads import *
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import transcript_sources as _worker_transcript_sources

class AdCorpusScoringTests(unittest.TestCase):
    """The scorer that measures the detector against hand-labelled episodes.

    These stay dependency-free like the rest of this suite: the scorer is pure,
    so the tests hand it spans directly rather than reaching for the library
    database or the model.
    """

    def setUp(self):
        self.corpus = load_ad_corpus()

    def case(self, *expected, duration=3600.0):
        return {"id": "case", "show": "Show", "expected": list(expected),
                "audioDurationSeconds": duration}

    def expect(self, label, start, end):
        return {"label": label, "start": start, "end": end, "why": "test"}

    def score(self, case, cuts):
        spans = [self.corpus.Span(start, end) for start, end in cuts]
        return self.corpus.score_case(case, spans)

    def test_removing_programme_content_fails_the_case(self):
        verdict = self.score(self.case(self.expect("must-keep", 30.0, 60.0)), [(0.0, 50.0)])
        self.assertFalse(verdict.passed)
        self.assertIn("20.0s of programme", verdict.reason)

    def test_a_boundary_landing_a_hair_inside_the_programme_is_forgiven(self):
        # A cut lands on a transcript segment edge and the truth was read off
        # those same edges, so sub-second slop is rounding, not a defect.
        verdict = self.score(self.case(self.expect("must-keep", 30.0, 60.0)), [(0.0, 30.9)])
        self.assertTrue(verdict.passed)

    def test_an_advertisement_left_whole_fails_the_case(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 32.0)), [(100.0, 200.0)])
        self.assertFalse(verdict.passed)
        self.assertIn("left 32.0s of advertising", verdict.reason)

    def test_an_advertisement_missing_only_its_last_breath_still_passes(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 32.0)), [(0.0, 31.0)])
        self.assertTrue(verdict.passed)

    def test_a_second_missed_at_each_end_is_rounding_and_three_seconds_is_not(self):
        # Both boundaries land on cue edges and both can round, so the slack is
        # per edge. Past it the listener is hearing advertising, which is the
        # thing being measured.
        case = self.case(self.expect("must-cut", 0.0, 32.0))
        self.assertTrue(self.score(case, [(1.0, 31.0)]).passed)
        self.assertFalse(self.score(case, [(1.5, 30.5)]).passed)

    def test_a_label_running_past_the_end_of_the_audio_is_scored_where_it_exists(self):
        # Waveform's closing break is labelled 2.5s beyond the end of its own
        # file: the transcript's last cue outruns the probed duration. Counting
        # seconds the file does not contain as advertising left playing would
        # measure the transcript rather than the cut.
        case = self.case(self.expect("must-cut", 90.0, 105.0), duration=100.0)
        self.assertTrue(self.score(case, [(90.0, 100.0)]).passed)

    def test_an_advertisement_barely_clipped_does_not_count_as_removed(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 32.0)), [(0.0, 8.0)])
        self.assertFalse(verdict.passed)

    def test_an_acceptable_cut_passes_whether_it_is_taken_or_left(self):
        expected = self.expect("acceptable-cut", 0.0, 26.0)
        self.assertTrue(self.score(self.case(expected), [(0.0, 26.0)]).passed)
        self.assertTrue(self.score(self.case(expected), []).passed)

    def test_an_unknown_label_is_refused_rather_than_silently_passed(self):
        with self.assertRaises(ValueError):
            self.score(self.case(self.expect("probably-fine", 0.0, 10.0)), [])

    def test_overlapping_cuts_score_exactly_as_their_union_does(self):
        # The detector nominates a span and a recovery pass widens it; two
        # cuts covering one advertisement is the normal shape of a result.
        # Summing them reported a ten-second spot as sixteen seconds removed.
        case = self.case(
            self.expect("must-cut", 0.0, 10.0),
            self.expect("must-keep", 10.0, 600.0),
        )
        overlapping = self.score(case, [(0.0, 6.0), (3.0, 10.0), (3.0, 10.0), (12.0, 20.0)])
        union = self.score(case, [(0.0, 10.0), (12.0, 20.0)])
        self.assertEqual([span.overlap_seconds for span in overlapping.spans],
                         [span.overlap_seconds for span in union.spans])
        self.assertEqual(overlapping.keep_loss_seconds, union.keep_loss_seconds)
        self.assertEqual(overlapping.unknown_cut_seconds, union.unknown_cut_seconds)
        self.assertEqual(overlapping.passed, union.passed)

    def test_duplicate_cuts_cannot_report_more_of_a_spot_than_there_is(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 10.0)),
                             [(0.0, 10.0), (0.0, 10.0), (0.0, 10.0)])
        self.assertEqual(verdict.spans[0].overlap_seconds, 10.0)
        self.assertIn("100%", verdict.spans[0].note)

    def test_duplicate_cuts_cannot_hide_programme_loss_either(self):
        # The same arithmetic in the direction that matters more: without the
        # union this reports sixty seconds lost from a thirty-second span,
        # which is a number the episode cannot produce.
        verdict = self.score(self.case(self.expect("must-keep", 30.0, 60.0)),
                             [(30.0, 60.0), (30.0, 60.0)])
        self.assertEqual(verdict.keep_loss_seconds, 30.0)

    def test_a_second_lost_from_every_break_fails_even_though_each_is_forgiven(self):
        # Per-span tolerance is for rounding and forgives it once. Ten spans
        # each losing nine tenths of a second is a sentence gone from every
        # break in the episode, and every one of them passes on its own.
        expected = [self.expect("must-keep", 100.0 * n, 100.0 * n + 50.0) for n in range(1, 11)]
        cuts = [(100.0 * n, 100.0 * n + 0.9) for n in range(1, 11)]
        verdict = self.score(self.case(*expected), cuts)
        self.assertTrue(all(span.passed for span in verdict.spans))
        self.assertFalse(verdict.passed)
        self.assertIn("9.0s of programme across the episode", verdict.reason)

    def test_an_episode_losing_less_than_the_budget_still_passes(self):
        expected = [self.expect("must-keep", 100.0 * n, 100.0 * n + 50.0) for n in range(1, 4)]
        cuts = [(100.0 * n, 100.0 * n + 0.9) for n in range(1, 4)]
        self.assertTrue(self.score(self.case(*expected), cuts).passed)

    def test_an_interval_the_arithmetic_cannot_read_is_named_not_absorbed(self):
        case = self.case(self.expect("must-cut", 0.0, 10.0))
        for cuts, expected in (
            ([(0.0, 10.0), (50.0, 40.0)], "ends at or before it starts"),
            ([(-5.0, 10.0)], "starts before the audio does"),
            ([(4000.0, 4100.0)], "starts after the 3600.0s episode ends"),
            ([(0.0, float("inf"))], "end is not a finite number"),
            ([(float("nan"), 10.0)], "start is not a finite number"),
        ):
            verdict = self.score(case, cuts)
            self.assertFalse(verdict.passed, cuts)
            self.assertIn(expected, verdict.reason)
            # Nothing is scored around it: a malformed cut makes every number
            # after it meaningless, and a clean report off one is the failure.
            self.assertEqual(verdict.spans, [])

    def test_a_cut_ending_past_the_probed_duration_is_still_a_cut(self):
        # The closing review cuts to the end of the file, and the probe and the
        # transcript disagree by a couple of seconds on a real episode. That
        # overhang is normal, not a malformed interval.
        verdict = self.score(self.case(self.expect("must-cut", 3550.0, 3605.0)), [(3550.0, 3605.0)])
        self.assertTrue(verdict.passed)
        self.assertEqual(verdict.unknown_cut_seconds, 0.0)

    def test_cutting_where_nothing_is_labelled_is_reported_rather_than_scored(self):
        case = self.case(self.expect("must-cut", 0.0, 10.0), duration=1000.0)
        verdict = self.score(case, [(0.0, 10.0), (500.0, 560.0)])
        # It passes -- the labels say nothing about 500-560s and the harness
        # will not invent a verdict -- but it says how much went unmeasured.
        self.assertTrue(verdict.passed)
        self.assertEqual(verdict.unknown_cut_seconds, 60.0)
        self.assertAlmostEqual(verdict.labelled_coverage, 0.01)
        self.assertFalse(verdict.coverage_complete)

    def test_a_case_whose_labels_reach_every_cut_is_complete(self):
        verdict = self.score(self.case(self.expect("must-cut", 0.0, 10.0), duration=1000.0),
                             [(0.0, 10.0)])
        self.assertTrue(verdict.coverage_complete)
        self.assertEqual(verdict.unknown_cut_seconds, 0.0)

class AdCorpusManifestTests(unittest.TestCase):
    """The ground truth itself, and what it currently says about the detector."""

    def setUp(self):
        self.corpus = load_ad_corpus()
        self.manifest = self.corpus.load_manifest()

    def find(self, case_id):
        for case in self.manifest["cases"]:
            if case["id"] == case_id:
                return case
        self.fail(f"{case_id} is no longer in the corpus")

    def frozen(self, case):
        return [
            self.corpus.Span(entry["start"], entry["end"]) for entry in case["recorded"]
        ]

    def test_every_labelled_span_is_well_formed_and_inside_its_episode(self):
        for case in self.manifest["cases"]:
            # The labels are read off transcript cue boundaries, and the size
            # guards divide by the audio duration, so the manifest carries both
            # and neither may go missing. The bound is asymmetric because the
            # two numbers drift apart for different reasons. A cue end can
            # round a second or two past the end of the file, so the transcript
            # is allowed barely any headroom over the audio. Audio past the
            # last cue is untranscribed lead-out -- Practical AI closes on five
            # seconds of music the model emits no cue for -- and that can be
            # long without meaning anything is wrong. Both bounds are far below
            # the minutes that separate two different episodes, which is the
            # mistake this is here to catch.
            transcript = case["transcriptEndSeconds"]
            audio = case["audioDurationSeconds"]
            self.assertLessEqual(
                transcript, audio + 5.0,
                f"{case['id']}: the transcript runs past the end of the audio",
            )
            self.assertLessEqual(
                audio - transcript, 60.0,
                f"{case['id']}: the transcript and the audio disagree about the episode length",
            )
            for expected in case["expected"]:
                self.assertIn(expected["label"], self.manifest["labels"], case["id"])
                self.assertLess(expected["start"], expected["end"], case["id"])
                # A label may reach the end of the audio even where no cue
                # does, which is how the untranscribed lead-out gets labelled
                # at all; it may not reach past both.
                self.assertLessEqual(
                    expected["end"], max(transcript, audio) + 1.0, case["id"]
                )
                self.assertTrue(expected["why"].strip(), case["id"])

    def test_waveform_still_leaves_all_three_reported_advertisements_whole(self):
        # A characterisation test, not an aspiration: it records the defect as
        # measured on 2026-09-05 so that fixing the detector breaks this test
        # loudly and forces the record to be updated with the new truth.
        case = self.find("waveform-two-preroll-sponsor-reads")
        verdict = self.corpus.score_case(case, self.frozen(case))
        self.assertFalse(verdict.passed, "the leading-edge miss appears to be fixed; update this test")
        missed = [span for span in verdict.spans if span.label == "must-cut" and not span.passed]
        self.assertEqual(
            [(s.span.start, s.span.end) for s in missed],
            # 4122.76-4162.76 is the Amazon Prime spot, labelled on 2026-09-07
            # after the review named it an evaluation gap. The saved run misses
            # it too; it was simply not being scored before.
            [(0.24, 32.88), (33.52, 66.08), (4066.16, 4122.76), (4122.76, 4162.76)],
        )
        # The three spans it does get right have to survive any fix.
        kept = [span for span in verdict.spans if span.label == "must-cut" and span.passed]
        self.assertEqual(len(kept), 3)

    def test_pop_culture_happy_hour_still_loses_the_episode_premise(self):
        case = self.find("pchh-preroll-swallowed-the-premise")
        verdict = self.corpus.score_case(case, self.frozen(case))
        self.assertFalse(verdict.passed, "the overreach appears to be fixed; update this test")
        lost = [span for span in verdict.spans if span.label == "must-keep" and not span.passed]
        self.assertEqual(len(lost), 1)
        self.assertAlmostEqual(lost[0].overlap_seconds, 20.32, places=2)

    def test_practical_ai_still_leaves_both_host_reads_whole(self):
        # The same shape as the Waveform characterisation: it records what the
        # 2026-09-08 run actually did, so a detector fix breaks this loudly.
        # Both misses are host reads that open without a break of any kind,
        # which is the condition this case exists to measure.
        case = self.find("practical-ai-two-host-reads-left-whole")
        verdict = self.corpus.score_case(case, self.frozen(case))
        self.assertFalse(verdict.passed, "the host reads appear to be caught; update this test")
        missed = [span for span in verdict.spans if span.label == "must-cut" and not span.passed]
        self.assertEqual(
            [(s.span.start, s.span.end) for s in missed],
            [(1117.52, 1186.92), (1898.84, 1959.36)],
        )
        # Nothing was cut outside the closing credit, so the failure is purely
        # what was left in. If a fix starts losing programme here, the aggregate
        # budget below is what will say so.
        self.assertEqual(verdict.keep_loss_seconds, 0.0)
        self.assertTrue(verdict.coverage_complete, verdict.unknown_cut_seconds)

    def test_every_case_says_who_labelled_it_and_against_which_input(self):
        # A label with no provenance is an assertion, and this corpus is the
        # thing a detector fix is accepted against. Owner and analyst being one
        # person is a real limit of it, so the manifest has to say so rather
        # than leave the reader to assume independence.
        for case in self.manifest["cases"]:
            provenance = case.get("provenance")
            self.assertIsInstance(provenance, dict, case["id"])
            for key in ("labelledBy", "labelledOn", "inputIdentity", "labelSource"):
                self.assertTrue(str(provenance.get(key, "")).strip(), f"{case['id']}: {key}")
            self.assertIn(case["sttModel"], provenance["inputIdentity"], case["id"])

    def test_labelled_spans_within_a_case_never_overlap_each_other(self):
        # The aggregate programme-loss budget adds up per-span losses, so two
        # `must-keep` labels covering the same second would count it twice.
        for case in self.manifest["cases"]:
            spans = sorted((e["start"], e["end"]) for e in case["expected"])
            for (_, first_end), (second_start, _) in zip(spans, spans[1:]):
                self.assertLessEqual(first_end, second_start, case["id"])

    def test_reviewed_incidents_with_no_case_are_inventoried_rather_than_invented(self):
        # Thirteen historical failures were reviewed and two of them have
        # fixtures. The rest are not silently absent: where the input or the
        # label is gone, the manifest records what is missing and what would
        # close it, because a corpus that lists only what it happens to hold
        # reads as a corpus that covers everything.
        gaps = self.manifest.get("gaps")
        self.assertIsInstance(gaps, list)
        self.assertTrue(gaps)
        case_ids = {case["id"] for case in self.manifest["cases"]}
        for gap in gaps:
            for key in ("id", "show", "kind", "reported", "missing", "closes"):
                self.assertTrue(str(gap.get(key, "")).strip(), f"{gap.get('id')}: {key}")
            self.assertNotIn(gap["id"], case_ids)
            # `runtime` and `policy` gaps have no labelled audio that could
            # express them; saying which kind each is stops the inventory
            # reading as a list of unfixed detector defects.
            self.assertIn(gap["kind"], {"judgement", "runtime", "policy"})
        self.assertEqual(len(gaps), len({gap["id"] for gap in gaps}))

    def test_no_gap_claims_an_input_a_case_already_carries(self):
        # A gap whose input is present is not a gap, it is an unwritten case.
        hashes = {case["sourceHash"] for case in self.manifest["cases"]}
        for gap in self.manifest["gaps"]:
            for source_hash in hashes:
                self.assertNotIn(source_hash, gap["missing"], gap["id"])

    def test_recorded_runs_reproduce_two_of_the_labelled_pods(self):
        # The pod measurement Task 5.3 asks for, as far as the manifest can
        # carry it: a labelled pod is a maximal run of adjacent `must-cut`
        # labels, and this counts how many of them a recorded span reproduces
        # end to end. It is a measurement against the `recorded` field, not the
        # bracketing recovery's own hit rate -- the manifest does not attribute
        # a recorded span to the pass that produced it, and the recovery runs
        # only inside a replay on the host, which this container cannot run.
        pods = []
        reproduced = []
        for case in self.manifest["cases"]:
            case_pods = []
            for expected in sorted(case["expected"], key=lambda entry: entry["start"]):
                if expected["label"] != "must-cut":
                    continue
                if case_pods and expected["start"] <= case_pods[-1][1] + 0.001:
                    case_pods[-1] = (case_pods[-1][0], expected["end"])
                else:
                    case_pods.append((expected["start"], expected["end"]))
            recorded = [(entry["start"], entry["end"]) for entry in case["recorded"]]
            for pod in case_pods:
                pods.append((case["id"], *pod))
                if any(
                    abs(start - pod[0]) <= 0.01 and abs(end - pod[1]) <= 0.01
                    for start, end in recorded
                ):
                    reproduced.append((case["id"], *pod))
        # Fourteen labelled pods across six cases as of 2026-09-23. The count is a
        # tripwire for a case being added or relabelled without anyone rereading
        # this measurement. The Planet Money case added four pods; its recorded
        # run reproduced the three it cut and missed the mid-roll pod it left whole.
        # The TechCrunch Alexa case added two and reproduced neither: its opening
        # cut ran on through three headlines and its closing cut started late.
        self.assertEqual(len(pods), 14)
        self.assertEqual(
            [(round(start, 2), round(end, 2)) for _case_id, start, end in reproduced],
            [(2729.8, 2917.96), (5278.64, 5339.76),
             (0.0, 17.2), (262.08, 310.96), (1694.88, 1732.88)],
        )

    def test_recorded_confidence_does_not_rank_a_wrong_cut_below_a_right_one(self):
        # Reread 2026-09-23 when the TechCrunch Alexa case landed. Every run
        # recorded before 2026-09-19 comes back at 1.0 throughout, including
        # spans wrong in each direction. The one run recorded after the detector
        # began grading confidence reports 0.9 for the span that removed 108s of
        # programme and 0.7667 for the one that was right as far as it went, so
        # nothing in the app can yet use confidence to decide anything.
        graded = {}
        for case in self.manifest["cases"]:
            values = sorted({entry["confidence"] for entry in case["recorded"]} - {1.0})
            if values:
                graded[case["id"]] = values
        self.assertEqual(graded, {"techcrunch-alexa-postroll-left-its-opening": [0.7667, 0.9]})

    def test_every_remaining_gap_names_the_input_that_would_close_it(self):
        # The inventory is only actionable if a reader knows what to go and
        # find. Every judgement gap either names the retained artifact by its
        # source hash or says plainly that no specific input can be named,
        # which is what keeps a reader from going to look for something the
        # manifest never identifies; every runtime gap says no corpus input
        # can, because the defect is not a judgement on audio.
        judgement = [gap for gap in self.manifest["gaps"] if gap["kind"] == "judgement"]
        self.assertTrue(judgement)
        named = {
            gap["id"] for gap in judgement
            if "sha256:" in gap["closes"] + " " + gap["missing"]
        }
        unnamed = {
            gap["id"] for gap in judgement
            if "no specific input can be named" in gap["closes"] + " " + gap["missing"]
        }
        every_gap = {gap["id"] for gap in judgement}
        self.assertEqual(
            named | unnamed, every_gap,
            "every judgement gap must name a source hash or say no specific input can be named",
        )
        self.assertEqual(
            named & unnamed, set(),
            "a gap that names a hash does not also claim no input can be named",
        )
        self.assertIn("daily-chase-sapphire-sparse-spot", named)
        self.assertIn("smartless-steve-zahn-brought-to-you-in-part-by", named)
        runtime = [gap for gap in self.manifest["gaps"] if gap["kind"] == "runtime"]
        self.assertTrue(runtime)
        for gap in runtime:
            self.assertIn(
                "No corpus input closes it", gap["closes"],
                f"{gap['id']}: a runtime gap must say why no input closes it",
            )

    def test_a_retained_input_without_programme_labels_stays_out_of_the_corpus(self):
        # The one gap whose input is retained. It still cannot become a case
        # yet: a must-cut-only case would score a detector that cut the whole
        # episode as perfect, so the case enters only once its must-keep spans
        # are hand-timed against the cache entry.
        retained_hash = "sha256:3a1051fa9b3c5c2bc85e450a3cd9cf150270d0a9859a3b9a38265a5e56c44961"
        gap = next(g for g in self.manifest["gaps"] if g["id"] == "daily-chase-sapphire-sparse-spot")
        self.assertIn(retained_hash, gap["missing"])
        self.assertIn("must-cut and no must-keep", gap["missing"])
        self.assertIn("whole episode", gap["missing"])
        self.assertIn(retained_hash, gap["closes"])
        self.assertNotIn(retained_hash, {case["sourceHash"] for case in self.manifest["cases"]})
        self.assertNotIn(gap["id"], {case["id"] for case in self.manifest["cases"]})

    def test_no_case_can_score_whole_episode_deletion_as_perfect(self):
        # The manifest's own warning, turned into a guard: every case that
        # carries a must-cut span must also carry at least one must-keep span,
        # or a detector that removed the whole episode would pass it.
        for case in self.manifest["cases"]:
            labels = {entry["label"] for entry in case["expected"]}
            if "must-cut" in labels:
                self.assertIn(
                    "must-keep", labels,
                    f"{case['id']}: a must-cut-only case scores whole-episode deletion as perfect",
                )

    def test_the_manifest_pins_inputs_and_records_the_eviction(self):
        # The three original cases' transcripts were evicted from the
        # preparation cache, and the manifest has to say so: the cache is a
        # working set for preparation, and a case's input must be pinned rather
        # than left in it.
        decisions = {decision["id"]: decision for decision in self.manifest["decisions"]}
        decision = decisions["corpus-inputs-are-pinned-not-cached"]
        self.assertIn("pinned", decision["decision"].lower())
        self.assertIn("preparation cache", decision["decision"])
        self.assertIn("adcorpus-inputs", decision["applies"])
        self.assertIn("evicted", decision["context"])
        # The statement names the inputs that were actually evicted. A case
        # whose input survives is not one of them -- the TechCrunch case exists
        # because its preparation failed at the encoder before overwriting the
        # download -- so requiring every case's hash here would force a true
        # sentence to be padded with a false one.
        evicted = [
            case for case in self.manifest["cases"]
            if case["sourceHash"] in decision["context"]
        ]
        self.assertGreaterEqual(len(evicted), 3, "the three evicted inputs must be named")
        for case in evicted:
            self.assertIn(
                case["sourceHash"], decision["context"],
                f"{case['id']}: the eviction statement must name its input",
            )
