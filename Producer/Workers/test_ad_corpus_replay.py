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

class AdCorpusReplayWiringTests(unittest.TestCase):
    """The replay path, with the model stubbed out.

    Replay is the tool a detector fix will be measured with, and it only runs
    for real behind a four-gigabyte model, so nothing else in the gate reaches
    it. These tests stand in for `wilted.llm` and check that a replay hands the
    shared analysis entry what a real preparation hands it -- the same segment
    type, the same duration, inside the same capability -- and that a refusal
    from it lands against the case that provoked it.

    The judgement itself, and the order of the recovery passes around it, are
    `analyze_ad_detections`' contract and are tested where they live. That is
    the point of the change these tests describe: the replay used to assemble
    that sequence itself, so it could drift from the app one edit at a time,
    and it had -- it was missing the coverage refusals and the dropped-anchor
    audit, and could score a run the app would have refused outright.
    """

    def setUp(self):
        self.corpus = load_ad_corpus()
        self.calls = []
        self.addCleanup(self.restore_modules, dict(sys.modules))

    def restore_modules(self, snapshot):
        for name in [n for n in sys.modules if n.startswith("wilted.") or n == "wilted"]:
            if name not in snapshot:
                del sys.modules[name]

    def cache_for(self, case, *, segments=None):
        """A cache directory holding exactly this case's entry.

        Keyed by `sourceHash` the way the real one is, so `cached_segments`
        finds it by the same match. Built rather than borrowed: the local
        aligned-STT cache is mutable state that another machine does not have,
        and a wiring test that skips itself there proves nothing in the gate.
        """
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        count = case["segmentCount"] if segments is None else segments
        step = float(case["audioDurationSeconds"]) / count
        (root / "entry.json").write_text(json.dumps({
            "sourceHash": case["sourceHash"],
            "segments": [
                {"text": f"cue {index}", "start_s": index * step, "end_s": (index + 1) * step}
                for index in range(count)
            ],
        }))
        return root

    def empty_store(self):
        """A pinned store that does not exist, so the cache is the only input.

        The mounted host may have adopted the real store; a wiring test that
        silently read it would be measuring the host's copy instead of its own
        fixture.
        """
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        return root / "adcorpus-inputs"

    def pinned_store_for(self, case, *, text):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, True)
        store = root / "adcorpus-inputs"
        store.mkdir()
        (store / "entry.json").write_text(json.dumps({
            "sourceHash": case["sourceHash"],
            "segments": [{"text": text, "start_s": 0.0, "end_s": 1.0}],
        }))
        return store

    def install_stubs(self, detections=(), analyze=None):
        class Ad:
            def __init__(self, start_s, end_s, confidence=1.0, label="ad_break", kinds=()):
                self.start_s, self.end_s = start_s, end_s
                self.confidence, self.label = confidence, label
                self.kinds = kinds

        calls = self.calls
        ads = types.ModuleType("wilted.ads")
        attach_ad_kind_taxonomy(ads)
        ads.AdSegment = Ad
        # The classifier contract `AuditingBackend` refuses to run without.
        # Only the live path builds one before handing it over, but the stub
        # has to satisfy it for the parity test below to reach the same call.
        ads._AD_DETECT_SYSTEM_PROMPT = "classify"
        ads._AD_DETECT_CORRECTION_PROMPT = "correct"
        ads._AD_DETECT_RESPONSE_FORMAT = {"type": "json_object"}
        ads._parse_ad_response = lambda response, expected_ids: []

        class Backend:
            def load(inner):
                calls.append(("load",))

            def close(inner):
                calls.append(("close",))

        llm = types.ModuleType("wilted.llm")
        llm.DEFAULT_GGUF_MODEL = "/models/stand-in.gguf"
        llm.create_backend = lambda kind, model: (
            calls.append(("create_backend", kind, model)) or Backend()
        )
        # The runtime will not build a model outside this, and the worker claims
        # it in `main` rather than in any pass, so a replay importing the passes
        # directly gets no capability unless it claims one itself.
        @contextmanager
        def capability_scope(*, owner_id, data_dir):
            calls.append(("capability", owner_id, str(data_dir)))
            try:
                yield object()
            finally:
                calls.append(("capability_released",))

        capability = types.ModuleType("wilted.execution_capability")
        capability.execution_capability_scope = capability_scope

        package = types.ModuleType("wilted")
        package.ads, package.llm = ads, llm
        package.execution_capability = capability
        sys.modules.update({"wilted": package, "wilted.ads": ads, "wilted.llm": llm,
                            "wilted.execution_capability": capability})
        self.use_runtime(self.fake_runtime())

        def recorder(ads_module, backend, segments, total, **kwargs):
            calls.append(("analyze", segments, total, backend, ads_module))
            if analyze is not None:
                return analyze()
            return wp.AdAnalysis(tuple(Ad(*span) for span in detections), wp.AdAnalysisAudit())

        self.patch("analyze_ad_detections", recorder)
        self.patch("prepare_ad_model_lock", lambda *_a, **_k: None)

    def fake_runtime(self):
        """A directory shaped like the runtime, for the existence check to find.

        `sys.modules` already holds the stub package, so the import itself would
        succeed anywhere; the check that runs before it is what needs a path.
        """
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root, True)
        (Path(root) / "wilted").mkdir()
        (Path(root) / "wilted" / "ads.py").write_text("")
        return root

    def use_runtime(self, path):
        patcher = mock.patch.dict(os.environ, {"WILTED_PIPELINE_PYTHONPATH": str(path)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_runtime_is_resolved_the_way_the_app_resolves_it(self):
        # Swift hands the worker a PYTHONPATH from this variable with this
        # fallback. A replay resolving it any other way would be measuring a
        # different detector than the one the app runs.
        self.use_runtime("/tmp/somewhere-else/src")
        self.assertEqual(self.corpus.runtime_sources(), Path("/tmp/somewhere-else/src"))
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(self.corpus.runtime_sources(), self.corpus.DEFAULT_RUNTIME_SOURCES)
        self.assertTrue(str(self.corpus.DEFAULT_RUNTIME_SOURCES).endswith("wilted/Producer/Runtime/src"))
        self.assertNotIn("wilted-old", str(self.corpus.DEFAULT_RUNTIME_SOURCES))

    def test_missing_runtime_source_is_named_rather_than_left_as_an_import_error(self):
        # Nothing in the worker puts the runtime on the path -- Swift does it
        # from outside -- so a replay run from a shell finds it or explains why.
        case = self.waveform()
        cache = self.cache_for(case)
        self.install_stubs()
        empty = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, empty, True)
        self.use_runtime(empty)
        with self.assertRaises(RuntimeError) as caught:
            self.corpus.replay_spans(case, cache=cache, store=self.empty_store())
        self.assertIn(empty, str(caught.exception))
        self.assertIn("restore Producer/Runtime/src", str(caught.exception))
        self.assertIn("WILTED_PIPELINE_PYTHONPATH", str(caught.exception))

    def patch(self, name, replacement):
        """`mock.patch.object` in the form the system interpreter supports.

        This leg runs under whatever `python3` is first on PATH, which on this
        host is 3.9 outside the gate, so `TestCase.enterContext` is not
        available.
        """
        patcher = mock.patch.object(wp, name, replacement)
        patcher.start()
        self.addCleanup(patcher.stop)

    def waveform(self):
        for case in self.corpus.load_manifest()["cases"]:
            if case["id"] == "waveform-two-preroll-sponsor-reads":
                return case
        self.fail("the Waveform case is no longer in the corpus")

    def replay(self, case, detections=(), analyze=None, cache=None, store=None):
        cache = cache if cache is not None else self.cache_for(case)
        store = store if store is not None else self.empty_store()
        self.install_stubs(detections, analyze)
        return self.corpus.replay_spans(case, cache=cache, store=store)

    def analyzed(self):
        return next(call for call in self.calls if call[0] == "analyze")

    def test_a_replay_reproduces_the_worker_call_for_call(self):
        case = self.waveform()
        spans, audit = self.replay(case, detections=[(100.0, 200.0)])
        names = [call[0] for call in self.calls]
        self.assertEqual(names, [
            "capability", "create_backend", "load", "analyze", "close", "capability_released",
        ])
        self.assertEqual([(span.start, span.end) for span in spans], [(100.0, 200.0)])
        # The same evidence a live analysis publishes, so a corpus verdict can
        # be trusted or distrusted on the same grounds as a preparation.
        self.assertIn("modelRequests", audit)

    def test_a_replay_reads_the_pinned_store_before_the_preparation_cache(self):
        # Through `replay_spans`, not just the resolver: the segments the
        # detector is handed are the proof that the pinned copy was the input.
        case = self.waveform()
        cache = self.cache_for(case, segments=2)
        store = self.pinned_store_for(case, text="pinned")
        self.replay(case, detections=[(1.0, 2.0)], cache=cache, store=store)
        _, segments, _, _, _ = self.analyzed()
        self.assertEqual([segment.text for segment in segments], ["pinned"])

        # With the pinned copy gone the cache answers, exactly as before.
        (store / "entry.json").unlink()
        self.calls.clear()
        self.replay(case, detections=[(1.0, 2.0)], cache=cache, store=store)
        _, segments, _, _, _ = self.analyzed()
        self.assertEqual([segment.text for segment in segments], ["cue 0", "cue 1"])

    def test_a_replay_and_a_preparation_make_the_same_analysis_call(self):
        # The whole point of the shared entry: if these two ever diverge, the
        # corpus is measuring a detector the app does not run, which is the
        # defect this replaced. Driven through `detect_and_cut` rather than
        # asserted by reading the two, because the divergence that happened
        # before was invisible to anyone reading either one on its own -- both
        # looked right, and the replay was quietly missing the coverage
        # refusals and the dropped-anchor audit.
        case = self.waveform()
        self.replay(case)
        replay_call = self.analyzed()

        self.calls.clear()
        segments = list(replay_call[1])
        with mock.patch.object(_worker_cue_timing, "probe_duration", lambda _path: replay_call[2]), \
                mock.patch.object(_worker_gpu_admission, "prepare_ad_model_lock", lambda *_a, **_k: None), \
                mock.patch.object(_worker_ad_removal, "analyze_ad_detections", wp.analyze_ad_detections), \
                redirect_stderr(io.StringIO()):
            wp.detect_and_cut({}, Path("/nowhere/in.m4a"), [], segments)
        live_call = self.analyzed()

        self.assertEqual(live_call[4], replay_call[4], "a different detector module")
        self.assertEqual([(s.start_s, s.end_s, s.text) for s in live_call[1]],
                         [(s.start_s, s.end_s, s.text) for s in replay_call[1]])
        self.assertEqual(live_call[2], replay_call[2])

    def test_a_replay_never_transcribes_anything_a_second_time(self):
        # One Parakeet pass supplies both detection and the displayed
        # transcript, and the corpus exists to measure that exact input. A
        # replay that transcribed again would be scoring a different episode
        # while reporting the case's source hash -- and on a machine where the
        # daemon is not running it would fail rather than measure anything.
        case = self.waveform()

        def refuse(*_args, **_kwargs):
            self.fail("the replay reached speech-to-text")

        with mock.patch.object(_worker_transcript_sources, "transcribe_with_daemon", refuse):
            spans, _ = self.replay(case, detections=[(1.0, 2.0)])
        self.assertEqual([(span.start, span.end) for span in spans], [(1.0, 2.0)])

    def test_a_refusal_is_recorded_against_its_case_rather_than_ending_the_run(self):
        # `ads-classification-unresolved` means the classifier never resolved
        # some cues. Scoring what it did return would be scoring a guess, and
        # crashing the harness would lose every other case's verdict.
        case = self.waveform()
        cache = self.cache_for(case)

        def refuse():
            raise wp.WorkerError("ads-classification-unresolved",
                                 "classifier exhausted normal and corrective retries for global IDs: 7")

        self.install_stubs(analyze=refuse)
        with self.assertRaises(self.corpus.ReplayRefused) as caught:
            self.corpus.replay_spans(case, cache=cache, store=self.empty_store())
        self.assertEqual(caught.exception.code, "ads-classification-unresolved")

        with redirect_stderr(io.StringIO()):
            results = self.corpus.run("replay", library=Path("/nowhere"), cache=cache,
                                      store=self.empty_store(), strict=True)
        refused = next(r for r in results if r.case_id == case["id"])
        self.assertFalse(refused.passed)
        self.assertFalse(refused.skipped)
        self.assertIn("ads-classification-unresolved", refused.reason)
        self.assertEqual(refused.spans, [])

    def test_the_model_is_built_inside_a_claimed_execution_capability(self):
        # The archive gates multi-gigabyte model construction on this, and the
        # worker claims it in `main`. A replay calls the analysis entry
        # directly, so without its own claim `create_backend` raises before any
        # measurement.
        case = self.waveform()
        cache = self.cache_for(case)
        self.replay(case, cache=cache)
        claimed = next(call for call in self.calls if call[0] == "capability")
        self.assertEqual(claimed[1], "wilted-ad-corpus-replay")
        self.assertEqual(claimed[2], str(cache.parent))
        self.assertLess(self.calls.index(claimed),
                        [call[0] for call in self.calls].index("create_backend"))
        self.assertEqual(self.calls[-1][0], "capability_released")

    def test_the_detector_is_handed_the_type_the_worker_hands_it(self):
        # Duck typing makes the archive's own `TranscriptSegment` look
        # interchangeable here. It is not the call the app makes.
        case = self.waveform()
        self.replay(case)
        _, segments, _, _, _ = self.analyzed()
        self.assertEqual(len(segments), case["segmentCount"])
        self.assertEqual(type(segments[0]).__name__, "CachedAlignedSegment")

    def test_the_size_guards_divide_by_the_audio_not_the_transcript(self):
        case = self.waveform()
        self.replay(case)
        self.assertEqual(self.analyzed()[2], case["audioDurationSeconds"])
        self.assertNotEqual(case["audioDurationSeconds"], case["transcriptEndSeconds"])

    def test_a_replay_says_which_case_it_is_working_on(self):
        # A replay spends minutes per case and emits nothing of its own
        # meanwhile: the detector's journal names no case and the report only
        # lands at the end, so two cases running are one interleaved stream
        # nobody can attribute.
        stderr = io.StringIO()
        with mock.patch.object(self.corpus, "replay_spans",
                               lambda case, *, cache, store: None), \
                redirect_stderr(stderr):
            results = self.corpus.run(
                "replay", library=Path("/nowhere"), cache=Path("/nowhere"),
                store=Path("/nowhere"))
        named = [line for line in stderr.getvalue().splitlines()
                 if line.startswith("ad-corpus: replaying ")]
        self.assertEqual(len(named), len(results))
        for verdict, line in zip(results, named):
            self.assertIn(verdict.case_id, line)

    def test_reading_the_library_back_does_not_announce_itself(self):
        # `recorded` is milliseconds a case and prints its report immediately,
        # so the same line there would be noise rather than progress.
        stderr = io.StringIO()
        with mock.patch.object(self.corpus, "recorded_spans", lambda case, *, library: None), \
                redirect_stderr(stderr):
            self.corpus.run("recorded", library=Path("/nowhere"), cache=Path("/nowhere"))
        self.assertNotIn("replaying", stderr.getvalue())

    def test_a_source_hash_no_cache_entry_matches_is_a_skip_not_an_empty_result(self):
        # "Never prepared here" and "the detector found nothing" are opposite
        # readings, and only one of them is a failure.
        case = dict(self.waveform(), sourceHash="sha256:notacachedrun")
        self.install_stubs()
        self.assertIsNone(
            self.corpus.replay_spans(
                case, cache=self.cache_for(self.waveform()), store=self.empty_store()
            )
        )

    def test_a_missing_input_skips_by_default_and_fails_the_candidate_run(self):
        # The mode a fix is judged in cannot let the corpus shrink to whatever
        # this machine happens to hold: two cases becoming one skipped case and
        # one pass exits zero and reads as success.
        empty = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, empty, True)
        store = empty / "adcorpus-inputs"
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            lenient = self.corpus.run("replay", library=Path("/nowhere"), cache=empty, store=store)
            self.assertEqual(self.corpus.main(
                ["--mode", "replay", "--cache", str(empty), "--store", str(store)]), 0)
            strict = self.corpus.run("replay", library=Path("/nowhere"), cache=empty,
                                     store=store, strict=True)
        self.assertTrue(all(r.skipped and r.passed for r in lenient))
        self.assertTrue(strict)
        for verdict in strict:
            self.assertFalse(verdict.passed)
            self.assertFalse(verdict.skipped)
            # The case did not run for want of input; it must not read as one
            # that ran and scored badly.
            self.assertTrue(verdict.unrunnable)
            # Named, not just counted: "something did not run" is not enough to
            # act on when the fix is to pin the missing input.
            self.assertIn("unrunnable", verdict.reason)
            self.assertIn("no pinned input for sha256:", verdict.reason)
            self.assertIn("no cached transcript for sha256:", verdict.reason)
            self.assertIn(str(empty), verdict.reason)
            self.assertIn(str(store), verdict.reason)
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(self.corpus.main(
                ["--mode", "replay", "--cache", str(empty), "--store", str(store), "--strict"]), 1)
