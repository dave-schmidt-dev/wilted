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
from . import prompts
from .constants import CUT_TOOLS
from .reporting import WorkerError

class CountingBackend:
    """Wrap the classifier's backend so a run that never reached the model is
    distinguishable from one that ran and found nothing.

    The detector treats every backend exception as a malformed response: it
    retries, halves the batch, and finally labels each segment as content. That
    is the right call for one bad completion and the wrong one for a backend
    that cannot answer at all, which it cannot tell apart. This can.
    """

    def __init__(self, backend):
        self._backend = backend
        self.calls = 0
        self.failures = 0
        self.last_error: Exception | None = None

    def generate(self, system_prompt: str, user_content: str, *, response_format=None):
        self.calls += 1
        try:
            return self._backend.generate(system_prompt, user_content, response_format=response_format)
        except Exception as error:
            self.failures += 1
            self.last_error = error
            raise

    @property
    def mostly_failed(self) -> bool:
        """True when the backend, not the completions, is what is broken.

        A healthy backend raises essentially never: the accepted four-podcast
        trial made 207 calls with no malformed responses, and a malformed
        response is the detector's parse error rather than a backend exception
        anyway. A majority of raised calls is an environment fault, and one
        lucky singleton must not disarm the check.
        """
        return self.calls > 0 and self.failures * 2 > self.calls

@dataclass(frozen=True)
class AuditCandidate:
    """Observed classifier evidence that deserves review, not an automatic cut."""

    kind: str
    ids: tuple[int, ...]
    detail: str

@dataclass
class AdAnalysisAudit:
    """Evidence recorded around the archive detector's otherwise opaque retries."""

    classifier_requests: int = 0
    classifier_valid_requests: int = 0
    classifier_invalid_requests: int = 0
    observed_ids: tuple[int, ...] = ()
    exhausted_singleton_lineages: int = 0
    model_requests: int = 0
    model_failures: int = 0
    experimental_requests: int = 0
    unresolved_ids: tuple[int, ...] = ()
    candidates: tuple[AuditCandidate, ...] = ()
    speculative_cuts: tuple[object, ...] = ()
    incomplete_error: str | None = None
    near_empty: str | None = None

@dataclass(frozen=True)
class AdAnalysis:
    """The archive's detections plus the worker-owned audit of their coverage."""

    detections: tuple[object, ...]
    audit: AdAnalysisAudit

@dataclass
class _ClassificationLineage:
    """One normal/correction request pair made by the archived classifier."""

    ids: tuple[int, ...]
    attempts: list[bool | None]
    positives: set[int]
    classifications: dict[int, set[str]]
    truncated: bool = False

def _rendered_global_ids(transcript: str) -> tuple[int, ...]:
    """Extract archive-rendered global IDs without interpreting transcript text."""
    return tuple(int(value) for value in re.findall(r"^\[ID (\d+)\] ", transcript, re.MULTILINE))

def _audit_ad_response(ads_module, response: str, expected_ids: tuple[int, ...]):
    """Return observed decisions, or ``None`` when the archive rejects a reply."""
    parser = getattr(ads_module, "_parse_ad_response", None)
    if not callable(parser):
        raise WorkerError("ads-audit-contract-unavailable", "archived ad response parser is unavailable")
    try:
        decisions = parser(response, list(expected_ids))
    except Exception:  # noqa: BLE001 - mirrors archive malformed-response handling
        return None
    if (
        not isinstance(decisions, list)
        or len(decisions) != len(expected_ids)
        or tuple(item[0] for item in decisions if isinstance(item, tuple) and len(item) == 3) != expected_ids
    ):
        raise WorkerError("ads-audit-contract-unavailable", "archived ad response parser contract drifted")
    return decisions

