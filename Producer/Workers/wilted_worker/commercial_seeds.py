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
from .commercial_preservation import _commercial_envelope_preserved, _evidence_is_covered, recovered_confidence
from .constants import COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_IDS, COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_SECONDS, COMMERCIAL_RECOVERY_MAX_CANDIDATES, COMMERCIAL_SPARSE_CONTEXT_FLANK_IDS, COMMERCIAL_SPARSE_GAP_MIN_SECONDS, COMMERCIAL_SPARSE_MAX_ENVELOPE_SECONDS, COMMERCIAL_SPARSE_MAX_SECONDS, COMMERCIAL_SPARSE_TRANSITION_MAX_CHARS, COMMERCIAL_SPARSE_TRANSITION_MAX_SECONDS, EXPLICIT_SPONSOR_CTA_RE
from .sponsor_evidence import explicit_sponsor_destination_seen

def commercial_evidence_seed_ids(segments, detections):
    """Return de-duplicated adjacent CTA-plus-destination evidence windows.

    These are nominations only.  The archive's all-content classifications are
    intentionally not reinterpreted here, and any cue already covered by an
    archive detection is excluded rather than extended by this recovery.
    """
    seeds = []
    for first in range(len(segments)):
        if _evidence_is_covered(first, segments, detections):
            continue
        last_limit = min(len(segments), first + COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_IDS)
        window = []
        for segment_id in range(first, last_limit):
            if _evidence_is_covered(segment_id, segments, detections):
                break
            if float(segments[segment_id].start_s) - float(segments[first].start_s) > COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_SECONDS:
                break
            window.append(segment_id)
            # Speech-to-text may split a phrase at any cue boundary ("dot" /
            # "com", "get" / "started").  Search every bounded contiguous
            # subwindow as joined speech, then retain the smallest exact cue
            # range that carries both signals.
            evidence_windows = []
            for sub_first in range(len(window)):
                for sub_last in range(sub_first, len(window)):
                    evidence_ids = tuple(window[sub_first:sub_last + 1])
                    joined = " ".join(segments[item].text or "" for item in evidence_ids)
                    if (EXPLICIT_SPONSOR_CTA_RE.search(joined) is not None
                            and explicit_sponsor_destination_seen(joined)):
                        evidence_windows.append(evidence_ids)
            if not evidence_windows:
                continue
            evidence_ids = min(
                evidence_windows,
                key=lambda ids: (len(ids), ids[0], ids[-1]),
            )
            seeds.append(evidence_ids)
            break
    # Adjacent scans naturally rediscover the same CTA/destination pair.  Join
    # intersecting seed windows before inference so one commercial observation
    # consumes at most one nomination/preservation pair.
    merged = []
    for seed in sorted(set(seeds), key=lambda ids: (ids[0], ids[-1])):
        if merged and seed[0] <= merged[-1][-1] + 1:
            merged[-1] = tuple(range(merged[-1][0], max(merged[-1][-1], seed[-1]) + 1))
        else:
            merged.append(seed)
    return tuple(merged[:COMMERCIAL_RECOVERY_MAX_CANDIDATES])

