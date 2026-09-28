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
from .commercial_preservation import recovered_confidence
from .constants import EXPLICIT_SPONSOR_CTA_RE, EXPLICIT_SPONSOR_NAME_MINIMUM_REPEATS, EXPLICIT_SPONSOR_NAME_WINDOW_SECONDS, EXPLICIT_SPONSOR_RECOVERY_MAX_SECONDS, EXPLICIT_SPONSOR_RECOVERY_MAX_SEGMENTS, EXPLICIT_SPONSOR_RESUMPTION_TAIL_SEGMENTS, MISSING_SUPPORT_SPONSOR_COMPATIBILITY_PATTERN
from .sponsor_evidence import _probe_opening_sponsor_interior, consecutive_preroll_start, count_sponsor_name_mentions, explicit_sponsor_anchor_ids, explicit_sponsor_destination_seen, explicit_sponsor_domain_seen, explicit_sponsor_name_phrases, explicit_sponsor_opening_pattern, sponsor_name_recurrence_text

def recover_unclaimed_explicit_sponsor_reads(ads_module, backend, segments, detections):
    """Recover or extend explicit host reads through verified content return."""
    recovered = []
    # Keep the support anchor private to this wrapper. Both archive regexes are
    # consulted inside detect_ads, so mutating either one changes base spans.
    opening_pattern = explicit_sponsor_opening_pattern(ads_module)
    for anchor_id in explicit_sponsor_anchor_ids(segments, opening_pattern):
        anchor = segments[anchor_id]
        requires_domain = re.search(
            MISSING_SUPPORT_SPONSOR_COMPATIBILITY_PATTERN,
            anchor.text,
            re.IGNORECASE,
        ) is not None
        _worker_reporting.progress(
            "ads.detect.recovery.nominated",
            f"raw anchor ID {anchor_id} at {float(anchor.start_s):.3f}s",
        )
        claimed = [*detections, *recovered]
        context_ids = [anchor_id]
        for segment_id in range(anchor_id + 1, len(segments)):
            if (
                len(context_ids) >= EXPLICIT_SPONSOR_RECOVERY_MAX_SEGMENTS
                or segments[segment_id].start_s - anchor.start_s > EXPLICIT_SPONSOR_RECOVERY_MAX_SECONDS
            ):
                break
            context_ids.append(segment_id)
        if len(context_ids) < 2:
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                f"explicit sponsor anchor at {anchor.start_s:.3f} had no following content boundary",
            )
            continue

        # Two independent signals, as before, but the second one no longer has
        # to be an address. A sponsor whose domain is spoken as ordinary words
        # is invisible to every address pattern there is, and Giant Bombcast
        # 955's ninety-second read was skipped for exactly that: no dot, no
        # http, and a `.town` top-level domain no list had. Its own name came
        # back thirteen times, which is what a read is.
        name_phrases = explicit_sponsor_name_phrases(anchor.text, opening_pattern)
        name_counts = {}
        actual_domain_seen = False
        destination_seen = False
        cta_seen = False
        evidence_id = None
        for segment_id in context_ids:
            text = segments[segment_id].text
            actual_domain_seen = actual_domain_seen or explicit_sponsor_domain_seen(text)
            destination_seen = destination_seen or explicit_sponsor_destination_seen(text)
            cta_seen = cta_seen or EXPLICIT_SPONSOR_CTA_RE.search(text) is not None
            if (
                name_phrases
                and segments[segment_id].start_s - anchor.start_s <= EXPLICIT_SPONSOR_NAME_WINDOW_SECONDS
            ):
                count_sponsor_name_mentions(
                    text if segment_id != anchor_id else sponsor_name_recurrence_text(text, opening_pattern),
                    name_phrases,
                    name_counts,
                )
            name_repeated = any(
                count >= EXPLICIT_SPONSOR_NAME_MINIMUM_REPEATS for count in name_counts.values()
            )
            corroboration_seen = (
                actual_domain_seen if requires_domain else destination_seen or name_repeated
            )
            if cta_seen and corroboration_seen:
                evidence_id = segment_id
                break

        if evidence_id is None:
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                f"unclaimed explicit sponsor anchor at {anchor.start_s:.3f} had no bounded CTA/domain evidence",
            )
            continue
        recovered_start = consecutive_preroll_start(
            ads_module, backend, segments, anchor_id
        )
        # Verify every cue between the anchor and the evidence. The former
        # implementation jumped straight to the evidence and could therefore
        # accumulate a CTA and destination across intervening editorial speech.
        verified_end_id = anchor_id
        interior_verified = True
        try:
            candidate_ids = range(anchor_id + 1, evidence_id + 1)
            for candidate_id in candidate_ids:
                candidate = segments[candidate_id]
                previous = segments[verified_end_id]
                if any(
                    float(ad.start_s) <= float(candidate.start_s) + 0.5
                    and float(ad.end_s) >= float(candidate.end_s) - 0.5
                    and float(ad.start_s) <= float(previous.end_s) + 2.0
                    for ad in claimed
                ):
                    verified_end_id = candidate_id
                    continue
                _worker_reporting.progress(
                    "ads.detect.recovery.reviewing",
                    f"checking explicit candidate ID {candidate_id} before evidence ID {evidence_id}",
                )
                if recovered_start == 0.0 and anchor_id == 1:
                    include = _probe_opening_sponsor_interior(
                        ads_module,
                        backend,
                        segments,
                        anchor_id,
                        evidence_id,
                        candidate_id,
                        name_phrases[0] if name_phrases else "named",
                    )
                else:
                    include = ads_module._probe_boundary_candidate(  # noqa: SLF001
                        candidate_id,
                        verified_end_id,
                        "right",
                        segments,
                        backend,
                    )
                if include is True:
                    verified_end_id = candidate_id
                    continue
                interior_verified = False
                break
        except Exception as error:  # noqa: BLE001 - uncertain recovery preserves source audio
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                f"explicit whole-span review failed at {anchor.start_s:.3f}: "
                f"{type(error).__name__}: {error}",
            )
            continue
        if not interior_verified:
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                f"explicit whole-span review found programme before evidence ID {evidence_id}",
            )
            continue
        content_start_id = None
        verifier_end = min(
            context_ids[-1],
            evidence_id + EXPLICIT_SPONSOR_RESUMPTION_TAIL_SEGMENTS,
        )
        try:
            for candidate_id in range(evidence_id + 1, verifier_end + 1):
                candidate = segments[candidate_id]
                previous = segments[verified_end_id]
                if any(
                    float(ad.start_s) <= float(candidate.start_s) + 0.5
                    and float(ad.end_s) >= float(candidate.end_s) - 0.5
                    and float(ad.start_s) <= float(previous.end_s) + 2.0
                    for ad in claimed
                ):
                    verified_end_id = candidate_id
                    continue
                include = ads_module._probe_boundary_candidate(  # noqa: SLF001
                    candidate_id,
                    verified_end_id,
                    "right",
                    segments,
                    backend,
                )
                if include is True:
                    verified_end_id = candidate_id
                    continue
                if include is False:
                    content_start_id = candidate_id
                break
        except Exception as error:  # noqa: BLE001 - uncertain fallback boundaries never cut audio
            _worker_reporting.progress(
                "ads.detect.recovery.skipped",
                f"explicit sponsor verifier failed at {anchor.start_s:.3f}: {type(error).__name__}: {error}",
            )
            continue
        connected_ending_ads = [
            ad for ad in claimed
            if float(ad.start_s) <= float(segments[verified_end_id].end_s) + 2.0
            and float(ad.end_s) >= float(segments[verified_end_id].start_s)
        ]
        if content_start_id is None:
            if connected_ending_ads:
                recovered_end = max(float(ad.end_s) for ad in connected_ending_ads)
            else:
                _worker_reporting.progress(
                    "ads.detect.recovery.skipped",
                    f"explicit sponsor verifier found no content return after {evidence_id}",
                )
                continue
        else:
            recovered_end = ads_module._last_meaningful_ad_end(  # noqa: SLF001
                content_start_id,
                anchor_id,
                segments,
            )
            if connected_ending_ads:
                recovered_end = max(
                    recovered_end,
                    max(float(ad.end_s) for ad in connected_ending_ads),
                )
        overlapping_ads = [
            ad for ad in claimed
            if float(ad.start_s) < recovered_end + 2.0
            and float(ad.end_s) > recovered_start - 2.0
        ]
        if (
            overlapping_ads
            and recovered_start >= min(float(ad.start_s) for ad in overlapping_ads)
            and recovered_end <= max(float(ad.end_s) for ad in overlapping_ads)
        ):
            continue
        # The receipt is the share of the recovery contract's corroboration
        # that was actually observed: the call to action that found the
        # evidence, a spoken address, any destination, and the sponsor's name
        # coming back. A read with one of those is weaker evidence than a read
        # with all four, and the reported confidence says which one this is.
        confidence = recovered_confidence(
            sum((
                cta_seen,
                actual_domain_seen,
                destination_seen,
                name_repeated,
            )),
            4,
        )
        recovered.append(
            ads_module.AdSegment(  # noqa: SLF001 - preserve legacy detection result type
                # The fallback's proof is the full explicit host-read cue. Its
                # natural sponsor lead-in can precede the regex phrase, so do
                # not retain it by token-refining this worker-only recovery.
                recovered_start,
                recovered_end,
                confidence,
                "sponsor_read",
            )
        )

    if not recovered:
        return detections
    merged = ads_module._merge_adjacent(  # noqa: SLF001 - retain legacy overlap semantics
        sorted([*detections, *recovered], key=lambda ad: ad.start_s)
    )
    evidence = ", ".join(f"{ad.start_s:.3f}-{ad.end_s:.3f}" for ad in recovered)
    _worker_reporting.progress("ads.detect.recovered", f"{len(recovered)} spans: {evidence}")
    return merged