def _worker_owned_prompts() -> frozenset:
    """Every system prompt this worker itself defines.

    The contract guard below flags an unrecognized prompt that *looks* like an
    archived classifier request, to catch the archive's own prompts drifting
    out from under us. A prompt this module declares is by definition not that,
    but the guard's shape test is a word search over prose, so a worker prompt
    that merely says "classification" in a sentence tripped it and failed the
    whole preparation. Exempting our own prompts keeps the guard pointed at
    what it is for, and keeps the next prompt author from having to know which
    English words are load-free.
    """
    return frozenset(
        value for name, value in vars(prompts).items()
        if name.endswith("_PROMPT") and isinstance(value, str) and value
    )

class AuditingBackend(CountingBackend):
    """Observe archive classification requests while leaving its retry policy intact."""

    def __init__(self, backend, ads_module, segment_count: int | None = None):
        super().__init__(backend)
        self._ads_module = ads_module
        self._segment_count = segment_count
        self.lineages: list[_ClassificationLineage] = []
        self._pending: _ClassificationLineage | None = None
        self.contract_errors: list[str] = []
        prompts = (
            getattr(ads_module, "_AD_DETECT_SYSTEM_PROMPT", None),
            getattr(ads_module, "_AD_DETECT_CORRECTION_PROMPT", None),
        )
        parser = getattr(ads_module, "_parse_ad_response", None)
        response_format = getattr(ads_module, "_AD_DETECT_RESPONSE_FORMAT", None)
        if (not all(isinstance(prompt, str) and prompt for prompt in prompts)
                or prompts[0] == prompts[1] or not callable(parser) or not isinstance(response_format, dict)):
            raise WorkerError("ads-audit-contract-unavailable", "archived classifier contract is unavailable")
        self._classification_prompts = frozenset(prompts)
        self._normal_prompt = prompts[0]
        self._correction_prompt = prompts[1]
        self._classification_response_format = response_format
        self._worker_prompts = _worker_owned_prompts()

    def bind_segment_count(self, segment_count: int) -> None:
        """Bind rendered IDs to the transcript domain before detection begins."""
        if self._segment_count is not None and self._segment_count != segment_count:
            raise WorkerError("ads-audit-contract-unavailable", "audit backend is bound to another transcript")
        self._segment_count = segment_count

    def _contract_failure(self, detail: str) -> None:
        self.contract_errors.append(detail)
        raise WorkerError("ads-audit-contract-unavailable", detail)

    def generate(self, system_prompt: str, user_content: str, *, response_format=None):
        rendered_ids = _rendered_global_ids(user_content)
        classification = system_prompt in self._classification_prompts
        schema_matches = response_format == self._classification_response_format
        if classification and not schema_matches:
            self._contract_failure("archived classifier request used an unrecognized response schema")
        classification_shaped = bool(
            rendered_ids
            and system_prompt not in self._worker_prompts
            and re.search(r"\bclassif(?:y|ication|ier)\b", system_prompt, re.IGNORECASE)
        )
        if not classification and (schema_matches or classification_shaped):
            self._contract_failure("unknown classification-shaped prompt")
        ids = rendered_ids if classification else ()
        if classification:
            if not ids or user_content.count("[ID ") != len(ids) or len(set(ids)) != len(ids):
                self._contract_failure("classifier request rendered missing or duplicate global IDs")
            if self._segment_count is None or any(not 0 <= segment_id < self._segment_count for segment_id in ids):
                self._contract_failure("classifier request rendered an out-of-range global ID")
        lineage = None
        if classification:
            if system_prompt == self._normal_prompt or self._pending is None or self._pending.ids != ids:
                lineage = _ClassificationLineage(ids, [], set(), {}, "…[TRUNCATED]…" in user_content)
                self.lineages.append(lineage)
                self._pending = lineage
            else:
                lineage = self._pending
        try:
            response, tokens = super().generate(system_prompt, user_content, response_format=response_format)
        except Exception:
            if lineage is not None:
                lineage.attempts.append(False)
                if system_prompt == self._correction_prompt:
                    self._pending = None
            raise
        if lineage is not None:
            decisions = _audit_ad_response(self._ads_module, response, ids)
            lineage.attempts.append(decisions is not None)
            if decisions is not None:
                for segment_id, is_ad, label in decisions:
                    state = f"ad:{label}" if is_ad else "content"
                    lineage.classifications.setdefault(segment_id, set()).add(state)
                    if is_ad:
                        lineage.positives.add(segment_id)
                self._pending = None
            elif system_prompt == self._correction_prompt:
                self._pending = None
        return response, tokens

    def audit(self, detections, segments) -> AdAnalysisAudit:
        """Summarize observed coverage; never infer the archive's private drop reason."""
        unresolved = sorted({
            lineage.ids[0]
            for lineage in self.lineages
            if len(lineage.ids) == 1 and len(lineage.attempts) >= 2 and not any(lineage.attempts)
        })
        candidates: list[AuditCandidate] = []
        observed_positive_ids = set().union(*(lineage.positives for lineage in self.lineages)) if self.lineages else set()
        for segment_id in sorted(observed_positive_ids):
            if not 0 <= segment_id < len(segments):
                continue
            segment = segments[segment_id]
            if not any(float(ad.start_s) <= float(segment.start_s) and float(ad.end_s) >= float(segment.end_s)
                       for ad in detections):
                candidates.append(AuditCandidate(
                    "positive-missing-final-span", (segment_id,),
                    f"classifier marked global ID {segment_id} as advertising but no final span covers it",
                ))
        observed_states: dict[int, set[str]] = {}
        for lineage in self.lineages:
            for segment_id, states in lineage.classifications.items():
                observed_states.setdefault(segment_id, set()).update(states)
            if lineage.truncated:
                candidates.append(AuditCandidate(
                    "visible-truncation", lineage.ids,
                    "classifier request visibly contained the archive truncation marker",
                ))
        for segment_id, states in sorted(observed_states.items()):
            if len(states) > 1:
                candidates.append(AuditCandidate(
                    "request-disagreement", (segment_id,),
                    f"classifier responses disagreed for global ID {segment_id}: {', '.join(sorted(states))}",
                ))
        return AdAnalysisAudit(
            classifier_requests=sum(len(lineage.attempts) for lineage in self.lineages),
            classifier_valid_requests=sum(sum(attempt is True for attempt in lineage.attempts) for lineage in self.lineages),
            classifier_invalid_requests=sum(sum(attempt is False for attempt in lineage.attempts) for lineage in self.lineages),
            observed_ids=tuple(sorted({segment_id for lineage in self.lineages for segment_id in lineage.ids})),
            exhausted_singleton_lineages=sum(
                len(lineage.ids) == 1 and len(lineage.attempts) >= 2 and not any(lineage.attempts)
                for lineage in self.lineages
            ),
            model_requests=self.calls,
            model_failures=self.failures,
            unresolved_ids=tuple(unresolved),
            candidates=tuple(candidates),
        )

def preflight_ad_removal(request: dict) -> None:
    """Fail before any work if the cut cannot possibly succeed.

    Both checks are cheap, and both failures were silent before: the model
    reached the detector unloaded and every batch was quietly classified as
    content, and the missing `ffprobe` surfaced only as a skipped duration
    probe on the way out. A run that skips ad removal skips this too.
    """
    from wilted import llm as llm_module

    missing = [tool for tool in CUT_TOOLS if shutil.which(tool) is None]
    if missing:
        raise WorkerError(
            "cut-tools-missing",
            f"{', '.join(missing)} not on PATH ({os.environ.get('PATH', '')}); install ffmpeg",
        )
    model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
    # An `hf:<repo>/<file>` spec is resolved by the previous project's cache
    # at load time; only a literal path can be checked here.
    if not model.startswith("hf:") and not Path(model).is_file():
        raise WorkerError("ads-model-missing", f"no ad-detection model at {model}")
