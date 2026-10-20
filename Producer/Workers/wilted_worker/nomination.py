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
from typing import TYPE_CHECKING
from .commercial_preservation import _commercial_preservation_review
from .prompts import EXPERIMENTAL_NOMINATION_PROMPT
from .reporting import WorkerError
from .review_formats import _experimental_id_response_format, _parse_experimental_ids

if TYPE_CHECKING:
    from .ad_audit import AdAnalysisAudit, AuditingBackend

EXPERIMENTAL_CONTEXT_IDS = 9

EXPERIMENTAL_CONTEXT_CHARS = 12_000

EXPERIMENTAL_MAX_CANDIDATE_SECONDS = 600.0

EXPERIMENTAL_MAX_CANDIDATE_SHARE = 0.15

class _CallBudgetBackend:
    """Enforce an experimental model-call limit before forwarding inference."""

    def __init__(self, backend, limit: int):
        self.backend = backend
        self.limit = limit
        self.calls = 0

    def generate(self, system_prompt, user_content, *, response_format=None, prepared_prompt=None):
        if self.calls >= self.limit:
            raise WorkerError("ads-experimental-budget-exhausted", "experimental model-call budget exhausted")
        self.calls += 1
        kwargs = {"response_format": response_format}
        if prepared_prompt is not None:
            kwargs["prepared_prompt"] = prepared_prompt
        return self.backend.generate(system_prompt, user_content, **kwargs)

    def measure_prompt(self, system_prompt, user_content, *, response_format=None):
        """Forward a non-inference budget query without spending the call quota."""
        measure = getattr(self.backend, "measure_prompt", None)
        if not callable(measure):
            raise ValueError("backend cannot measure the loaded chat prompt budget")
        return measure(system_prompt, user_content, response_format=response_format)

def _experimental_speculative_cuts(
    audit: AdAnalysisAudit,
    backend: AuditingBackend,
    segments,
    total_seconds: float,
    nominated_candidates,
    max_additional_model_calls: int,
) -> AdAnalysisAudit:
    """Run the opt-in adaptation seam, refusing every incomplete proposal.

    This is intentionally not wired to preparation. A caller must nominate an
    observed diagnostic candidate and provide a preservation confirmation; the
    archive's unobservable filtering state is never used as evidence.
    """
    if not nominated_candidates:
        return audit
    nominated = tuple(dict.fromkeys(nominated_candidates))
    observed = set(audit.candidates)
    if (max_additional_model_calls < 2 or not total_seconds > 0 or not total_seconds < float("inf")
            or any(candidate not in observed or not candidate.ids for candidate in nominated)):
        audit.incomplete_error = "experimental adaptation is missing nominated evidence, duration, or mandatory call budget"
        audit.speculative_cuts = ()
        return audit
    speculative = []
    budget = _CallBudgetBackend(backend, max_additional_model_calls)
    for candidate in nominated:
        try:
            candidate_ids = tuple(dict.fromkeys(candidate.ids))
            if (any(not 0 <= segment_id < len(segments) for segment_id in candidate_ids)
                    or tuple(sorted(candidate_ids)) != candidate_ids):
                raise ValueError("candidate IDs are invalid")
            first, last = candidate_ids[0], candidate_ids[-1]
            if candidate_ids != tuple(range(first, last + 1)):
                raise ValueError("candidate IDs are not contiguous")
            if len(candidate_ids) > EXPERIMENTAL_CONTEXT_IDS - 2:
                raise ValueError("candidate exceeds the bounded context ID budget")
            start_s, end_s = float(segments[first].start_s), float(segments[last].end_s)
            duration = end_s - start_s
            if (not 0 <= start_s < end_s <= total_seconds
                    or duration > EXPERIMENTAL_MAX_CANDIDATE_SECONDS
                    or duration / total_seconds > EXPERIMENTAL_MAX_CANDIDATE_SHARE):
                raise ValueError("candidate duration is unsafe")
            remaining = EXPERIMENTAL_CONTEXT_IDS - len(candidate_ids) - 2
            left_extra = min(first - 1, remaining // 2)
            right_extra = min(len(segments) - last - 2, remaining - left_extra)
            left_extra = min(first - 1, remaining - right_extra)
            context_ids = tuple(range(first - left_extra - 1, last + right_extra + 2))
            if len(context_ids) > EXPERIMENTAL_CONTEXT_IDS or context_ids[0] == first or context_ids[-1] == last:
                raise ValueError("candidate lacks programme context on both sides")
            rendered = "\n".join(
                f"[ID {segment_id}] [{float(segments[segment_id].start_s):.3f}s - "
                f"{float(segments[segment_id].end_s):.3f}s] {segments[segment_id].text}"
                for segment_id in context_ids
            )
            if len(rendered) > EXPERIMENTAL_CONTEXT_CHARS:
                raise ValueError("candidate exceeds the bounded context character budget")
            nomination, _ = budget.generate(
                EXPERIMENTAL_NOMINATION_PROMPT,
                rendered,
                response_format=_experimental_id_response_format("ad_ids", candidate_ids),
            )
            ad_ids = _parse_experimental_ids(nomination, "ad_ids", candidate_ids, nonempty=True)
            if ad_ids != candidate_ids:
                raise ValueError("nomination did not confirm the complete candidate")
            _commercial_preservation_review(budget, rendered, context_ids, ad_ids, segments=segments)
        except Exception as error:  # noqa: BLE001 - experimental work cannot weaken a safe result
            audit.incomplete_error = f"experimental adaptation incomplete: {type(error).__name__}: {error}"
            audit.speculative_cuts = ()
            audit.experimental_requests = budget.calls
            return audit
        speculative.append({"startSeconds": start_s, "endSeconds": end_s, "ids": ad_ids})
    audit.speculative_cuts = tuple(speculative)
    audit.experimental_requests = budget.calls
    return audit
