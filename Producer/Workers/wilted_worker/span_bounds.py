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
from .ad_audit import HeldAdSpan
from .commercial_seeds import _constrained_id
from .constants import AD_POD_CONTINUATION_MAX_GAP_SECONDS, AD_POD_CONTINUATION_MAX_SECONDS, AD_POD_CONTINUATION_MAX_SEGMENTS, COMMERCIAL_RECOVERY_CONTEXT_CHARS, MAXIMUM_SINGLE_AD_SHARE, MAXIMUM_TOTAL_AD_SHARE, MAXIMUM_UNCONFIRMED_AD_SHARE, MINIMUM_PROGRAMME_SHARE, OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS
from .edge_recovery import _program_starts_inside
from .prompts import AD_POD_CONTINUATION_PROMPT, OVERSIZED_SPAN_CONFIRM_PROMPT, OVERSIZED_SPAN_PROGRAM_START_PROMPT, OVERSIZED_SPAN_RESCAN_PROMPT


def _try_rebase_confirmed_prefix(
    ads_module, backend, segments, ad, total_seconds, window_ids,
    rebase_anchor_ids, program_id, held_spans,
):
    """Confirm the anchored portion before a review-found programme cue.

    Returns ``None`` when no anchor lies in the bounded passage, otherwise the
    final resize outcome. A non-advertising answer is positive programme
    evidence, so it records the existing held-span disposition rather than
    permitting another recovery path.
    """
    rebase_anchor_id = next(
        (
            anchor_id
            for anchor_id in sorted(rebase_anchor_ids)
            if window_ids[0] < anchor_id < program_id and anchor_id in window_ids
        ),
        None,
    )
    if rebase_anchor_id is None:
        return None
    rebase_ids = [
        segment_id
        for segment_id in window_ids
        if rebase_anchor_id <= segment_id < program_id
    ]
    _worker_reporting.progress(
        "ads.detect.span.rebase.reviewing",
        f"preserving prefix ID {window_ids[0]} and rechecking from explicit anchor ID "
        f"{rebase_anchor_id} before program ID {program_id}",
    )
    try:
        rebase_program_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_CONFIRM_PROMPT, "program_id",
            rebase_ids, [-1, *rebase_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - uncertainty holds the full span
        _worker_reporting.progress(
            "ads.detect.span.rebase.skipped",
            f"anchor-forward confirmation failed: {type(error).__name__}: {error}",
        )
    else:
        if rebase_program_id == -1:
            rebase_start_s = float(segments[rebase_anchor_id].start_s)
            end_s = float(segments[program_id].start_s)
            _worker_reporting.progress(
                "ads.detect.span.rebased",
                f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} safely rebased to "
                f"{rebase_start_s:.3f}-{end_s:.3f} from explicit anchor ID {rebase_anchor_id}",
            )
            return ("confirmed", ads_module.AdSegment(
                rebase_start_s, end_s, float(ad.confidence), ad.label
            ))
        _worker_reporting.progress(
            "ads.detect.span.rebase.skipped",
            f"the anchor-forward passage holds program content at {rebase_program_id}",
        )
    _record_held_span(
        held_spans, ad.start_s, ad.end_s, "sponsor-prefix-programme-found", total_seconds
    )
    return ("program_found", None)


