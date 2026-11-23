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
from wilted_worker import cue_timing as _worker_cue_timing

REPO_ROOT = Path(__file__).resolve().parents[2]

WORKER_PATH = REPO_ROOT / "Producer" / "Workers" / "wilted_pipeline.py"

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

wp = load_worker()

def worker_namespaces():
    """Return the entry namespace plus every loaded split-worker namespace."""
    namespaces = dict(vars(wp))
    for name, module in sys.modules.items():
        if name.startswith("wilted_worker.") and isinstance(module, types.ModuleType):
            namespaces.update(vars(module))
    return namespaces

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

@contextmanager
def synthetic_render(source_duration, silence_report=""):
    """Stand in for ffmpeg and its duration probe on the reported cut path.

    The silence detection pass has no ``-filter_complex``; it gets
    ``silence_report`` as its stderr, which by default reports no silence.
    """
    rendered = {}

    def render(command, **_kwargs):
        if "-filter_complex" not in command:
            return silence_report
        output = Path(command[-1])
        output.write_bytes(b"synthetic")
        filters = command[command.index("-filter_complex") + 1]
        # asegment output n runs from split point n-1 to split point n; the
        # outputs routed to asetpts are the kept ones.
        points = [float(point) for point in re.search(r"asegment=timestamps=([0-9.|]+)", filters)[1].split("|")]
        bounds = [0.0, *points, source_duration]
        rendered[output.name] = sum(
            max(0.0, min(bounds[index + 1], source_duration) - bounds[index])
            for index in (int(found) for found in re.findall(r"\[s(\d+)\]asetpts", filters))
        )

    def probe(path):
        return rendered.get(Path(path).name, source_duration)

    with mock.patch.object(_worker_cue_timing, "_run_render_with_progress", side_effect=render), \
            mock.patch.object(_worker_cue_timing, "probe_duration", side_effect=probe):
        yield

def install_fake_wilted(parse_results=None, parse_error=None, transcriptions=None):
    """Stand in for the previous project's `wilted` package.

    `transcriptions` maps a model name to the segments the daemon returns for
    it, or to an exception it raises.
    """
    transcribe = types.ModuleType("wilted.transcribe")

    def transcribe_audio(audio_path, model_name="mlx-community/parakeet-tdt-0.6b-v3", **_):
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
    class SummaryOutputTruncated(ValueError):
        pass

    gguf_summary = types.ModuleType("wilted.gguf_summary")
    gguf_summary.SummaryOutputTruncated = SummaryOutputTruncated
    package = types.ModuleType("wilted")
    package.transcribe = transcribe
    package.gguf_summary = gguf_summary
    sys.modules["wilted"] = package
    sys.modules["wilted.transcribe"] = transcribe
    sys.modules["wilted.gguf_summary"] = gguf_summary
    # A `wilted.llm` double left behind by another test must not be reused here.
    sys.modules.pop("wilted.llm", None)
    install_fake_speech_stack()
    return transcribe

__all__ = ['FakeSegment', 'REPO_ROOT', 'WORKER_PACKAGE_PATH', 'WORKER_PATH', 'WORKER_SOURCES', 'install_fake_speech_stack', 'install_fake_wilted', 'load_ad_corpus', 'load_worker', 'recording_model_lock', 'synthetic_render', 'worker_namespaces', 'wp']
