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
from .recovery_policy import overlaps_blocked_house_region
from .constants import COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_IDS, COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_SECONDS, COMMERCIAL_RECOVERY_MAX_CANDIDATE_SECONDS, COMMERCIAL_RECOVERY_MAX_CANDIDATES, COMMERCIAL_SPARSE_CONTEXT_FLANK_IDS, COMMERCIAL_SPARSE_GAP_MIN_SECONDS, COMMERCIAL_SPARSE_MAX_ENVELOPE_SECONDS, COMMERCIAL_SPARSE_MAX_SECONDS, COMMERCIAL_SPARSE_TRANSITION_MAX_CHARS, COMMERCIAL_SPARSE_TRANSITION_MAX_SECONDS, EXPLICIT_SPONSOR_CTA_RE
from .interval_geometry import interval_contains, intervals_overlap
from .sponsor_evidence import explicit_sponsor_destination_seen

def commercial_evidence_seed_ids(segments, detections):
    """Return de-duplicated adjacent CTA-plus-destination evidence windows.

    These are nominations only.  The archive's all-content classifications are
    intentionally not reinterpreted here, and any cue already covered by an
    archive detection is excluded rather than extended by this recovery.

    A destination without a call to action is also a nomination when it sits
    beside a primary seed or an existing cut: produced spots may sign off with
    only a domain.  Such neighbour seeds never stand alone far from either.
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
    # A produced spot can end with only a destination ("blitzy dot com").  Run
    # the same bounded search for destination-only windows, but nominate one
    # only when it sits close to a primary seed or an existing detection.
    neighbour_seeds = []
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
            evidence_windows = []
            for sub_first in range(len(window)):
                for sub_last in range(sub_first, len(window)):
                    evidence_ids = tuple(window[sub_first:sub_last + 1])
                    joined = " ".join(segments[item].text or "" for item in evidence_ids)
                    if (EXPLICIT_SPONSOR_CTA_RE.search(joined) is None
                            and explicit_sponsor_destination_seen(joined)):
                        evidence_windows.append(evidence_ids)
            if not evidence_windows:
                continue
            neighbour_seeds.append(min(
                evidence_windows,
                key=lambda ids: (len(ids), ids[0], ids[-1]),
            ))
            break
    anchors = [
        (float(segments[ids[0]].start_s), float(segments[ids[-1]].end_s))
        for ids in seeds
    ]
    anchors.extend((float(ad.start_s), float(ad.end_s)) for ad in detections)
    neighbour_seeds = [
        ids for ids in neighbour_seeds
        if any(
            _neighbour_seed_is_near(
                float(segments[ids[0]].start_s),
                float(segments[ids[-1]].end_s),
                anchor_start,
                anchor_end,
            )
            for anchor_start, anchor_end in anchors
        )
    ]
    # Adjacent scans naturally rediscover the same CTA/destination pair.  Join
    # intersecting seed windows before inference so one commercial observation
    # consumes at most one nomination/preservation pair.
    primary_seeds = set(seeds)
    merged = []
    merged_has_primary = []
    for seed in sorted(primary_seeds | set(neighbour_seeds), key=lambda ids: (ids[0], ids[-1])):
        if merged and seed[0] <= merged[-1][-1] + 1:
            merged[-1] = tuple(range(merged[-1][0], max(merged[-1][-1], seed[-1]) + 1))
            merged_has_primary[-1] = merged_has_primary[-1] or seed in primary_seeds
        else:
            merged.append(seed)
            merged_has_primary.append(seed in primary_seeds)
    primary_windows = [
        ids for ids, has_primary in zip(merged, merged_has_primary) if has_primary
    ]
    neighbour_windows = [
        ids for ids, has_primary in zip(merged, merged_has_primary) if not has_primary
    ]
    selected = primary_windows[:COMMERCIAL_RECOVERY_MAX_CANDIDATES]
    selected.extend(
        neighbour_windows[:COMMERCIAL_RECOVERY_MAX_CANDIDATES - len(selected)]
    )
    return tuple(sorted(selected, key=lambda ids: (ids[0], ids[-1])))

def _neighbour_seed_is_near(neighbour_start, neighbour_end, anchor_start, anchor_end):
    """Return whether one evidence window is within the neighbour bound of another."""
    if intervals_overlap(neighbour_start, neighbour_end, anchor_start, anchor_end):
        return True
    if neighbour_start >= anchor_end:
        return neighbour_start - anchor_end <= COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_SECONDS
    return anchor_start - neighbour_end <= COMMERCIAL_RECOVERY_EVIDENCE_WINDOW_SECONDS

def _ids_overlap_blocked_house_region(segments, ids, held_spans):
    return any(
        overlaps_blocked_house_region(
            held_spans, float(segments[segment_id].start_s), float(segments[segment_id].end_s)
        )
        for segment_id in ids
    )

def recover_commercial_evidence_reads(
    ads_module, backend, segments, detections, total_seconds,
    remove_self_promotion: bool = False, held_spans: list | None = None,
):
    """Recover unanchored host reads only from reviewed CTA/destination evidence."""
    recovered = []
    for evidence_ids in commercial_evidence_seed_ids(segments, detections):
        if _ids_overlap_blocked_house_region(segments, evidence_ids, held_spans):
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                "commercial evidence overlaps known house material kept by policy",
            )
            continue
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
        if _ids_overlap_blocked_house_region(segments, proposed_ids, held_spans):
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                "commercial proposal overlaps known house material kept by policy",
            )
            continue
        start_s = float(segments[proposed_ids[0]].start_s)
        end_s = float(segments[proposed_ids[-1]].end_s)
        if any(intervals_overlap(float(ad.start_s), float(ad.end_s), start_s, end_s) for ad in [*detections, *recovered]):
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
        recovered.append(ads_module.AdSegment(
            start_s, end_s, confidence, "sponsor_read", kinds=(ads_module.AD_KIND_PAID,),
        ))
    if not recovered:
        return detections
    if not remove_self_promotion:
        house_kind = ads_module.AD_KIND_HOUSE
        non_house_detections = [
            ad for ad in detections
            if house_kind not in ads_module.ad_segment_kinds(ad)
            and getattr(ad, "label", None) not in {"self_promo", "newsletter_pitch"}
        ]
        house_detections = [ad for ad in detections if ad not in non_house_detections]
        merged = ads_module._merge_adjacent(  # noqa: SLF001
            sorted([*non_house_detections, *recovered], key=lambda ad: ad.start_s)
        )
        merged.extend(house_detections)
        merged.sort(key=lambda ad: ad.start_s)
    else:
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
            intervals_overlap(
                float(ad.start_s), float(ad.end_s),
                float(segments[segment_id].start_s), float(segments[segment_id].end_s),
            )
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
    ads_module, backend, segments, detections, total_seconds, audit,
    remove_self_promotion: bool = False, held_spans: list | None = None,
):
    """Recover a complete read around sparse classifier evidence, or keep audio."""
    recovered = list(detections)
    reviewed_envelopes = set()
    house_kind = ads_module.AD_KIND_HOUSE
    paid_kind = ads_module.AD_KIND_PAID
    for segment_id, original in sparse_commercial_seeds(segments, detections, audit):
        if _ids_overlap_blocked_house_region(segments, [segment_id], held_spans):
            _worker_reporting.progress(
                "ads.detect.sparse.skipped",
                f"evidence ID {segment_id} is known house material kept by policy",
            )
            continue
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
        if _ids_overlap_blocked_house_region(segments, proposed_ids, held_spans):
            _worker_reporting.progress(
                "ads.detect.sparse.skipped",
                f"proposal around evidence ID {segment_id} overlaps known house material",
            )
            continue
        start_s = float(segments[proposed_ids[0]].start_s)
        end_s = float(segments[proposed_ids[-1]].end_s)
        if original is not None and not interval_contains(
            start_s, end_s, float(original.start_s), float(original.end_s)
        ):
            _worker_reporting.progress("ads.detect.sparse.skipped", f"proposal did not contain existing cut at ID {segment_id}")
            continue
        if original is not None and (
            abs(start_s - float(original.start_s)) <= 0.01
            and abs(end_s - float(original.end_s)) <= 0.01
        ):
            continue
        overlapping = [
            ad for ad in recovered
            if ad is not original
            and intervals_overlap(float(ad.start_s), float(ad.end_s), start_s, end_s)
        ]
        if overlapping:
            union_start = min(start_s, *(float(ad.start_s) for ad in overlapping))
            union_end = max(end_s, *(float(ad.end_s) for ad in overlapping))
            if original is not None:
                union_start = min(union_start, float(original.start_s))
                union_end = max(union_end, float(original.end_s))
            if union_end - union_start <= COMMERCIAL_RECOVERY_MAX_CANDIDATE_SECONDS:
                merged_ads = [*overlapping]
                if original is not None:
                    merged_ads.append(original)
                has_disallowed_house = not remove_self_promotion and any(
                    house_kind in ads_module.ad_segment_kinds(ad)
                    or getattr(ad, "label", None) in {"self_promo", "newsletter_pitch"}
                    for ad in merged_ads
                )
                if has_disallowed_house:
                    _worker_reporting.progress(
                        "ads.detect.sparse.skipped",
                        f"disallowed house material cannot enter merged cut at ID {segment_id}",
                    )
                    continue

                removed = {id(ad) for ad in merged_ads}
                recovered[:] = [ad for ad in recovered if id(ad) not in removed]
                confidence = min(
                    recovered_confidence(2, 3),
                    *(float(ad.confidence) for ad in merged_ads),
                )
                all_kinds = set()
                for ad in merged_ads:
                    all_kinds.update(ads_module.ad_segment_kinds(ad))
                merged_kinds = tuple(sorted(all_kinds))
                if paid_kind in merged_kinds:
                    label = "sponsor_read"
                elif house_kind in merged_kinds:
                    label = "self_promo"
                else:
                    labels = {ad.label for ad in merged_ads}
                    label = labels.pop() if len(labels) == 1 else merged_ads[0].label
                recovered.append(ads_module.AdSegment(
                    union_start, union_end, confidence, label, kinds=merged_kinds,
                ))
                _worker_reporting.progress(
                    "ads.detect.sparse.merged",
                    f"ID {segment_id} merged verified commercial {union_start:.3f}-{union_end:.3f}",
                )
                continue
            _worker_reporting.progress("ads.detect.sparse.skipped", f"proposal overlaps another cut at ID {segment_id}")
            continue

        if original is not None and not remove_self_promotion and (
            house_kind in ads_module.ad_segment_kinds(original)
            or getattr(original, "label", None) in {"self_promo", "newsletter_pitch"}
        ):
            _worker_reporting.progress(
                "ads.detect.sparse.skipped",
                f"known house material at ID {segment_id} cannot be expanded when removal is disabled",
            )
            continue

        confidence = recovered_confidence(2, 3)
        candidate_kinds = set()
        if original is not None:
            confidence = min(confidence, float(original.confidence))
            candidate_kinds.update(ads_module.ad_segment_kinds(original))
            recovered.remove(original)
        else:
            candidate_kinds.add(paid_kind)
        final_kinds = tuple(sorted(candidate_kinds))
        if paid_kind in final_kinds:
            label = "sponsor_read"
        elif house_kind in final_kinds:
            label = "self_promo"
        elif original is not None:
            label = original.label
        else:
            label = "sponsor_read"
        recovered.append(ads_module.AdSegment(start_s, end_s, confidence, label, kinds=final_kinds))
        _worker_reporting.progress(
            "ads.detect.sparse.recovered",
            f"ID {segment_id} verified as complete commercial {start_s:.3f}-{end_s:.3f}",
        )
    return sorted(recovered, key=lambda ad: float(ad.start_s))

def _constrained_id(ads_module, backend, prompt, field, window_ids, permitted, segments):
    """Ask one bounded ID question and return a validated supplied ID."""
    from .commercial_preservation import _generate_review

    # Never review a head/tail excerpt as though it were the complete cue.
    # Measurement rejects an oversized request before the auditing generation
    # path can mistake a local, unanswered review for a failed model run.
    rendered = "\n".join(
        ads_module._segment_prefix(index, segments[index]) + segments[index].text
        for index in window_ids
    )
    response, _tokens = _generate_review(
        backend,
        prompt,
        rendered,
        response_format=ads_module._id_response_format(field, permitted),  # noqa: SLF001
    )
    parsed = json.loads(response)
    if not isinstance(parsed, dict) or set(parsed) != {field}:
        raise ValueError(f"{field} response must contain exactly {field}")
    value = parsed[field]
    if isinstance(value, bool) or not isinstance(value, int) or value not in permitted:
        raise ValueError(f"{field} response must be one of the supplied IDs, got {value!r}")
    return value
