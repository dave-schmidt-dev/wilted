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
from .commercial_preservation import _commercial_preservation_review
from .prompts import EXPERIMENTAL_NOMINATION_PROMPT
from .reporting import WorkerError
from .review_formats import _experimental_id_response_format, _parse_experimental_ids

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

    def generate(self, system_prompt, user_content, *, response_format=None):
        if self.calls >= self.limit:
            raise WorkerError("ads-experimental-budget-exhausted", "experimental model-call budget exhausted")
        self.calls += 1
        return self.backend.generate(system_prompt, user_content, response_format=response_format)

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

def detect_nominated_ad_spans(
    ads_module, backend, segments, total_seconds, *, pod_share_bound=None
):
    """Call the vendored detector and enforce an optional proportional pod bound.

    The archive's pod recovery has no proportional guard of its own. Its
    bracket bound is a fixed ten minutes written for a two-hour show, so on a
    short episode a single pod can swallow most of the programme -- the
    recorded TechCrunch overcut is exactly that shape (`gaps`, id
    `techcrunch-short-episode-overcut`). The worker holds no value it can
    defend for a share bound: the corpus carries three hand-labelled episodes,
    all tuning inputs, and the short-episode input that would calibrate one is
    gone, so replay evidence alone cannot establish its safety.

    The bound is therefore a caller-supplied parameter and nothing in this
    module reads a constant for it. `None` -- the production default -- applies
    no bound at all and returns the detector's own output untouched. When a
    bound is supplied, a nominated span whose share of the episode exceeds it
    is dropped uncut, the same conservative direction as every other ceiling:
    an advertisement left in is an annoyance, programme removed is gone.
    """
    detections = ads_module.detect_ads(segments, backend)
    if pod_share_bound is None or not 0 < float(total_seconds) < float("inf"):
        return detections
    bounded = []
    for ad in detections:
        share = (float(ad.end_s) - float(ad.start_s)) / float(total_seconds)
        if share > pod_share_bound:
            _worker_reporting.progress(
                "ads.detect.pod.rejected",
                f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} is {share:.0%} of the episode, "
                f"past the {pod_share_bound:.0%} nominated-pod bound",
            )
            continue
        bounded.append(ad)
    return bounded
