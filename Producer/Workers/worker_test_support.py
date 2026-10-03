"""Unit tests for the podcast preparation worker.

Deliberately dependency-free: every import the worker makes from the previous
project is lazy and inside a function, so the tests stub those modules and run
without a model. That keeps this leg in the ordinary gate instead of loading a
four-gigabyte model."""
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
from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import reporting as _worker_reporting
from wilted_worker import transcript_sources as _worker_transcript_sources

_WORKER_PATCH_MODULES = {'recover_commercial_evidence_reads': _worker_commercial_seeds, 'recover_sparse_commercial_reads': _worker_commercial_seeds, 'recover_transcript_end_postroll': _worker_tail_recovery, 'recover_transcript_start_preroll': _worker_edge_recovery, 'recover_unclaimed_explicit_sponsor_reads': _worker_commercial_recovery, 'resize_oversized_ad_spans': _worker_span_bounds}

REPO_ROOT = Path(__file__).resolve().parents[2]

WORKER_PATH = REPO_ROOT / "Producer" / "Workers" / "wilted_pipeline.py"

RUNTIME_ADS_PATH = REPO_ROOT / "Producer" / "Runtime" / "src" / "wilted" / "ads.py"

WORKER_PACKAGE_PATH = WORKER_PATH.with_name("wilted_worker")

WORKER_SOURCES = (WORKER_PATH, *sorted(WORKER_PACKAGE_PATH.rglob("*.py"))) if WORKER_PACKAGE_PATH.is_dir() else (WORKER_PATH,)

