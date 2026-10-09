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
                    progress(f"log.{record.levelname.lower()}.{self.forwarded}", "Local summarizer warning.")
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

DISCARDED_RUN_REPORT_LIMIT = 12

class DiscardedRuns(logging.Handler):
    """Collect the archived detector's own notices about runs it threw away.

    The detector flags a span, fails to evidence it, and drops it with a line
    at INFO -- which the WARNING+ forwarder above never sees. That left a real
    question unanswerable: The Daily's closing Chase Sapphire spot was missing
    from the output and nothing in the journal said whether it had been flagged
    and then dropped for lacking a price or an address, or never flagged at
    all. Those two want different fixes, so the difference is worth one line.
    """

    def __init__(self, segments, limit: int = DISCARDED_RUN_REPORT_LIMIT):
        super().__init__(level=logging.INFO)
        self.segments = segments
        self.limit = limit
        self.notices: list[str] = []
        self.count = 0

    def emit(self, record: logging.LogRecord) -> None:
        try:
            message = record.getMessage()
            if not message.startswith("Discarding"):
                return
            self.count += 1
            if len(self.notices) < self.limit:
                self.notices.append(self._with_times(message))
        except Exception:  # noqa: BLE001 - a handler must never unwind its caller
            self.handleError(record)

    def _with_times(self, message: str) -> str:
        """Add the run's clock times, because a segment ID means nothing later."""
        found = re.search(r"\b(\d+)-(\d+)\b", message)
        if not found:
            return message
        first, last = int(found.group(1)), int(found.group(2))
        if not 0 <= first <= last < len(self.segments):
            return message
        span = f"{float(self.segments[first].start_s):.1f}-{float(self.segments[last].end_s):.1f}s"
        return f"{message} ({span})"

    def summarize(self) -> None:
        if not self.count:
            return
        detail = "; ".join(self.notices)
        if self.count > len(self.notices):
            detail += f"; and {self.count - len(self.notices)} more"
        progress("ads.detect.discarded", f"{self.count} flagged runs dropped: {detail}")
