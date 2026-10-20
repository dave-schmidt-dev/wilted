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
from .constants import COMMERCIAL_PRESERVATION_FLANK_IDS, COMMERCIAL_PRESERVATION_FLANK_STEPS, COMMERCIAL_SPARSE_PREFIX_MAX_IDS, COMMERCIAL_SPARSE_PREFIX_MAX_SECONDS, EXPLICIT_SPONSOR_CTA_RE, RECOVERED_CONFIDENCE_CEILING, RECOVERED_CONFIDENCE_FLOOR
from .prompts import COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT, COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT, COMMERCIAL_EVIDENCE_NOMINATION_PROMPT, COMMERCIAL_PREFIX_CUE_PROMPT, COMMERCIAL_PREFIX_ROLE_PROMPT
from .review_formats import _commercial_conflict_response_format, _commercial_preservation_labels, _commercial_preservation_response_format, _experimental_id_response_format, _parse_commercial_conflict_response, _parse_experimental_ids
from .interval_geometry import interval_contains
from .sponsor_evidence import _commercial_recovery_context, explicit_sponsor_destination_seen

def _generate_review(backend, system_prompt, user_content, *, response_format):
    """Infer the exact final request that was just measured, through the audited path."""
    prepared = backend.measure_prompt(system_prompt, user_content, response_format=response_format)
    values = _prompt_budget_values(prepared)
    if values[0] + values[2] > values[1]:
        raise ValueError("commercial review " + _budget_detail(*values))
    return backend.generate(system_prompt, user_content, response_format=response_format,
                            prepared_prompt=prepared)


def _prompt_budget_values(prepared):
    """Return a truthful measured budget or reject an unusable one."""
    if isinstance(prepared, dict):
        values = (
            prepared.get("token_count"),
            prepared.get("context_size"),
            prepared.get("output_reserve"),
        )
    elif isinstance(prepared, (tuple, list)) and len(prepared) == 3:
        values = tuple(prepared)
    else:
        values = tuple(
            getattr(prepared, name, None)
            for name in ("token_count", "context_size", "output_reserve")
        )
    if any(type(value) is not int or value <= 0 for value in values):
        raise ValueError("commercial review measured an invalid chat prompt budget")
    token_count, context_size, output_reserve = values
    if output_reserve >= context_size:
        raise ValueError("commercial review measured an invalid chat prompt budget")
    return token_count, context_size, output_reserve

def _budget_detail(token_count, context_size, output_reserve):
    return (
        f"needs {token_count + output_reserve} tokens "
        f"({token_count} prompt + {output_reserve} output reserve) "
        f"against {context_size} context"
    )

def _measure_review_request(backend, system_prompt, user_content, response_format):
    """Measure one request without inference; False means the measured prompt is too large."""
    measure = getattr(backend, "measure_prompt", None)
    if not callable(measure):
        raise ValueError("commercial review requires a measured chat prompt budget")
    try:
        prepared = measure(system_prompt, user_content, response_format=response_format)
    except ValueError as error:
        try:
            values = _prompt_budget_values(error)
        except ValueError:
            # Missing/invalid measurement, template or reserve is unusable.
            return False, f"{type(error).__name__}: {error}"
        return False, _budget_detail(*values)
    token_count, context_size, output_reserve = _prompt_budget_values(prepared)
    if token_count + output_reserve > context_size:
        return False, _budget_detail(token_count, context_size, output_reserve)
    return True, ""

def _measure_review_requests(backend, requests):
    for system_prompt, user_content, response_format in requests:
        fits, detail = _measure_review_request(
            backend, system_prompt, user_content, response_format
        )
        if not fits:
            return False, detail
    return True, ""

