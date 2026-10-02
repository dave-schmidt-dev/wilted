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

class PreflightTests(unittest.TestCase):
    """What the cut needs is checked before speech-to-text starts, not after."""

    def setUp(self):
        self.audio = Path(REPO_ROOT / "Producer" / "Workers" / "test_wilted_pipeline.py")
        self.tools = tempfile.mkdtemp(prefix="wilted-tools.")
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.tools], check=False))
        for tool in wp.CUT_TOOLS:
            path = Path(self.tools) / tool
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        self.default_model = Path(self.tools) / "default.gguf"
        self.default_model.write_bytes(b"GGUF")
        install_fake_wilted()
        install_fake_ads(FakeLLM())
        sys.modules["wilted.llm"].DEFAULT_GGUF_MODEL = str(self.default_model)
        # `run()` swallows a failed speech-to-text tier, so a `self.fail` in
        # the stub would be caught; record the call and assert on it instead.
        self.stt_calls: list = []
        sys.modules["wilted.transcribe"].transcribe_audio = lambda path: self.stt_calls.append(path) or []

    def test_missing_cut_tools_fail_before_any_work(self):
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent-bin"}), redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run({"audioPath": str(self.audio), "removeAds": True})
        self.assertEqual(raised.exception.code, "cut-tools-missing")
        self.assertIn("ffmpeg", str(raised.exception))
        self.assertEqual(self.stt_calls, [], "speech-to-text ran without ffmpeg present")

    def test_a_named_model_that_is_not_on_disk_fails_first(self):
        with mock.patch.dict(os.environ, {"PATH": self.tools}):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.preflight_ad_removal({"llmModel": "/models/absent.gguf"})
        self.assertEqual(raised.exception.code, "ads-model-missing")

    def test_the_default_model_is_checked_when_none_is_named(self):
        self.default_model.unlink()
        with mock.patch.dict(os.environ, {"PATH": self.tools}), redirect_stderr(io.StringIO()):
            with self.assertRaises(wp.WorkerError) as raised:
                wp.run({"audioPath": str(self.audio), "removeAds": True})
        self.assertEqual(raised.exception.code, "ads-model-missing")
        self.assertIn(str(self.default_model), str(raised.exception))
        self.assertEqual(self.stt_calls, [], "speech-to-text ran without a model to detect with")

    def test_present_tools_and_a_present_default_model_pass(self):
        with mock.patch.dict(os.environ, {"PATH": self.tools}):
            wp.preflight_ad_removal({})

    def test_a_hub_spec_is_left_for_the_loader_to_resolve(self):
        with mock.patch.dict(os.environ, {"PATH": self.tools}):
            wp.preflight_ad_removal({"llmModel": "hf:some/repo/model.gguf"})

    def test_skipping_ad_removal_skips_the_preflight(self):
        install_fake_wilted()
        with mock.patch.dict(os.environ, {"PATH": "/nonexistent-bin"}), redirect_stderr(io.StringIO()):
            result = wp.run({"audioPath": str(self.audio), "removeAds": False, "allowSpeechToText": False})
        self.assertTrue(result["ok"])

    def test_the_single_aligned_stt_pass_finishes_before_eviction_and_ad_model_load(self):
        events = []
        transcribe = sys.modules["wilted.transcribe"]
        install_fake_speech_stack(events=events)

        def transcribe_audio(path, model_name="mlx-community/parakeet-tdt-1.1b", **_):
            self.assertEqual(model_name, "mlx-community/parakeet-tdt-1.1b")
            return events.append("aligned") or [FakeSegment(0, 1, "content")]

        llm = FakeLLM()
        original_load = llm.load

        def load():
            events.append("ads.load")
            original_load()

        llm.load = load
        original_close = llm.close

        def close():
            events.append("ads.close")
            original_close()

        llm.close = close
        ads = install_fake_ads(llm)
        original_detect = ads.detect_ads

        def detect(segments, backend):
            events.append("ads.detect")
            return original_detect(segments, backend)

        ads.detect_ads = detect
        with mock.patch.object(transcribe, "transcribe_audio", transcribe_audio), \
                mock.patch.dict(os.environ, {"PATH": self.tools}), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=1.0), redirect_stderr(io.StringIO()):
            wp.run({
                "audioPath": str(self.audio),
                "removeAds": True,
                "llmModel": str(self.default_model),
            })
        self.assertEqual(
            events,
            [
                "aligned",
                "status",
                "ads.load",
                "ads.detect",
                "ads.close",
            ],
        )

    def test_eviction_barrier_reports_before_and_after_fifo_completion(self):
        events = []
        install_fake_speech_stack(events=events, statuses=({"resident_models": 1}, {"resident_models": 0}))
        stream = io.StringIO()
        with mock.patch.object(_worker_gpu_admission.time, "sleep"), redirect_stderr(stream):
            lock = wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True)
            with lock:
                events.append("ads.work")
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertEqual(
            events,
            [
                "status",
                "evict:stt",
                "evict:tts",
                "barrier:echo:wilted-gpu-drained",
                "status",
                "ads.work",
            ],
        )
        self.assertIn("ads.model.release", stages)
        self.assertIn("ads.model.drain", stages)
        self.assertIn("ads.model.retry", stages)

    def test_daemon_unavailable_allows_the_locked_ad_model_lifecycle(self):
        events = []
        client, _ = install_fake_speech_stack(events=events)
        client.status = mock.Mock(side_effect=client.DaemonUnavailable("socket absent"))
        stream = io.StringIO()
        with redirect_stderr(stream):
            lock = wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True)
            with lock:
                events.append("ads.work")
        self.assertEqual(events, ["ads.work"])
        details = [json.loads(line)["detail"] for line in stream.getvalue().splitlines()]
        self.assertIn("speech daemon unavailable; canonical GPU lock is exclusive", details)

    def test_permanent_residency_times_out_and_prevents_ad_model_load(self):
        events = []
        install_fake_speech_stack(events=events, statuses=({"resident_models": 1},))
        transcribe = sys.modules["wilted.transcribe"]
        transcribe.transcribe_audio = lambda path, **_: [FakeSegment(0, 1, "content")]
        llm = FakeLLM()
        llm.load = mock.Mock(wraps=llm.load)
        install_fake_ads(llm)
        def clock():
            return 11.0 if "evict:stt" in events else 0.0

        with mock.patch.dict(os.environ, {"PATH": self.tools}), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=1.0), \
                mock.patch.object(_worker_gpu_admission.time, "monotonic", side_effect=clock), \
                mock.patch.object(_worker_gpu_admission.time, "sleep"), redirect_stderr(io.StringIO()), \
                self.assertRaises(wp.WorkerError) as raised:
            wp.run({
                "audioPath": str(self.audio),
                "removeAds": True,
                "readableTranscript": False,
                "llmModel": str(self.default_model),
            })
        self.assertEqual(raised.exception.code, "ads-model-wait-failed")
        self.assertIn("timed out waiting for exclusive GPU model admission", str(raised.exception))
        self.assertEqual(events, ["status", "evict:stt"])
        llm.load.assert_not_called()

    def test_malformed_residency_status_fails_closed_before_model_load(self):
        events = []
        install_fake_speech_stack(events=events, statuses=({"resident_models": "unknown"},))
        with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError) as raised, \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            with wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True):
                self.fail("unsafe admission must not yield")
        self.assertEqual(raised.exception.code, "ads-model-wait-failed")
        self.assertIn("invalid speech daemon status", str(raised.exception))
        self.assertEqual(events, ["status"])

    def test_published_transcript_locks_before_load_without_stt_eviction(self):
        events = []
        install_fake_wilted({"vtt": [FakeSegment(0, 1, "content")]})
        install_fake_speech_stack(events=events)
        llm = FakeLLM()
        original_load, original_close = llm.load, llm.close
        llm.load = lambda: events.append("ads.load") or original_load()
        llm.close = lambda: events.append("ads.close") or original_close()
        install_fake_ads(llm)
        stream = io.StringIO()
        with mock.patch.dict(os.environ, {"PATH": self.tools}), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=1.0), \
                redirect_stderr(stream):
            result = wp.run({
                "audioPath": str(self.audio),
                "removeAds": True,
                "allowSpeechToText": False,
                "llmModel": str(self.default_model),
                "publishedTranscript": {
                    "body": "WEBVTT",
                    "mediaType": "text/vtt",
                    "url": "https://x.test/a.vtt",
                },
            })
        self.assertTrue(result["ok"])
        self.assertEqual(events, ["status", "ads.load", "ads.close"])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertLess(stages.index("ads.model.wait"), stages.index("ads.model.locked"))
        self.assertLess(stages.index("ads.model.locked"), stages.index("ads.model.load"))

    def test_another_admitted_request_releases_drains_and_retries(self):
        events = []
        install_fake_speech_stack(
            events=events,
            statuses=({"resident_models": 0, "in_flight": 2}, {"resident_models": 0, "in_flight": 1}),
        )
        stream = io.StringIO()
        with redirect_stderr(stream), wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=False):
            events.append("ads.work")
        self.assertEqual(events, ["status", "barrier:echo:wilted-gpu-drained", "status", "ads.work"])
        stages = [json.loads(line)["stage"] for line in stream.getvalue().splitlines()]
        self.assertIn("ads.model.release", stages)
        self.assertIn("ads.model.retry", stages)

    def test_rpc_calls_share_one_decreasing_deadline(self):
        rpc_timeouts = []
        install_fake_speech_stack(
            statuses=({"resident_models": 1, "in_flight": 1}, {"resident_models": 0, "in_flight": 1}),
            rpc_timeouts=rpc_timeouts,
        )
        clock_value = [0.0]

        def clock():
            current = clock_value[0]
            clock_value[0] += 0.1
            return current

        with mock.patch.object(_worker_gpu_admission.time, "monotonic", side_effect=clock), \
                redirect_stderr(io.StringIO()), \
                wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=True):
            pass
        budgets = [timeout for _name, timeout in rpc_timeouts]
        self.assertGreater(len(budgets), 3)
        self.assertEqual(budgets, sorted(budgets, reverse=True))
        self.assertEqual(len(budgets), len(set(budgets)))

    def test_canonical_lock_contention_reports_progress_and_times_out(self):
        install_fake_speech_stack()
        tick = [0.0]

        def clock():
            current = tick[0]
            tick[0] += 1.0
            return current

        stream = io.StringIO()
        blocked = BlockingIOError()
        blocked.errno = wp.errno.EAGAIN
        with mock.patch.object(_worker_gpu_admission.fcntl, "flock", side_effect=blocked), \
                mock.patch.object(_worker_gpu_admission, "GPU_LOCK_ACQUISITION_TIMEOUT_S", 10.0), \
                mock.patch.object(_worker_gpu_admission.time, "monotonic", side_effect=clock), \
                mock.patch.object(_worker_gpu_admission.time, "sleep"), redirect_stderr(stream), \
                self.assertRaises(wp.WorkerError) as raised:
            with wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=False):
                self.fail("contended lock must not yield")
        self.assertEqual(raised.exception.code, "ads-model-wait-failed")
        self.assertIn("timed out waiting for exclusive GPU model admission", str(raised.exception))
        waits = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertGreaterEqual(sum("shared GPU inference lock" in event["detail"] for event in waits), 2)

    def test_a_peer_holding_the_lock_past_the_eviction_budget_still_admits(self):
        # One ten-second budget used to cover both the wait for the lock and
        # every daemon call after it, so a peer that held the GPU for longer
        # than that made admission impossible rather than merely slow. Three
        # episodes downloaded together lost two preparations to exactly that.
        rpc_timeouts = []
        install_fake_speech_stack(
            statuses=({"resident_models": 0, "in_flight": 1},), rpc_timeouts=rpc_timeouts
        )
        contended = BlockingIOError()
        contended.errno = wp.errno.EAGAIN
        attempts = []

        def flock(_fd, _flags):
            attempts.append(True)
            if len(attempts) <= 40:
                raise contended

        tick = [0.0]

        def clock():
            current = tick[0]
            tick[0] += 1.0
            return current

        events = []
        with mock.patch.object(_worker_gpu_admission.fcntl, "flock", side_effect=flock), \
                mock.patch.object(_worker_gpu_admission.time, "monotonic", side_effect=clock), \
                mock.patch.object(_worker_gpu_admission.time, "sleep"), redirect_stderr(io.StringIO()):
            with wp.prepare_ad_model_lock("/models/ad.gguf", aligned_stt=False):
                events.append("ads.work")
        self.assertEqual(events, ["ads.work"])
        self.assertGreater(tick[0], wp.STT_EVICTION_BARRIER_TIMEOUT_S)
        # The barrier budget starts when the lock is first held, so the status
        # call that follows a long wait is not already out of time.
        self.assertGreater(rpc_timeouts[0][1], wp.STT_EVICTION_BARRIER_TIMEOUT_S / 2)

    def test_speech_rpc_wait_reports_live_progress(self):
        stream = io.StringIO()

        def delayed(_timeout):
            # Finish only once a heartbeat is out (2 s cap), so a slow thread
            # switch can't let the RPC end before the first progress line.
            cap = time.monotonic() + 2
            while "waiting for test RPC" not in stream.getvalue() and time.monotonic() < cap:
                time.sleep(0.005)
            return "done"

        with mock.patch.object(_worker_gpu_admission, "GPU_LOCK_PROGRESS_INTERVAL_S", 0.005), \
                mock.patch.object(_worker_gpu_admission, "STT_EVICTION_BARRIER_POLL_INTERVAL_S", 0.001), \
                redirect_stderr(stream):
            result = wp._speech_rpc_with_progress(  # noqa: SLF001 - direct invariant regression
                delayed,
                time.monotonic() + 5,
                "waiting for test RPC",
            )
        self.assertEqual(result, "done")
        details = [json.loads(line)["detail"] for line in stream.getvalue().splitlines()]
        self.assertTrue(any("waiting for test RPC" in detail for detail in details))

    def test_canonical_lock_is_held_through_gguf_close(self):
        install_fake_speech_stack()
        state = {"held": False, "close_saw_lock": False}

        def fake_flock(_fd, operation):
            if operation == wp.fcntl.LOCK_UN:
                state["held"] = False
            elif operation & wp.fcntl.LOCK_NB:
                if state["held"]:
                    raise BlockingIOError(wp.errno.EAGAIN, "held")
                state["held"] = True

        llm = FakeLLM()
        original_close = llm.close

        def close():
            state["close_saw_lock"] = state["held"]
            original_close()

        llm.close = close
        install_fake_ads(llm)
        with mock.patch.object(_worker_gpu_admission.fcntl, "flock", side_effect=fake_flock), redirect_stderr(io.StringIO()), \
                mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
            wp.detect_and_cut(
                {"audioPath": str(self.audio)},
                self.audio,
                [],
                [FakeSegment(0, 1, "content")],
            )
        self.assertTrue(state["close_saw_lock"])
        self.assertFalse(state["held"])

    def test_model_lock_releases_after_load_inference_and_close_errors(self):
        cases = (
            (FakeLLM(fail_load=RuntimeError("load failed")), True),
            (FakeLLM(fail_generate=RuntimeError("inference failed")), True),
            (FakeLLM(), False),
        )
        for llm, raises in cases:
            with self.subTest(raises=raises):
                install_fake_ads(llm)
                if not raises:
                    llm.close = mock.Mock(side_effect=RuntimeError("close failed"))
                events = []
                if raises:
                    with redirect_stderr(io.StringIO()), self.assertRaises(wp.WorkerError), \
                            mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
                        wp.detect_and_cut(
                            {"audioPath": str(self.audio)},
                            self.audio,
                            [],
                            [FakeSegment(0, 1, "content")],
                            model_lock=recording_model_lock(events),
                        )
                else:
                    with redirect_stderr(io.StringIO()), \
                            mock.patch.object(_worker_cue_timing, "probe_duration", return_value=200.0):
                        wp.detect_and_cut(
                            {"audioPath": str(self.audio)},
                            self.audio,
                            [],
                            [FakeSegment(0, 1, "content")],
                            model_lock=recording_model_lock(events),
                        )
                self.assertEqual(events, ["lock.enter", "lock.exit"])
