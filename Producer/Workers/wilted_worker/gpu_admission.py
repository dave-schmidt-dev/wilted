"""Worker module split from wilted_pipeline.py."""
from __future__ import annotations
import contextlib
import difflib
import errno
import fcntl
import html
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path
from . import reporting as _worker_reporting
from .constants import STT_EVICTION_BARRIER_TIMEOUT_S
from .reporting import WorkerError

STT_EVICTION_BARRIER_POLL_INTERVAL_S = 0.1

GPU_LOCK_PROGRESS_INTERVAL_S = 1.0

GPU_LOCK_ACQUISITION_TIMEOUT_S = 30 * 60.0

def _remaining_admission_budget(deadline: float) -> float:
    """Return the remaining shared lock/RPC budget or fail at its one deadline."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("timed out waiting for exclusive GPU model admission")
    return remaining

def _speech_rpc_with_progress(operation, deadline: float, detail: str):
    """Run one bounded synchronous daemon RPC with periodic progress."""
    outcome = {}
    done = threading.Event()

    def invoke():
        try:
            outcome["result"] = operation(_remaining_admission_budget(deadline))
        except BaseException as error:  # noqa: BLE001 - re-raised on the caller thread
            outcome["error"] = error
        finally:
            done.set()

    threading.Thread(target=invoke, daemon=True, name="wilted-speech-rpc").start()
    next_heartbeat = time.monotonic() + GPU_LOCK_PROGRESS_INTERVAL_S
    while not done.is_set():
        remaining = _remaining_admission_budget(deadline)
        if done.wait(min(STT_EVICTION_BARRIER_POLL_INTERVAL_S, remaining)):
            break
        now = time.monotonic()
        if now >= next_heartbeat:
            _worker_reporting.progress("ads.model.wait", f"{detail}; {remaining:.1f}s remain")
            next_heartbeat = now + GPU_LOCK_PROGRESS_INTERVAL_S
    if "error" in outcome:
        raise outcome["error"]
    return outcome.get("result")

@contextlib.contextmanager
def _canonical_gpu_flock(deadline: float):
    """Acquire speech-stack's canonical flock without a silent blocking wait."""
    from speech_stack.daemon import host as speech_host

    lock_path = speech_host.state_dir() / "gpu.lock"
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    next_heartbeat = time.monotonic()
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN):
                    raise
            remaining = _remaining_admission_budget(deadline)
            now = time.monotonic()
            if now >= next_heartbeat:
                _worker_reporting.progress("ads.model.wait", f"waiting for shared GPU inference lock; {remaining:.1f}s remain")
                next_heartbeat = now + GPU_LOCK_PROGRESS_INTERVAL_S
            time.sleep(min(STT_EVICTION_BARRIER_POLL_INTERVAL_S, remaining))
        try:
            yield
        finally:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)

def _validate_daemon_admission_snapshot(snapshot) -> tuple[int, int]:
    """Validate the broker counters used while the canonical flock is held."""
    resident_models = snapshot.get("resident_models") if isinstance(snapshot, dict) else None
    in_flight = snapshot.get("in_flight") if isinstance(snapshot, dict) else None
    if type(resident_models) is not int or resident_models < 0:
        raise RuntimeError(f"invalid speech daemon status: {snapshot!r}")
    if type(in_flight) is not int or in_flight < 1:
        raise RuntimeError(f"invalid speech daemon status: {snapshot!r}")
    return resident_models, in_flight

@contextlib.contextmanager
def prepare_ad_model_lock(_model: str, *, aligned_stt: bool):
    """Hold the canonical GPU flock after broker residency and work drain."""
    from speech_stack import client as speech_client

    # Two budgets, because they bound two different failures. Acquiring the
    # lock waits on a peer and is allowed to take as long as that peer's work;
    # everything after it talks to the daemon and must fail fast if the daemon
    # has stopped answering. The barrier budget starts when the lock is first
    # held, not at entry, so a long wait does not spend it before the first RPC.
    lock_deadline = time.monotonic() + GPU_LOCK_ACQUISITION_TIMEOUT_S
    barrier_deadline = None
    source = "aligned STT" if aligned_stt else "published transcript"
    _worker_reporting.progress("ads.model.wait", f"waiting for exclusive GPU admission after {source}")
    lock_stack = None
    try:
        while True:
            lock_stack = contextlib.ExitStack()
            try:
                lock_stack.enter_context(_canonical_gpu_flock(lock_deadline))
                if barrier_deadline is None:
                    barrier_deadline = time.monotonic() + STT_EVICTION_BARRIER_TIMEOUT_S
                snapshot = _speech_rpc_with_progress(
                    lambda timeout: speech_client.status(timeout=timeout),
                    barrier_deadline,
                    "waiting for speech daemon status",
                )
                resident_models, in_flight = _validate_daemon_admission_snapshot(snapshot)
            except speech_client.DaemonUnavailable:
                _worker_reporting.progress("ads.model.wait", "speech daemon unavailable; canonical GPU lock is exclusive")
                break
            except Exception:
                lock_stack.close()
                raise

            if resident_models == 0 and in_flight == 1:
                _worker_reporting.progress("ads.model.wait", "GPU admission is exclusive")
                break

            _worker_reporting.progress(
                "ads.model.release",
                f"releasing GPU lock to drain {resident_models} resident models and {in_flight - 1} other requests",
            )
            lock_stack.close()
            _worker_reporting.progress("ads.model.drain", "evicting resident speech models and waiting on FIFO barrier")
            try:
                if resident_models:
                    for task in ("stt", "tts"):
                        _speech_rpc_with_progress(
                            lambda timeout, task=task: speech_client.evict(task, timeout=timeout),
                            barrier_deadline,
                            f"waiting to evict resident {task} model",
                        )
                _speech_rpc_with_progress(
                    lambda timeout: speech_client.selftest(
                        "echo",
                        timeout=timeout,
                        barrier="wilted-gpu-drained",
                    ),
                    barrier_deadline,
                    "waiting for speech daemon FIFO drain",
                )
            except speech_client.DaemonUnavailable:
                _worker_reporting.progress("ads.model.drain", "speech daemon stopped during drain; retrying canonical lock")
            _worker_reporting.progress("ads.model.retry", "retrying exclusive GPU admission")
    except WorkerError:
        raise
    except Exception as error:  # noqa: BLE001 - never load GGUF without proving exclusive admission
        raise WorkerError(
            "ads-model-wait-failed",
            f"exclusive GPU admission failed: {type(error).__name__}: {error}",
        ) from error
    assert lock_stack is not None
    with lock_stack:
        yield