def _commercial_review_requests(
    rendered, context_ids, proposed_ids, *, nominate_ids=None,
    nomination_prompt=COMMERCIAL_EVIDENCE_NOMINATION_PROMPT,
    prefix_evidence_id=None,
):
    """Every request shape this review can send for one rendered context."""
    requests = []
    if nominate_ids is not None:
        requests.append((
            nomination_prompt,
            f"Observed commercial evidence IDs: {', '.join(map(str, nominate_ids))}\n{rendered}",
            _experimental_id_response_format("ad_ids", context_ids),
        ))
    first, last = proposed_ids[0], proposed_ids[-1]
    labelled_ids = tuple(
        segment_id for segment_id in context_ids
        if first - COMMERCIAL_PRESERVATION_FLANK_IDS
        <= segment_id
        <= last + COMMERCIAL_PRESERVATION_FLANK_IDS
    )
    requests.append((
        COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
        f"IDs to classify: {', '.join(map(str, labelled_ids))}\n{rendered}",
        _commercial_preservation_response_format(labelled_ids),
    ))
    side_ids = {
        "left": tuple(segment_id for segment_id in labelled_ids if segment_id < first),
        "right": tuple(segment_id for segment_id in labelled_ids if segment_id > last),
    }
    for side in ("left", "right"):
        for _ in range(COMMERCIAL_PRESERVATION_FLANK_STEPS):
            if not side_ids[side]:
                break
            outermost_index = context_ids.index(
                min(side_ids[side]) if side == "left" else max(side_ids[side])
            )
            if side == "left":
                next_ids = context_ids[
                    max(0, outermost_index - COMMERCIAL_PRESERVATION_FLANK_IDS):outermost_index
                ]
            else:
                next_ids = context_ids[
                    outermost_index + 1:outermost_index + 1 + COMMERCIAL_PRESERVATION_FLANK_IDS
                ]
            if not next_ids:
                break
            requests.append((
                COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
                f"IDs to classify: {', '.join(map(str, next_ids))}\n{rendered}",
                _commercial_preservation_response_format(next_ids),
            ))
            side_ids[side] = tuple(next_ids)
    if prefix_evidence_id is None:
        for candidate_id in proposed_ids:
            requests.append((
                COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT,
                f"Candidate ID to resolve: {candidate_id}\n{rendered}",
                _commercial_conflict_response_format(),
            ))
    else:
        for length in range(1, min(len(proposed_ids) - 1, COMMERCIAL_SPARSE_PREFIX_MAX_IDS) + 1):
            prefix_ids = tuple(proposed_ids[:length])
            requests.append((
                COMMERCIAL_PREFIX_ROLE_PROMPT,
                f"Prefix IDs: {', '.join(map(str, prefix_ids))}; "
                f"observed evidence ID: {prefix_evidence_id}\n{rendered}",
                _commercial_conflict_response_format(),
            ))
            requests.append((
                COMMERCIAL_PREFIX_CUE_PROMPT,
                f"IDs to classify: {', '.join(map(str, prefix_ids))}; "
                f"observed evidence ID: {prefix_evidence_id}\n{rendered}",
                _commercial_preservation_response_format(prefix_ids),
            ))
    return tuple(requests)

def _commercial_context_fit(backend, proposed_ids, *, nominate_ids, nomination_prompt, prefix_evidence_id):
    def fit(context_ids, rendered):
        return _measure_review_requests(
            backend,
            _commercial_review_requests(
                rendered, context_ids, proposed_ids,
                nominate_ids=nominate_ids,
                nomination_prompt=nomination_prompt,
                prefix_evidence_id=prefix_evidence_id,
            ),
        )
    return fit