def recover_commercial_evidence_reads(ads_module, backend, segments, detections, total_seconds):
    """Recover unanchored host reads only from reviewed CTA/destination evidence."""
    recovered = []
    for evidence_ids in commercial_evidence_seed_ids(segments, detections):
        first, last = evidence_ids[0], evidence_ids[-1]
        _worker_reporting.progress(
            "ads.detect.commercial.nominated",
            f"CTA/destination evidence IDs {first}-{last}",
        )
        proposed_ids = _commercial_envelope_preserved(
            ads_module, backend, segments, total_seconds, evidence_ids, nominate=True
        )
        if proposed_ids is None:
            continue
        start_s = float(segments[proposed_ids[0]].start_s)
        end_s = float(segments[proposed_ids[-1]].end_s)
        if any(float(ad.start_s) < end_s and float(ad.end_s) > start_s for ad in [*detections, *recovered]):
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                f"commercial evidence IDs {first}-{last} overlapped an existing cut",
            )
            continue
        # The receipt is how sharp the evidence was: a seed that sits in one
        # cue is a tighter observation than one spread across a window, and a
        # nomination that stayed on the observed evidence is a tighter read
        # than one that widened it.
        confidence = recovered_confidence(
            sum((
                True,
                len(evidence_ids) == 1,
                proposed_ids == evidence_ids,
            )),
            3,
        )
        recovered.append(ads_module.AdSegment(start_s, end_s, confidence, "sponsor_read"))
    if not recovered:
        return detections
    merged = ads_module._merge_adjacent(  # noqa: SLF001 - preserve legacy merge shape
        sorted([*detections, *recovered], key=lambda ad: ad.start_s)
    )
    evidence = ", ".join(f"{ad.start_s:.3f}-{ad.end_s:.3f}" for ad in recovered)
    _worker_reporting.progress("ads.detect.recovered", f"{len(recovered)} commercial-evidence spans: {evidence}")
    return merged

def sparse_commercial_seeds(segments, detections, audit):
    """Nominate dropped classifier positives and whole short commercial cues.

    A short surviving cut is reviewed only when its one fully covered cue also
    carries both a call to action and a destination. That is a bounded reason
    to look for an earlier host read, never a reason to extend the cut itself.
    """
    seeds = []
    for candidate in audit.candidates:
        if candidate.kind != "positive-missing-final-span" or len(candidate.ids) != 1:
            continue
        segment_id = candidate.ids[0]
        if 0 <= segment_id < len(segments) and not any(
            float(ad.start_s) < float(segments[segment_id].end_s)
            and float(ad.end_s) > float(segments[segment_id].start_s)
            for ad in detections
        ):
            seeds.append((segment_id, None))
    for ad in detections:
        start_s, end_s = float(ad.start_s), float(ad.end_s)
        if not 0 < end_s - start_s <= COMMERCIAL_SPARSE_MAX_SECONDS:
            continue
        covered = [
            segment_id for segment_id, segment in enumerate(segments)
            if abs(float(segment.start_s) - start_s) <= 0.01
            and abs(float(segment.end_s) - end_s) <= 0.01
        ]
        if len(covered) != 1:
            continue
        segment_id = covered[0]
        text = segments[segment_id].text or ""
        if (EXPLICIT_SPONSOR_CTA_RE.search(text) is not None
                and explicit_sponsor_destination_seen(text)):
            seeds.append((segment_id, ad))
    # The already verified short cut is the strongest observation; review it
    # before spending calls on classifier positives that produced no cut.
    seeds.sort(key=lambda seed: (seed[1] is None, seed[0]))
    return tuple(seeds)

def sparse_pause_envelope(segments, seed_id):
    """Return the local pause-bracketed passage around one observed ad cue.

    A pause is only a proposed boundary. The model must still classify every
    included cue and find programme on both sides before any audio is removed.
    Reject a passage with no nearby pauses instead of guessing its extent.
    """
    seed_start = float(segments[seed_id].start_s)
    first = None
    for left in range(seed_id - 1, -1, -1):
        if seed_start - float(segments[left].start_s) > COMMERCIAL_SPARSE_MAX_ENVELOPE_SECONDS:
            break
        gap = float(segments[left + 1].start_s) - float(segments[left].end_s)
        if gap >= COMMERCIAL_SPARSE_GAP_MIN_SECONDS:
            first = left + 1
            break
    if first is None:
        return None
    last = None
    for right in range(seed_id, len(segments) - 1):
        if float(segments[right].end_s) - seed_start > COMMERCIAL_SPARSE_MAX_ENVELOPE_SECONDS:
            break
        gap = float(segments[right + 1].start_s) - float(segments[right].end_s)
        if gap >= COMMERCIAL_SPARSE_GAP_MIN_SECONDS:
            last = right
            break
    if last is None or first == 0 or last >= len(segments) - 1:
        return None
    # Several tiny backchannels can sit between a read's meaningful sign-off
    # and the actual silence. Keep those in the programme side of the review;
    # removing less audio is the safe choice when their role is unclear.
    while last > seed_id and (
        float(segments[last].end_s) - float(segments[last].start_s)
        <= COMMERCIAL_SPARSE_TRANSITION_MAX_SECONDS
        and len((segments[last].text or "").strip()) <= COMMERCIAL_SPARSE_TRANSITION_MAX_CHARS
    ):
        last -= 1
    if float(segments[last].end_s) - float(segments[first].start_s) > COMMERCIAL_SPARSE_MAX_ENVELOPE_SECONDS:
        return None
    return tuple(range(first, last + 1))

