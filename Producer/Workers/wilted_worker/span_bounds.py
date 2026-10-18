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
from .boundary_review import complete_fragment_visible, record_held_span, review_candidate_span
from .commercial_seeds import _constrained_id
from .constants import AD_POD_CONTINUATION_MAX_GAP_SECONDS, AD_POD_CONTINUATION_MAX_SECONDS, AD_POD_CONTINUATION_MAX_SEGMENTS, COMMERCIAL_RECOVERY_CONTEXT_CHARS, MAXIMUM_SINGLE_AD_SHARE, MAXIMUM_TOTAL_AD_SHARE, MAXIMUM_UNCONFIRMED_AD_SHARE, MINIMUM_PROGRAMME_SHARE, OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS
from .interval_geometry import intervals_overlap
from .prompts import AD_POD_CONTINUATION_PROMPT, OVERSIZED_SPAN_CONFIRM_PROMPT, OVERSIZED_SPAN_RESCAN_PROMPT


def _resize_one_oversized_span(
    ads_module, backend, segments, ad, total_seconds, rebase_anchor_ids=frozenset(),
    held_spans=None,
):
    """Review one too-large span and return `(outcome, segment)`.

    Delegates to the shrink-only review loop in boundary_review.
    """
    return review_candidate_span(
        ads_module, backend, segments, ad, total_seconds, rebase_anchor_ids, held_spans
    )


def _rescan_unconfirmed_oversized_span(ads_module, backend, segments, ad):
    """Re-examine a span the first review could not place a boundary in.

    Deliberately not the same question asked twice. The first review looks for
    where the programme resumes and a passage that is advertising end to end
    has no such point, so repeating it learns nothing. This asks the opposite
    question -- what evidence says this was ever an advertisement -- and names
    the programme content most often mistaken for one. A sponsor read carries a
    sponsor, an offer, a destination; a news segment misread as an ad carries
    none of them, and that is the difference size cannot see.
    """
    span_ids = [
        segment_id for segment_id, segment in enumerate(segments)
        if intervals_overlap(float(segment.start_s), float(segment.end_s), float(ad.start_s), float(ad.end_s))
    ]
    if len(span_ids) < 2:
        # The first review already refuses a span it cannot see as a passage,
        # and asking the second question about one segment is asking it to
        # vouch for a single cue: a lone segment carries neither the run of
        # programme a boundary needs nor the recurrence advertising evidence
        # needs, and a confirmation that rests on it is not evidence of
        # anything. Rejecting costs at most leaving the span to the size guard.
        _worker_reporting.progress(
            "ads.detect.span.rescan.rejected",
            f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} covers fewer than two segments; "
            "a passage that short cannot be vouched for",
        )
        return False
    if len(span_ids) > OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS:
        _worker_reporting.progress("ads.detect.span.rescan.skipped", "complete span exceeds the cue budget")
        return False
    window_ids = span_ids
    if not complete_fragment_visible(ads_module, window_ids, segments):
        _worker_reporting.progress("ads.detect.span.rescan.skipped", "complete span exceeds the text budget")
        return False
    try:
        evidence_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_RESCAN_PROMPT, "advertisement_evidence_id",
            window_ids, [-1, *window_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        _worker_reporting.progress("ads.detect.span.rescan.skipped", f"rescan failed: {type(error).__name__}: {error}")
        return False
    if evidence_id == -1:
        _worker_reporting.progress(
            "ads.detect.span.rescan.rejected",
            f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} carries no advertising evidence on a second read",
        )
        return False
    try:
        programme_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_CONFIRM_PROMPT, "program_id",
            window_ids, [-1, *window_ids], segments,
        )
    except Exception as error:  # An incomplete independent review never authorizes a cut.
        _worker_reporting.progress("ads.detect.span.rescan.skipped", f"confirmation failed: {type(error).__name__}")
        return False
    if programme_id != -1:
        return False
    _worker_reporting.progress(
        "ads.detect.span.rescan.confirmed",
        f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} is advertising; evidence at ID {evidence_id}",
    )
    return True