def _commercial_preservation_review(
    backend, rendered, context_ids, proposed_ids, segments=None,
    prefix_evidence_id=None,
) -> None:
    """Require programme context around a proposed commercial cut."""
    proposed_ids = tuple(proposed_ids)
    labelled_ids = tuple(
        segment_id for segment_id in context_ids
        if proposed_ids[0] - COMMERCIAL_PRESERVATION_FLANK_IDS
        <= segment_id
        <= proposed_ids[-1] + COMMERCIAL_PRESERVATION_FLANK_IDS
    )

    def label(ids):
        preservation, _ = _generate_review(backend,
            COMMERCIAL_ENVELOPE_PRESERVATION_PROMPT,
            f"IDs to classify: {', '.join(map(str, ids))}\n{rendered}",
            response_format=_commercial_preservation_response_format(ids),
        )
        return _commercial_preservation_labels(preservation, ids)

    labels = label(labelled_ids)
    programme_ids = [
        segment_id for segment_id in proposed_ids
        if labels[str(segment_id)] in {"programme", "mixed"}
    ]
    if prefix_evidence_id is not None and programme_ids:
        first_commercial = next(
            (segment_id for segment_id in proposed_ids
             if labels[str(segment_id)] == "commercial"), None
        )
        prefix_ids = tuple(range(proposed_ids[0], first_commercial)) if first_commercial is not None else ()
        if (prefix_ids
                and programme_ids == list(prefix_ids)
                and prefix_evidence_id in proposed_ids
                and labels[str(prefix_evidence_id)] == "commercial"
                and segments is not None
                and len(prefix_ids) <= COMMERCIAL_SPARSE_PREFIX_MAX_IDS
                and float(segments[prefix_ids[-1]].end_s) - float(segments[prefix_ids[0]].start_s)
                <= COMMERCIAL_SPARSE_PREFIX_MAX_SECONDS
                and any(segment_id < proposed_ids[0]
                        and labels[str(segment_id)] in {"programme", "mixed"}
                        for segment_id in labelled_ids)):
            _worker_reporting.progress(
                "ads.detect.sparse.prefix.reviewing",
                f"checking commercial setup IDs {prefix_ids[0]}-{prefix_ids[-1]} before evidence ID {prefix_evidence_id}",
            )
            try:
                role_response, _ = _generate_review(backend,
                    COMMERCIAL_PREFIX_ROLE_PROMPT,
                    f"Prefix IDs: {', '.join(map(str, prefix_ids))}; observed evidence ID: {prefix_evidence_id}\n{rendered}",
                    response_format=_commercial_conflict_response_format(),
                )
                prefix_role = _parse_commercial_conflict_response(role_response)
                _worker_reporting.progress("ads.detect.sparse.prefix.role", f"whole-prefix role={prefix_role}")
                if prefix_role in {"commercial", "mixed"}:
                    cue_response, _ = _generate_review(backend,
                        COMMERCIAL_PREFIX_CUE_PROMPT,
                        f"IDs to classify: {', '.join(map(str, prefix_ids))}; observed evidence ID: {prefix_evidence_id}\n{rendered}",
                        response_format=_commercial_preservation_response_format(prefix_ids),
                    )
                    cue_labels = _commercial_preservation_labels(cue_response, prefix_ids)
                    rejected_ids = [
                        f"{segment_id}:{cue_labels[str(segment_id)]}"
                        for segment_id in prefix_ids
                        if cue_labels[str(segment_id)] != "commercial"
                    ]
                    _worker_reporting.progress(
                        "ads.detect.sparse.prefix.cues",
                        "all commercial" if not rejected_ids else "veto=" + ",".join(rejected_ids),
                    )
                    if (prefix_role == "commercial"
                            and all(cue_labels[str(segment_id)] == "commercial" for segment_id in prefix_ids)):
                        for segment_id in prefix_ids:
                            labels[str(segment_id)] = "commercial"
                        programme_ids = []
                        _worker_reporting.progress(
                            "ads.detect.sparse.prefix.resolved",
                            f"entire commercial setup IDs {prefix_ids[0]}-{prefix_ids[-1]} verified",
                        )
                    elif rejected_ids:
                        # A mixed/uncertain opening stays in the output. A
                        # later all-commercial suffix may still be removable.
                        for segment_id in prefix_ids:
                            labels[str(segment_id)] = cue_labels[str(segment_id)]
                        programme_ids = [
                            segment_id for segment_id in proposed_ids
                            if labels[str(segment_id)] in {"programme", "mixed"}
                        ]
            except Exception as error:  # noqa: BLE001 - unresolved prefix preserves audio
                _worker_reporting.progress(
                    "ads.detect.sparse.prefix.skipped",
                    f"commercial setup review failed: {type(error).__name__}: {error}",
                )
                raise ValueError("commercial setup review was invalid") from error
    if programme_ids and segments is not None and prefix_evidence_id is None:
        for segment_id in tuple(programme_ids):
            if labels[str(segment_id)] != "programme":
                continue
            text = segments[segment_id].text or ""
            if not (
                EXPLICIT_SPONSOR_CTA_RE.search(text) is not None
                or explicit_sponsor_destination_seen(text)
            ):
                continue
            _worker_reporting.progress(
                "ads.detect.commercial.conflict.reviewing",
                f"checking conflicting evidence on candidate ID {segment_id}",
            )
            try:
                response, _tokens = _generate_review(backend,
                    COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT,
                    f"Candidate ID to resolve: {segment_id}\n{rendered}",
                    response_format=_commercial_conflict_response_format(),
                )
                classification = _parse_commercial_conflict_response(response)
                if classification == "commercial":
                    labels[str(segment_id)] = "commercial"
                    programme_ids.remove(segment_id)
                    _worker_reporting.progress(
                        "ads.detect.commercial.conflict.resolved",
                        f"candidate ID {segment_id} resolved to commercial",
                    )
                else:
                    _worker_reporting.progress(
                        "ads.detect.commercial.conflict.preserved",
                        f"candidate ID {segment_id} confirmed as {classification}",
                    )
            except Exception as error:  # noqa: BLE001 - uncertain conflict resolution preserves source audio
                _worker_reporting.progress(
                    "ads.detect.commercial.conflict.skipped",
                    f"candidate ID {segment_id} conflict review failed: {type(error).__name__}: {error}",
                )

    if programme_ids:
        safe_first = max(programme_ids) + 1
        if (prefix_evidence_id is None
                or safe_first > prefix_evidence_id
                or any(labels[str(segment_id)] != "commercial"
                       for segment_id in range(safe_first, proposed_ids[-1] + 1))):
            raise ValueError(
                "programme preservation intersects the proposed cut at IDs "
                + ", ".join(map(str, programme_ids))
            )
        _worker_reporting.progress(
            "ads.detect.sparse.prefix.preserved",
            f"keeping disputed IDs through {safe_first - 1}; reviewing commercial suffix {safe_first}-{proposed_ids[-1]}",
        )
        proposed_ids = tuple(range(safe_first, proposed_ids[-1] + 1))

    first, last = proposed_ids[0], proposed_ids[-1]
    confirmed = {
        "left": any(
            segment_id < first and labels[str(segment_id)] in {"programme", "mixed"}
            for segment_id in labelled_ids
        ),
        "right": any(
            segment_id > last and labels[str(segment_id)] in {"programme", "mixed"}
            for segment_id in labelled_ids
        ),
    }
    side_ids = {
        "left": tuple(segment_id for segment_id in labelled_ids if segment_id < first),
        "right": tuple(segment_id for segment_id in labelled_ids if segment_id > last),
    }
    for side in ("left", "right"):
        for _ in range(COMMERCIAL_PRESERVATION_FLANK_STEPS):
            if confirmed[side] or not side_ids[side]:
                break
            outermost_index = context_ids.index(
                min(side_ids[side]) if side == "left" else max(side_ids[side])
            )
            if side == "left":
                next_ids = context_ids[
                    max(0, outermost_index - COMMERCIAL_PRESERVATION_FLANK_IDS):outermost_index
                ]
            else:
                next_ids = context_ids[
                    outermost_index + 1:outermost_index + 1 + COMMERCIAL_PRESERVATION_FLANK_IDS
                ]
            if not next_ids:
                break
            follow_up_labels = label(next_ids)
            confirmed[side] = any(
                follow_up_labels[str(segment_id)] in {"programme", "mixed"}
                for segment_id in next_ids
            )
            side_ids[side] = tuple(next_ids)
    if not confirmed["left"] or not confirmed["right"]:
        raise ValueError("programme preservation was not confirmed on both sides")
    return proposed_ids

