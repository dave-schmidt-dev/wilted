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

class AdCorpusInputStoreTests(unittest.TestCase):
    """The corpus's own copy of a case's input, and the adoption that fills it.

    The aligned-STT cache is a 32-entry LRU working set for preparation, not a
    corpus store: all three original cases' inputs were evicted from it and the
    2026-09-17 replay returned 0/3 with "no cached transcript". These tests pin
    the resolution order (pinned first, cache second), the distinct verdict for
    a case with no input anywhere, and the adopt command that moves a cache
    snapshot into the store.
    """

    def setUp(self):
        self.corpus = load_ad_corpus()
        self.cases = {case["id"]: case for case in self.corpus.load_manifest()["cases"]}
        self.waveform = self.cases["waveform-two-preroll-sponsor-reads"]
        self.pchh = self.cases["pchh-preroll-swallowed-the-premise"]
        self.practical = self.cases["practical-ai-two-host-reads-left-whole"]

    def entry(self, case, *, text="cue"):
        return json.dumps({
            "sourceHash": case["sourceHash"],
            "segments": [{"text": text, "start_s": 0.0, "end_s": 1.0}],
        })

    def directory(self, name):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        return root / name

    def test_the_boundary_set_still_resolves_through_the_cache_when_unpinned(self):
        # Nothing adopted here: the fallback keeps an existing machine working,
        # which is what makes landing the pinned store safe before the host has
        # run the adoption.
        cache = self.directory("cache")
        cache.mkdir()
        (cache / "entry.json").write_text(self.entry(self.waveform, text="from the cache"))
        store = self.directory("adcorpus-inputs")
        segments, source = self.corpus.case_segments(self.waveform, store=store, cache=cache)
        self.assertEqual([segment["text"] for segment in segments], ["from the cache"])
        self.assertEqual(source, "cache")

    def test_the_pinned_store_is_read_before_the_cache(self):
        cache = self.directory("cache")
        cache.mkdir()
        (cache / "entry.json").write_text(self.entry(self.waveform, text="from the cache"))
        store = self.directory("adcorpus-inputs")
        store.mkdir()
        (store / self.corpus._pinned_input_name(self.waveform["sourceHash"])).write_text(
            self.entry(self.waveform, text="pinned")
        )

        segments, source = self.corpus.case_segments(self.waveform, store=store, cache=cache)
        self.assertEqual([segment["text"] for segment in segments], ["pinned"])
        self.assertEqual(source, "pinned")

        (store / self.corpus._pinned_input_name(self.waveform["sourceHash"])).unlink()
        segments, source = self.corpus.case_segments(self.waveform, store=store, cache=cache)
        self.assertEqual([segment["text"] for segment in segments], ["from the cache"])
        self.assertEqual(source, "cache")

        (cache / "entry.json").unlink()
        self.assertEqual(
            self.corpus.case_segments(self.waveform, store=store, cache=cache),
            (None, None),
        )

    def test_a_case_with_input_in_neither_store_is_unrunnable_not_badly_scored(self):
        # Two cases, one verdict each: a case that could not run and a case
        # that ran and lost programme are different failures wanting different
        # responses, and strict mode must not flatten them into one FAIL.
        manifest = self.directory("manifest.json")
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({"cases": [self.waveform, self.pchh]}))

        def replay(case, *, cache, store):
            if case["id"] == self.waveform["id"]:
                return None
            # Ten seconds inside PCHH's must-keep run: it ran, and it scored
            # badly.
            return ([self.corpus.Span(40.0, 50.0)], {"modelRequests": 1})

        with mock.patch.object(self.corpus, "replay_spans", replay), \
                redirect_stderr(io.StringIO()):
            results = self.corpus.run(
                "replay", library=Path("/nowhere"), cache=Path("/nowhere"),
                store=Path("/nowhere"), manifest=manifest, strict=True,
            )
        missing = next(result for result in results if result.case_id == self.waveform["id"])
        scored = next(result for result in results if result.case_id == self.pchh["id"])
        self.assertTrue(missing.unrunnable)
        self.assertFalse(missing.skipped)
        self.assertIn("unrunnable", missing.reason)
        self.assertFalse(scored.unrunnable)
        self.assertFalse(scored.skipped)
        self.assertFalse(scored.passed)
        self.assertIn("lost", scored.reason)
        self.assertNotIn("unrunnable", scored.reason)

    def test_adopt_copies_manifest_named_entries_and_names_the_unsatisfied_cases(self):
        source = self.directory("snapshot")
        source.mkdir()
        (source / "one.json").write_text(self.entry(self.waveform, text="pinned"))
        (source / "unrelated.json").write_text(json.dumps({
            "sourceHash": "sha256:not-in-the-manifest",
            "segments": [{"text": "other", "start_s": 0.0, "end_s": 1.0}],
        }))
        # A manifest case with no segments is not an input, so it stays
        # unsatisfied rather than being pinned empty.
        (source / "empty.json").write_text(json.dumps({
            "sourceHash": self.pchh["sourceHash"], "segments": [],
        }))
        store = self.directory("adcorpus-inputs")

        adopted, unsatisfied = self.corpus.adopt(source, store=store)
        self.assertEqual([case_id for case_id, _ in adopted], [self.waveform["id"]])
        pinned = store / self.corpus._pinned_input_name(self.waveform["sourceHash"])
        self.assertTrue(pinned.is_file())
        self.assertEqual(json.loads(pinned.read_text())["segments"][0]["text"], "pinned")
        self.assertEqual(
            unsatisfied,
            [case["id"] for case in self.cases.values() if case["id"] != self.waveform["id"]],
            "every case this source does not supply is named, not just the original three",
        )

        stdout = io.StringIO()
        with redirect_stdout(stdout):
            code = self.corpus.main(["--adopt", str(source), "--store", str(store)])
        self.assertEqual(code, 1, "a partial adoption must not exit clean")
        report = stdout.getvalue()
        self.assertIn(f"adopted  {self.waveform['id']}", report)
        self.assertIn(f"unsatisfied  {self.pchh['id']}", report)
        self.assertIn(f"unsatisfied  {self.practical['id']}", report)

        # A source holding every case adopts cleanly.
        complete = self.directory("complete")
        complete.mkdir()
        for case in self.cases.values():
            (complete / f"{case['id']}.json").write_text(self.entry(case))
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            code = self.corpus.main(["--adopt", str(complete), "--store", str(store)])
        self.assertEqual(code, 0)
        summary = [line for line in stdout.getvalue().splitlines()
                   if line.startswith("ad-corpus:")]
        self.assertEqual(summary, [
            f"ad-corpus: adopted {len(self.cases)} case input(s), 0 unsatisfied; store {store}"
        ])
        self.assertNotIn("unsatisfied  ", stdout.getvalue())

    def test_adopt_pins_acquired_gap_inputs_without_making_them_cases(self):
        acquired_hash = "sha256:acquired-gap-input"
        gap_id = "weekly-show-five-sponsor-spots-survived"
        manifest = self.directory("manifest.json")
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({
            "cases": [self.waveform, self.pchh],
            "gaps": [
                {"id": gap_id, "acquiredInputs": [{"sourceHash": acquired_hash}]},
                {"id": "gap-without-acquired-inputs"},
            ],
        }))
        source = self.directory("snapshot")
        source.mkdir()
        (source / "gap.json").write_text(json.dumps({
            "sourceHash": acquired_hash,
            "segments": [{"text": "gap input", "start_s": 0.0, "end_s": 1.0}],
        }))
        (source / "unrelated.json").write_text(json.dumps({
            "sourceHash": "sha256:not-in-the-manifest",
            "segments": [{"text": "other", "start_s": 0.0, "end_s": 1.0}],
        }))
        store = self.directory("adcorpus-inputs")

        adopted, unsatisfied = self.corpus.adopt(source, store=store, manifest=manifest)

        self.assertEqual([entry_id for entry_id, _ in adopted], [gap_id])
        self.assertTrue((store / self.corpus._pinned_input_name(acquired_hash)).is_file())
        self.assertFalse((store / self.corpus._pinned_input_name("sha256:not-in-the-manifest")).exists())
        self.assertEqual(unsatisfied, [self.waveform["id"], self.pchh["id"]])

    def test_the_store_lives_outside_the_repository_and_is_gitignored(self):
        root = Path(__file__).resolve().parents[2]
        store = self.corpus.DEFAULT_AD_CORPUS_INPUTS
        self.assertTrue(str(store).endswith("adcorpus-inputs"))
        self.assertNotIn(str(root), str(store), "transcripts never live inside the repository")
        ignore = (root / ".gitignore").read_text(encoding="utf-8")
        self.assertIn("adcorpus-inputs/", ignore)
        self.assertIn("Producer/Workers/adcorpus/inputs/", ignore)
        # No transcript JSON is committed under the corpus directory.
        corpus_directory = root / "Producer" / "Workers" / "adcorpus"
        self.assertFalse((corpus_directory / "inputs").exists())
        for path in corpus_directory.glob("*.json"):
            self.assertNotIn('"segments"', path.read_text(encoding="utf-8"),
                             f"{path} looks like transcript content")

    def test_the_summary_counts_an_unrunnable_case_apart_from_a_failure(self):
        # "0/3 cases pass" on a corpus that never ran reads as a detector
        # regression and sends the reader to the detector. The pass ratio is
        # therefore over the cases that actually measured something.
        unrunnable = self.corpus.CaseVerdict(
            case_id="waveform-two-preroll-sponsor-reads", show="Waveform",
            passed=False, reason="unrunnable: no pinned input", unrunnable=True,
        )
        summary = self.corpus.report([unrunnable]).splitlines()[-1]
        self.assertIn("0/0 measured cases pass", summary)
        self.assertIn("1 unrunnable for want of input", summary)
        self.assertIn("0 scored only in part", summary)

    def test_a_measured_failure_still_counts_against_the_pass_ratio(self):
        failed = self.corpus.CaseVerdict(
            case_id="pchh-preroll-swallowed-the-premise", show="Pop Culture Happy Hour",
            passed=False, reason="20.0s of programme removed",
        )
        passed = self.corpus.CaseVerdict(
            case_id="practical-ai-two-host-reads-left-whole", show="Practical AI",
            passed=True, reason="every labelled span is where it should be",
        )
        summary = self.corpus.report([failed, passed]).splitlines()[-1]
        self.assertIn("1/2 measured cases pass", summary)
        self.assertIn("0 unrunnable for want of input", summary)