def _review_span(ads_module, backend, segments, ad, total_seconds, rebase_anchor_ids, held_spans, confirmed):
    """Review one span, rescanning an unanswered review, and return the span to keep.

    A vouched-for result is added to `confirmed`; anything else keeps the span
    as proposed and unvouched for.
    """
    outcome, reviewed = _resize_one_oversized_span(
        ads_module, backend, segments, ad, total_seconds, rebase_anchor_ids, held_spans
    )
    if outcome == "unanswered" and _rescan_unconfirmed_oversized_span(
        ads_module, backend, segments, ad
    ):
        outcome, reviewed = "confirmed", ad
    kept = reviewed if reviewed is not None else ad
    if outcome == "confirmed":
        confirmed.add((float(kept.start_s), float(kept.end_s)))
    return kept


def resize_oversized_ad_spans(
    ads_module, backend, segments, detections, total_seconds, *,
    rebase_anchor_ids=frozenset(), held_spans=None,
):
    """Review every span too large to be an ad, and say which ones were vouched for.

    Returns `(detections, confirmed)`, where `confirmed` holds the
    `(start_s, end_s)` of each span a review positively established. Size alone
    decides nothing here: a large span is a reason to look harder, not a reason
    to throw the span away. A span the first review cannot place a boundary in
    gets a second, differently-worded read; only a span that survives neither is
    handed to `reject_implausible_ad_spans`, which remains the net.

    Only an `"unanswered"` first review gets the rescan: a review that found
    programme in either candidate must leave the original span unvouched for.

    `total_seconds` is the probed audio duration, the same denominator the
    rejection below uses, so the two bounds cannot disagree about how large a
    span is.
    """
    if total_seconds <= 0 or not detections or not segments:
        return detections, frozenset()
    resized = []
    confirmed = set()
    reviewed_ids = set()
    for ad in detections:
        share = (float(ad.end_s) - float(ad.start_s)) / total_seconds
        if share <= MAXIMUM_SINGLE_AD_SHARE:
            resized.append(ad)
            continue
        reviewed_ids.add(id(ad))
        resized.append(_review_span(
            ads_module, backend, segments, ad, total_seconds, rebase_anchor_ids, held_spans, confirmed
        ))

    # Review before aggregate-unreviewed-share refusal when several individually
    # smaller spans exceed 50% in aggregate.
    unreviewed = [ad for ad in resized if (float(ad.start_s), float(ad.end_s)) not in confirmed]
    unreviewed_share = sum(float(ad.end_s) - float(ad.start_s) for ad in unreviewed) / total_seconds
    if unreviewed_share > MAXIMUM_UNCONFIRMED_AD_SHARE:
        for ad in sorted(unreviewed, key=lambda a: float(a.end_s) - float(a.start_s), reverse=True):
            if id(ad) in reviewed_ids:
                continue
            idx = next(i for i, candidate in enumerate(resized) if candidate is ad)
            resized[idx] = _review_span(
                ads_module, backend, segments, ad, total_seconds, rebase_anchor_ids, held_spans, confirmed
            )
            cur_unreviewed = [a for a in resized if (float(a.start_s), float(a.end_s)) not in confirmed]
            if sum(float(a.end_s) - float(a.start_s) for a in cur_unreviewed) / total_seconds <= MAXIMUM_UNCONFIRMED_AD_SHARE:
                break

    if held_spans is not None:
        held_spans[:] = [held for held in held_spans
                         if held.reason != "boundary-review-unresolved"
                         or (held.start_s, held.end_s) not in confirmed]
    return resized, frozenset(confirmed)