def _commercial_envelope_preserved(
    ads_module, backend, segments, total_seconds, candidate_ids, *, nominate,
    nomination_prompt=COMMERCIAL_EVIDENCE_NOMINATION_PROMPT,
    context_flank_ids=None,
    prefix_evidence_id=None,
):
    """Return a verified commercial subset or ``None`` without weakening audio safety."""
    try:
        candidate_ids = tuple(candidate_ids)
        if candidate_ids != tuple(range(candidate_ids[0], candidate_ids[-1] + 1)):
            raise ValueError("commercial candidate is not contiguous")
        _candidate, context_ids, rendered = _commercial_recovery_context(
            ads_module, segments, candidate_ids[0], candidate_ids[-1], total_seconds,
            flank_limit=context_flank_ids,
            fit=_commercial_context_fit(
                backend, candidate_ids,
                nominate_ids=candidate_ids if nominate else None,
                nomination_prompt=nomination_prompt,
                prefix_evidence_id=prefix_evidence_id,
            ),
        )
        proposed_ids = candidate_ids
        if nominate:
            nomination, _ = _generate_review(backend,
                nomination_prompt,
                f"Observed commercial evidence IDs: {', '.join(map(str, candidate_ids))}\n{rendered}",
                response_format=_experimental_id_response_format("ad_ids", context_ids),
            )
            proposed_ids = _parse_experimental_ids(nomination, "ad_ids", context_ids, nonempty=True)
            if proposed_ids != tuple(range(proposed_ids[0], proposed_ids[-1] + 1)):
                raise ValueError("commercial nomination is not contiguous")
            if not set(candidate_ids).issubset(proposed_ids):
                raise ValueError("commercial nomination omitted observed evidence")
            # Rebuild and re-measure around the nominated whole candidate before
            # preservation; the nomination request itself is already spent.
            _candidate, context_ids, rendered = _commercial_recovery_context(
                ads_module, segments, proposed_ids[0], proposed_ids[-1], total_seconds,
                flank_limit=context_flank_ids,
                fit=_commercial_context_fit(
                    backend, proposed_ids,
                    nominate_ids=None,
                    nomination_prompt=nomination_prompt,
                    prefix_evidence_id=prefix_evidence_id,
                ),
            )
        proposed_ids = _commercial_preservation_review(
            backend, rendered, context_ids, proposed_ids, segments=segments,
            prefix_evidence_id=prefix_evidence_id,
        )
        return proposed_ids
    except Exception as error:  # noqa: BLE001 - incomplete commercial review preserves source audio
        _worker_reporting.progress(
            "ads.detect.recovery.skipped",
            f"commercial envelope preserved source audio: {type(error).__name__}: {error}",
        )
        return None

def _evidence_is_covered(segment_id, segments, detections):
    segment = segments[segment_id]
    seg_start, seg_end = float(segment.start_s), float(segment.end_s)
    return any(
        interval_contains(float(ad.start_s), float(ad.end_s), seg_start, seg_end)
        for ad in detections
    )

def recovered_confidence(observed: int, expected: int) -> float:
    """Map observed corroboration onto the recovered-span confidence band.

    `observed` and `expected` are integer evidence counts: how many of the
    signals a recovery looks for it actually found. The result is a receipt of
    that share, never the literal 1.0 a classification carries.
    """
    if expected <= 0:
        return RECOVERED_CONFIDENCE_FLOOR
    share = min(1.0, max(0.0, observed / expected))
    return round(
        RECOVERED_CONFIDENCE_FLOOR
        + (RECOVERED_CONFIDENCE_CEILING - RECOVERED_CONFIDENCE_FLOOR) * share,
        4,
    )
