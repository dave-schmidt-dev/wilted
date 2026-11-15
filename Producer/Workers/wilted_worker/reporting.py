"""Worker module split from wilted_pipeline.py."""
from __future__ import annotations
import contextlib
from contextvars import ContextVar
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
from .constants import FORWARDED_WARNING_LIMIT

class WorkerError(RuntimeError):
    """A failure that should be reported as a structured result, not a crash."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code

_summary_request_id: ContextVar[str | None] = ContextVar("summary_request_id", default=None)

@contextlib.contextmanager
def summary_scope(request_id: str | None):
    """Correlate this summary's progress without affecting preparation records."""
    token = _summary_request_id.set(request_id)
    try:
        yield
    finally:
        _summary_request_id.reset(token)

def progress(stage: str, detail: str = "", fraction: float | None = None) -> None:
    """Emit one progress record on stderr.

    Every stage below is minutes long on a real episode. A caller with no
    feedback channel cannot tell a working transcription from a hung one, so
    this is part of the contract rather than logging.
    """
    request_id = _summary_request_id.get()
    if request_id is not None:
        stage = stage if stage.startswith("summary.") else "summary." + stage
    record = {"stage": stage, "detail": detail}
    if request_id is not None:
        record["requestID"] = request_id
    if fraction is not None:
        record["fraction"] = round(max(0.0, min(1.0, fraction)), 4)
    sys.stderr.write(json.dumps(record, separators=(",", ":")) + "\n")
    sys.stderr.flush()

class ForwardedWarnings(logging.Handler):
    """Relay WARNING+ log records from every library in this process as progress.

    The previous project reports trouble through `logging`. With no handler
    installed, Python's last-resort handler printed those lines to raw stderr,
    where the Swift collector discards anything that is not a JSON record --
    so the thousands of "Model not loaded" warnings that explained the TWiT
    1098 false negative were thrown away. Each relayed record gets its own
    numbered stage because the journal keeps one row per stage.
    """

    def __init__(self, limit: int = FORWARDED_WARNING_LIMIT):
        super().__init__(level=logging.WARNING)
        self.limit = limit
        self.forwarded = 0
        self.suppressed = 0
        # Logging handlers may run on threads that do not inherit ContextVars.
        self.summary_request_id = _summary_request_id.get()

    def emit(self, record: logging.LogRecord) -> None:
        if self.forwarded >= self.limit:
            self.suppressed += 1
            return
        self.forwarded += 1
        try:
            if self.summary_request_id is not None:
                with summary_scope(self.summary_request_id):
                    progress(f"log.{record.levelname.lower()}.{self.forwarded}", f"Local summarizer warning from {record.name}.")
            else:
                progress(f"log.{record.levelname.lower()}.{self.forwarded}", f"{record.name}: {record.getMessage()}")
        except Exception:  # noqa: BLE001 - a handler must never unwind its caller
            # handleError can print the original message and traceback. Summary
            # records may contain transcript text supplied by a model library.
            if self.summary_request_id is None:
                self.handleError(record)

    def summarize(self) -> None:
        if self.suppressed:
            if self.summary_request_id is not None:
                with summary_scope(self.summary_request_id):
                    progress("log.suppressed", f"{self.suppressed} further warnings not relayed")
            else:
                progress("log.suppressed", f"{self.suppressed} further warnings not relayed")