def reject_implausible_ad_spans(
    detections, total_seconds, confirmed=frozenset(), held_spans=None
):
    """Drop unreviewed detections too large to be advertising, and say which and why.

    Dropping the span rather than trimming it is deliberate: nothing here knows
    where the advertisement actually ended, and a guessed boundary would cut
    programme audio with the same confidence the detector just misplaced.

    `confirmed` holds the spans a review already read end to end and vouched
    for. A vouched-for span is exempt from the single-span limit, so a short
    news alert can legitimately be mostly advertising, but it is still subject
    to the total-share ceiling. If the vouched-for spans alone exceed that
    ceiling, they are held and no span is cut. Otherwise, an over-limit
    combination hands back the unreviewed spans and keeps only vouched-for
    spans. Unreviewed spans also have a tighter bound of their own, so they
    cannot accumulate past what a single span may claim. The
    `MINIMUM_PROGRAMME_SHARE` floor also keeps the whole episode when a cut
    would leave too little programme.
    """
    if total_seconds <= 0 or not detections:
        return detections
    kept = []
    for ad in detections:
        span_seconds = float(ad.end_s) - float(ad.start_s)
        share = span_seconds / total_seconds
        if share > MAXIMUM_SINGLE_AD_SHARE and (float(ad.start_s), float(ad.end_s)) not in confirmed:
            _worker_reporting.progress(
                "ads.detect.span.rejected",
                f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} is {share:.0%} of the episode and no "
                "review could vouch for it; a span that size is a detection failure, not an advertisement",
            )
            continue
        kept.append(ad)
    vouched = [ad for ad in kept if (float(ad.start_s), float(ad.end_s)) in confirmed]
    unreviewed = [ad for ad in kept if (float(ad.start_s), float(ad.end_s)) not in confirmed]
    unreviewed_removed = sum(float(ad.end_s) - float(ad.start_s) for ad in unreviewed)
    vouched_removed = sum(float(ad.end_s) - float(ad.start_s) for ad in vouched)
    total_removed = sum(float(ad.end_s) - float(ad.start_s) for ad in kept)
    programme_share = 1 - total_removed / total_seconds
    if vouched_removed / total_seconds > MAXIMUM_TOTAL_AD_SHARE:
        for ad in vouched:
            record_held_span(
                held_spans, ad.start_s, ad.end_s, "total-share-ceiling", total_seconds
            )
        _worker_reporting.progress(
            "ads.detect.refused",
            f"the spans a review vouched for total {vouched_removed:.1f}s of "
            f"{total_seconds:.1f}s ({vouched_removed / total_seconds:.0%}), over the "
            f"{MAXIMUM_TOTAL_AD_SHARE:.0%} total-share ceiling; keeping the episode whole",
        )
        return []
    if programme_share < MINIMUM_PROGRAMME_SHARE:
        _worker_reporting.progress(
            "ads.detect.refused",
            f"{total_removed:.1f}s of {total_seconds:.1f}s ({total_removed / total_seconds:.0%}) "
            f"would be removed, leaving {programme_share:.0%} of the episode as programme, under the "
            f"{MINIMUM_PROGRAMME_SHARE:.0%} floor; keeping the episode whole",
        )
        return []
    if unreviewed_removed / total_seconds > MAXIMUM_UNCONFIRMED_AD_SHARE:
        disposition = (
            "keeping only the spans a review vouched for"
            if vouched else "keeping the episode whole"
        )
        _worker_reporting.progress(
            "ads.detect.refused",
            f"{unreviewed_removed:.1f}s of {total_seconds:.1f}s "
            f"({unreviewed_removed / total_seconds:.0%}) was classified as advertising without review; "
            f"{disposition}",
        )
        return vouched
    if total_removed / total_seconds > MAXIMUM_TOTAL_AD_SHARE:
        _worker_reporting.progress(
            "ads.detect.refused",
            f"{total_removed:.1f}s of {total_seconds:.1f}s ({total_removed / total_seconds:.0%}) "
            f"would be removed, {unreviewed_removed:.1f}s of it without review; keeping only the spans "
            "a review vouched for",
        )
        return vouched
    return kept


def enforce_total_ad_share_ceiling(detections, total_seconds, held_spans=None):
    """Hold every final detection if recovery leaves the total over its ceiling."""
    if total_seconds <= 0 or not detections:
        return detections
    total_removed = sum(float(ad.end_s) - float(ad.start_s) for ad in detections)
    share = total_removed / total_seconds
    if share <= MAXIMUM_TOTAL_AD_SHARE:
        return detections
    for ad in detections:
        record_held_span(
            held_spans, ad.start_s, ad.end_s, "total-share-ceiling", total_seconds
        )
    _worker_reporting.progress(
        "ads.detect.refused",
        f"final recovered detections total {total_removed:.1f}s of {total_seconds:.1f}s "
        f"({share:.0%}), over the {MAXIMUM_TOTAL_AD_SHARE:.0%} total-share ceiling; "
        "keeping the episode whole",
    )
    return []