def recover_sparse_commercial_reads(
    ads_module, backend, segments, detections, total_seconds, audit
):
    """Recover a complete read around sparse classifier evidence, or keep audio."""
    recovered = list(detections)
    reviewed_envelopes = set()
    for segment_id, original in sparse_commercial_seeds(segments, detections, audit):
        candidate_ids = sparse_pause_envelope(segments, segment_id)
        if candidate_ids is None or candidate_ids in reviewed_envelopes:
            continue
        reviewed_envelopes.add(candidate_ids)
        if len(reviewed_envelopes) > COMMERCIAL_RECOVERY_MAX_CANDIDATES:
            break
        _worker_reporting.progress(
            "ads.detect.sparse.nominated",
            f"reviewing pause-bracketed IDs {candidate_ids[0]}-{candidate_ids[-1]} around evidence ID {segment_id}",
        )
        proposed_ids = _commercial_envelope_preserved(
            ads_module, backend, segments, total_seconds, candidate_ids,
            nominate=False, context_flank_ids=COMMERCIAL_SPARSE_CONTEXT_FLANK_IDS,
            prefix_evidence_id=segment_id,
        )
        if proposed_ids is None:
            continue
        start_s = float(segments[proposed_ids[0]].start_s)
        end_s = float(segments[proposed_ids[-1]].end_s)
        if original is not None and not (
            start_s <= float(original.start_s) and end_s >= float(original.end_s)
        ):
            _worker_reporting.progress("ads.detect.sparse.skipped", f"proposal did not contain existing cut at ID {segment_id}")
            continue
        if original is not None and (
            abs(start_s - float(original.start_s)) <= 0.01
            and abs(end_s - float(original.end_s)) <= 0.01
        ):
            continue
        if any(
            ad is not original and float(ad.start_s) < end_s and float(ad.end_s) > start_s
            for ad in recovered
        ):
            _worker_reporting.progress("ads.detect.sparse.skipped", f"proposal overlaps another cut at ID {segment_id}")
            continue
        confidence = recovered_confidence(2, 3)
        label = "sponsor_read"
        if original is not None:
            confidence = min(confidence, float(original.confidence))
            label = original.label
            recovered.remove(original)
        recovered.append(ads_module.AdSegment(start_s, end_s, confidence, label))
        _worker_reporting.progress(
            "ads.detect.sparse.recovered",
            f"ID {segment_id} verified as complete commercial {start_s:.3f}-{end_s:.3f}",
        )
    return sorted(recovered, key=lambda ad: float(ad.start_s))

def _constrained_id(ads_module, backend, prompt, field, window_ids, permitted, segments):
    """Ask one bounded ID question and return a validated supplied ID."""
    response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
        backend,
        prompt,
        ads_module._render_segments_bounded(window_ids, segments),  # noqa: SLF001
        ads_module._id_response_format(field, permitted),  # noqa: SLF001
    )
    parsed = json.loads(response)
    if not isinstance(parsed, dict) or set(parsed) != {field}:
        raise ValueError(f"{field} response must contain exactly {field}")
    value = parsed[field]
    if isinstance(value, bool) or not isinstance(value, int) or value not in permitted:
        raise ValueError(f"{field} response must be one of the supplied IDs, got {value!r}")
    return value