def _resize_one_oversized_span(
    ads_module, backend, segments, ad, total_seconds, rebase_anchor_ids=frozenset(),
    held_spans=None,
):
    """Review one too-large span and return `(outcome, segment)`.

    Two questions in the shape the opening review established: the first
    nominates a boundary, the second is handed only the shortened span and
    asked to find program content inside it. A boundary in the wrong place has
    the program in that passage, so the second question finds it and the trim
    never happens.

    `outcome` is `"confirmed"` when the review positively established what the
    span is -- advertising throughout, advertising up to a located boundary,
    or one re-confirmed prefix before programme found in a mixed candidate --
    `"program_found"` when programme evidence leaves no such safe prefix, and
    `"unanswered"` when it could not answer. Programme evidence is not an
    unanswered review: it must not let a later rescan vouch for the original
    oversized span. Size alone never decides, so a span the review vouched for
    is not later thrown away for being large.
    """
    span_ids = [
        segment_id for segment_id, segment in enumerate(segments)
        if float(segment.start_s) < float(ad.end_s) and float(segment.end_s) > float(ad.start_s)
    ]
    if len(span_ids) < 2:
        return ("unanswered", None)
    window_ids = span_ids[:OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS]

    try:
        program_start_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_PROGRAM_START_PROMPT, "program_start_id",
            window_ids, [-1, *window_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        _worker_reporting.progress("ads.detect.span.resize.skipped", f"resize review failed: {type(error).__name__}: {error}")
        return ("unanswered", None)
    if program_start_id == -1:
        # An affirmative verdict, not a decline: the review read the whole span
        # and found no programme in it. A short news alert really can be mostly
        # advertising, so this is the answer, not a failure to answer.
        _worker_reporting.progress("ads.detect.span.confirmed", "the span is advertising throughout")
        return ("confirmed", ad)
    if program_start_id == window_ids[0]:
        _worker_reporting.progress("ads.detect.span.resize.skipped", "the program starts at the first segment")
        return ("program_found", None)

    if program_start_id - 1 > window_ids[0] and _program_starts_inside(
        ads_module, backend, segments, program_start_id - 1
    ):
        # One step back only. The mixed segment is the boundary segment by
        # construction: the advertisement ends in it, so the one before it is
        # advertising throughout.
        _worker_reporting.progress(
            "ads.detect.boundary.shortened",
            f"the program starts inside segment {program_start_id - 1}, so the cut stops before it",
        )
        program_start_id -= 1
    end_s = float(segments[program_start_id].start_s)
    if end_s <= float(ad.start_s):
        _worker_reporting.progress("ads.detect.span.resize.skipped", "the program resumes before the span begins")
        return ("program_found", None)
    opening_ids = [segment_id for segment_id in window_ids if segment_id < program_start_id]
    try:
        program_id = _constrained_id(
            ads_module, backend, OVERSIZED_SPAN_CONFIRM_PROMPT, "program_id",
            opening_ids, [-1, *opening_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        _worker_reporting.progress("ads.detect.span.resize.skipped", f"resize confirmation failed: {type(error).__name__}: {error}")
        # The boundary review already found programme after this prefix. An
        # unreadable confirmation cannot turn that positive evidence into
        # permission to re-vouch for the original, oversized detection.
        return ("program_found", None)
    if program_id != -1:
        rebase_anchor_id = next(
            (
                anchor_id
                for anchor_id in sorted(rebase_anchor_ids)
                if window_ids[0] < anchor_id < program_start_id
            ),
            None,
        )
        if program_id == window_ids[0] and rebase_anchor_id is not None:
            # The first cue is a verified prefix joined to an explicit sponsor
            # anchor. It is programme, so preserve it, then recheck only the
            # anchor-forward passage before the bounded programme boundary.
            return _try_rebase_confirmed_prefix(
                ads_module, backend, segments, ad, total_seconds, window_ids,
                rebase_anchor_ids, program_start_id, held_spans,
            )
        # A positive answer means this proposed prefix was too wide, not that
        # its whole original span may be re-vouched for. The one bounded retry
        # considers only the earlier IDs. It can therefore establish precisely
        # the sponsor prefix before a mixed cue, but cannot guess at any later
        # boundary or reopen the whole-span rescan route.
        prefix_ids = [segment_id for segment_id in opening_ids if segment_id < program_id]
        if not prefix_ids:
            _worker_reporting.progress(
                "ads.detect.span.resize.skipped",
                f"the shortened span holds program content at {program_id}; no earlier prefix remains",
            )
            return ("program_found", None)
        try:
            prefix_program_id = _constrained_id(
                ads_module, backend, OVERSIZED_SPAN_CONFIRM_PROMPT, "program_id",
                prefix_ids, [-1, *prefix_ids], segments,
            )
        except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
            _worker_reporting.progress(
                "ads.detect.span.resize.skipped",
                f"safe-prefix confirmation failed: {type(error).__name__}: {error}",
            )
            return ("program_found", None)
        if prefix_program_id != -1:
            _worker_reporting.progress(
                "ads.detect.span.resize.skipped",
                f"the safe prefix still holds program content at {prefix_program_id}",
            )
            if prefix_program_id == window_ids[0]:
                rebased = _try_rebase_confirmed_prefix(
                    ads_module, backend, segments, ad, total_seconds, window_ids,
                    rebase_anchor_ids, program_id, held_spans,
                )
                if rebased is not None:
                    return rebased
            if rebase_anchor_id is not None:
                _record_held_span(
                    held_spans, ad.start_s, ad.end_s,
                    "sponsor-prefix-programme-found", total_seconds,
                )
            return ("program_found", None)
        end_s = float(segments[program_id].start_s)
        if end_s <= float(ad.start_s):
            _worker_reporting.progress("ads.detect.span.resize.skipped", "the safe prefix cuts no positive duration")
            return ("program_found", None)
        _worker_reporting.progress(
            "ads.detect.span.resized",
            f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} safely shortened to "
            f"{float(ad.start_s):.3f}-{end_s:.3f} before program ID {program_id}",
        )
        return ("confirmed", ads_module.AdSegment(
            float(ad.start_s), end_s, float(ad.confidence), ad.label
        ))

    _worker_reporting.progress(
        "ads.detect.span.resized",
        f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} shortened to "
        f"{float(ad.start_s):.3f}-{end_s:.3f} before program ID {program_start_id}",
    )
    # Only the front of the span is recovered. A true bracket -- advertising at
    # both ends with program between -- keeps its tail read in the audio, which
    # is the safe half of the trade and not worth a backwards pass to close.
    return ("confirmed", ads_module.AdSegment(float(ad.start_s), end_s, float(ad.confidence), ad.label))

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
        if float(segment.start_s) < float(ad.end_s) and float(segment.end_s) > float(ad.start_s)
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
    window_ids = span_ids[:OVERSIZED_SPAN_RESIZE_MAX_SEGMENTS]
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
    _worker_reporting.progress(
        "ads.detect.span.rescan.confirmed",
        f"{float(ad.start_s):.3f}-{float(ad.end_s):.3f} is advertising; evidence at ID {evidence_id}",
    )
    return True

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
    for ad in detections:
        share = (float(ad.end_s) - float(ad.start_s)) / total_seconds
        if share <= MAXIMUM_SINGLE_AD_SHARE:
            resized.append(ad)
            continue
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
        resized.append(kept)
    return resized, frozenset(confirmed)

def _record_held_span(held_spans, start_s, end_s, reason, total_seconds):
    """Record an uncut interval and report its share of the episode."""
    start_s, end_s = float(start_s), float(end_s)
    if held_spans is not None:
        held_spans.append(HeldAdSpan(start_s, end_s, reason))
    share = (end_s - start_s) / total_seconds
    _worker_reporting.progress(
        "ads.detect.span.held",
        f"{start_s:.3f}-{end_s:.3f} is held: {reason} ({share:.0%} of the episode)",
    )


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
            _record_held_span(
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
        _record_held_span(
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
            and float(other.start_s) < float(segments[first].end_s)
            and float(other.end_s) > float(segments[first].start_s)
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
                _record_held_span(
                    held_spans, ad_end, extension_end,
                    "pod-continuation-bracket", total_seconds,
                )
                continue
            if total_removed / total_seconds > MAXIMUM_TOTAL_AD_SHARE:
                _record_held_span(
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