def recover_adjacent_ad_pod_continuations(
    ads_module, backend, segments, detections, total_seconds, held_spans=None
):
    """Extend a surviving cut through one immediately adjacent promo, or preserve it."""
    if not detections or len(segments) < 2 or not 0 < total_seconds < float("inf"):
        return detections
    recovered = list(detections)
    for index, ad in enumerate(tuple(recovered)):
        # The neighbour is not standalone evidence.  It may be reviewed only
        # after the archive has already produced the same sponsor-read
        # classification as the demonstrated TechCrunch cut. The archive's
        # calibrated sponsor-read confidence is not a proof tier, so the label
        # (not a guessed numeric cutoff) is the stable safety boundary.
        if ad.label != "sponsor_read":
            continue
        ad_end = float(ad.end_s)
        first = next(
            (segment_id for segment_id, segment in enumerate(segments)
             if float(segment.start_s) >= ad_end),
            None,
        )
        if first is None:
            continue
        gap = float(segments[first].start_s) - ad_end
        if gap < 0 or gap > AD_POD_CONTINUATION_MAX_GAP_SECONDS:
            continue
        if any(
            other is not ad
            and intervals_overlap(
                float(other.start_s), float(other.end_s),
                float(segments[first].start_s), float(segments[first].end_s),
            )
            for other in recovered
        ):
            continue
        window_ids = []
        for segment_id in range(first, min(len(segments), first + AD_POD_CONTINUATION_MAX_SEGMENTS)):
            if float(segments[segment_id].start_s) - ad_end > AD_POD_CONTINUATION_MAX_SECONDS:
                break
            window_ids.append(segment_id)
        if len(window_ids) < 2:
            continue
        rendered = "\n".join(
            ads_module._segment_prefix(segment_id, segments[segment_id])  # noqa: SLF001
            + (segments[segment_id].text or "")
            for segment_id in window_ids
        )
        if len(rendered) > COMMERCIAL_RECOVERY_CONTEXT_CHARS:
            _worker_reporting.progress("ads.detect.pod-continuation.skipped", "complete adjacent passage exceeds the rendering budget")
            continue
        try:
            response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
                backend,
                AD_POD_CONTINUATION_PROMPT,
                rendered,
                ads_module._id_response_format(  # noqa: SLF001
                    "program_start_id", [-1, *window_ids]
                ),
            )
            parsed = json.loads(response)
            if not isinstance(parsed, dict) or set(parsed) != {"program_start_id"}:
                raise ValueError("program_start_id response must contain exactly program_start_id")
            program_start_id = parsed["program_start_id"]
            if (
                isinstance(program_start_id, bool)
                or not isinstance(program_start_id, int)
                or program_start_id not in [-1, *window_ids]
            ):
                raise ValueError("program_start_id must be one of the supplied IDs")
            if program_start_id in {-1, first}:
                continue
            extension_end = float(segments[program_start_id].start_s)
            proposed_seconds = extension_end - float(ad.start_s)
            total_removed = sum(float(item.end_s) - float(item.start_s) for item in recovered)
            total_removed += extension_end - ad_end
            if (
                extension_end <= ad_end
                or extension_end - ad_end > AD_POD_CONTINUATION_MAX_SECONDS
            ):
                raise ValueError("adjacent continuation is overly broad")
            if (
                any(
                    other is not ad
                    and float(other.start_s) < extension_end
                    and float(other.end_s) > ad_end
                    for other in recovered
                )
                or proposed_seconds / total_seconds > MAXIMUM_SINGLE_AD_SHARE
            ):
                record_held_span(
                    held_spans, ad_end, extension_end,
                    "pod-continuation-bracket", total_seconds,
                )
                continue
            if total_removed / total_seconds > MAXIMUM_TOTAL_AD_SHARE:
                record_held_span(
                    held_spans, ad_end, extension_end,
                    "total-share-ceiling", total_seconds,
                )
                continue
        except Exception as error:  # noqa: BLE001 - incomplete review preserves the verified cut
            _worker_reporting.progress(
                "ads.detect.pod-continuation.skipped",
                f"adjacent review preserved the existing cut: {type(error).__name__}: {error}",
            )
            continue
        recovered[index] = ads_module.AdSegment(
            float(ad.start_s), extension_end, float(ad.confidence), ad.label
        )
        _worker_reporting.progress(
            "ads.detect.pod-continuation",
            f"{ad_end:.3f}-{extension_end:.3f} extends the verified cut before programme ID {program_start_id}",
        )
    return recovered