def load_ad_corpus():
    """Load the corpus scorer the same way the worker is loaded.

    `sys.modules` has to hold the module before `exec_module` runs, because
    `@dataclass` resolves its fields by looking the defining module up there.
    """
    path = REPO_ROOT / "Producer" / "Workers" / "ad_corpus.py"
    spec = importlib.util.spec_from_file_location("ad_corpus", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["ad_corpus"] = module
    spec.loader.exec_module(module)
    return module

def load_worker():
    spec = importlib.util.spec_from_file_location("wilted_pipeline", WORKER_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["wilted_pipeline"] = module
    spec.loader.exec_module(module)
    return module

def load_runtime_ads():
    """Load the vendored `wilted.ads` with its model imports stood in for.

    The gate never imports the real module -- it reaches the model bindings --
    so the pure confidence arithmetic under test is loaded against minimal
    stand-ins for `wilted.cache`, `wilted.llm` and `wilted.transcribe`. The
    stand-ins are removed from `sys.modules` again as soon as the module is
    loaded: the loaded object keeps its own globals and does not need them to
    stay, and the rest of the suite must see the module tree it expects.
    """
    names = ("wilted", "wilted.cache", "wilted.llm", "wilted.transcribe", "wilted.ads")
    saved = {name: sys.modules.get(name) for name in names}

    package = types.ModuleType("wilted")
    package.__path__ = []
    cache = types.ModuleType("wilted.cache")
    cache.check_ffmpeg = lambda *args, **kwargs: None
    llm = types.ModuleType("wilted.llm")
    llm.LLMBackend = object
    llm.parse_json_response = json.loads
    transcript = types.ModuleType("wilted.transcribe")

    @dataclass
    class TranscriptSegment:
        start_s: float
        end_s: float
        text: str
        tokens: tuple = ()

    transcript.TranscriptSegment = TranscriptSegment
    sys.modules.update({
        "wilted": package,
        "wilted.cache": cache,
        "wilted.llm": llm,
        "wilted.transcribe": transcript,
    })
    try:
        spec = importlib.util.spec_from_file_location("wilted.ads", RUNTIME_ADS_PATH)
        module = importlib.util.module_from_spec(spec)
        sys.modules["wilted.ads"] = module
        spec.loader.exec_module(module)
    finally:
        for name, previous in saved.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous
    return module, TranscriptSegment

wp = load_worker()

def worker_namespaces():
    """Return the entry namespace plus every loaded split-worker namespace."""
    namespaces = dict(vars(wp))
    for name, module in sys.modules.items():
        if name.startswith("wilted_worker.") and isinstance(module, types.ModuleType):
            namespaces.update(vars(module))
    return namespaces

def _worker_owned_prompts():
    return {
        value
        for name, value in worker_namespaces().items()
        if name.endswith("_PROMPT") and isinstance(value, str) and value
    }

def _passthrough_detections(_ads, _backend, _segments, detections, *_args):
    return detections

def _passthrough_reviewed_detections(_ads, _backend, _segments, detections, *_args):
    return detections, frozenset()

@dataclass
class FakeSegment:
    start_s: float
    end_s: float
    text: str

def install_fake_speech_stack(
    *, events=None, evict_error=None, barrier_error=None, statuses=(), rpc_timeouts=None
):
    """Install the daemon FIFO and shared lock with deterministic behavior."""
    events = events if events is not None else []
    remaining_statuses = iter(statuses or ({"resident_models": 0, "in_flight": 1},))
    last_status = {"resident_models": 0, "in_flight": 1}
    rpc_timeouts = rpc_timeouts if rpc_timeouts is not None else []

    class DaemonUnavailable(RuntimeError):
        pass

    client = types.ModuleType("speech_stack.client")
    client.DaemonUnavailable = DaemonUnavailable

    def evict(task, **params):
        events.append(f"evict:{task}")
        rpc_timeouts.append((f"evict:{task}", params.get("timeout")))
        if evict_error is not None:
            raise evict_error
        return {"evicted": True, "task": task}

    def selftest(action, **params):
        events.append(f"barrier:{action}:{params.get('barrier', '')}")
        rpc_timeouts.append(("selftest", params.get("timeout")))
        if barrier_error is not None:
            raise barrier_error
        return params

    def status(**params):
        nonlocal last_status
        events.append("status")
        rpc_timeouts.append(("status", params.get("timeout")))
        try:
            last_status = next(remaining_statuses)
        except StopIteration:
            pass
        last_status = {"in_flight": 1, **last_status}
        return last_status

    client.evict = evict
    client.selftest = selftest
    client.status = status
    host = types.ModuleType("speech_stack.daemon.host")
    host._test_state_dir = tempfile.TemporaryDirectory(prefix="wilted-pipeline-lock-")
    unittest.addModuleCleanup(host._test_state_dir.cleanup)
    host.state_dir = lambda: Path(host._test_state_dir.name)

    daemon = types.ModuleType("speech_stack.daemon")
    daemon.host = host
    package = types.ModuleType("speech_stack")
    package.client = client
    package.daemon = daemon
    sys.modules["speech_stack"] = package
    sys.modules["speech_stack.client"] = client
    sys.modules["speech_stack.daemon"] = daemon
    sys.modules["speech_stack.daemon.host"] = host
    return client, events

@contextmanager
def recording_model_lock(events):
    """A lock double whose exit proves every model path releases it."""
    events.append("lock.enter")
    try:
        yield
    finally:
        events.append("lock.exit")

def install_fake_wilted(parse_results=None, parse_error=None, transcriptions=None):
    """Stand in for the previous project's `wilted` package.

    `transcriptions` maps a model name to the segments the daemon returns for
    it, or to an exception it raises.
    """
    transcribe = types.ModuleType("wilted.transcribe")

    def transcribe_audio(audio_path, model_name="mlx-community/parakeet-tdt-1.1b", **_):
        outcome = (transcriptions or {}).get(model_name)
        if isinstance(outcome, Exception):
            raise outcome
        if outcome is None:
            raise RuntimeError(f"no fake transcription for {model_name}")
        return outcome

    transcribe.transcribe_audio = transcribe_audio

    def parser(name):
        def parse(body):
            if parse_error is not None:
                raise parse_error
            calls.append((name, body))
            return (parse_results or {}).get(name)
        return parse

    calls: list[tuple[str, str]] = []
    transcribe.parse_vtt = parser("vtt")
    transcribe.parse_srt = parser("srt")
    transcribe.parse_podcast_json = parser("podcast-json")
    transcribe.calls = calls
    package = types.ModuleType("wilted")
    package.transcribe = transcribe
    sys.modules["wilted"] = package
    sys.modules["wilted.transcribe"] = transcribe
    # `from wilted import ads` falls back to sys.modules["wilted.ads"], so a
    # double left behind by another test would be silently reused here.
    sys.modules.pop("wilted.ads", None)
    sys.modules.pop("wilted.llm", None)
    install_fake_speech_stack()
    return transcribe

__all__ = ['FakeSegment', 'REPO_ROOT', 'RUNTIME_ADS_PATH', 'WORKER_PACKAGE_PATH', 'WORKER_PATH', 'WORKER_SOURCES', '_WORKER_PATCH_MODULES', '_passthrough_detections', '_passthrough_reviewed_detections', '_worker_owned_prompts', 'install_fake_speech_stack', 'install_fake_wilted', 'load_ad_corpus', 'load_runtime_ads', 'load_worker', 'recording_model_lock', 'worker_namespaces', 'wp']
