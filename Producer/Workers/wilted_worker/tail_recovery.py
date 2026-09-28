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
from .commercial_seeds import _constrained_id
from .constants import MAXIMUM_SINGLE_AD_SHARE, POSTROLL_ALREADY_CLAIMED_SECONDS, POSTROLL_CLEAN_BREAK_SECONDS, POSTROLL_LEADER_MAX_SECONDS, POSTROLL_RECOVERY_MAX_SECONDS, POSTROLL_RECOVERY_MAX_SEGMENTS, POSTROLL_RECOVERY_MINIMUM_SECONDS, STRADDLING_TAIL_MAX_PROBES
from .edge_recovery import _program_start_inside_answer
from .prompts import BOUNDARY_SEGMENT_TAIL_PROMPT, POSTROLL_CONFIRM_PROMPT, POSTROLL_PROGRAM_END_PROMPT
from .sponsor_evidence import explicit_sponsor_anchor_ids

def trim_straddling_span_tails(ads_module, backend, segments, detections, opening_pattern):
    """Pull a span's end back when the programme resumes inside its final cue.

    Every span the detector emits ends on a cue edge, which is correct only
    while the cue is advertising end to end. A produced read that signs off
    partway through a cue leaves the rest of it to the host, and taking the
    whole cue then removes the programme's own opening words. TechCrunch Daily
    is the corpus case: cue 9 carries the ODSC sign-off and then "i'm imran
    shake and your daily crunch for friday", so a cut to 187.48 rather than
    167.32 delivered a file opening mid-sentence on "after weeks of swirling
    rumors".

    Only an affirmative answer trims. That is a deliberate departure from the
    resize path, which treats an unreadable answer as a yes: that caller has
    already been told the programme resumes nearby and is only deciding how far
    to stop short, while this one screens every span in the episode with no
    such warrant. Shortening on silence here would let one bad model response
    shave the tail off every correct cut in the file -- a failure the listener
    meets on every episode, traded against one they meet rarely.

    A cue that opens its own sponsor read is never trimmed away: it is
    advertising rather than a straddle, and trimming it would uncover an anchor
    the recovery audit expects the span to hold.
    """
    if not detections or not segments:
        return detections
    anchor_ids = set(explicit_sponsor_anchor_ids(segments, opening_pattern))
    ends = {}
    for segment_id, segment in enumerate(segments):
        ends.setdefault(round(float(segment.end_s), 6), segment_id)
    trimmed = []
    probes = 0
    for ad in detections:
        boundary_id = ends.get(round(float(ad.end_s), 6))
        if (
            boundary_id is None
            or boundary_id in anchor_ids
            or probes >= STRADDLING_TAIL_MAX_PROBES
            or float(segments[boundary_id].start_s) <= float(ad.start_s)
        ):
            trimmed.append(ad)
            continue
        probes += 1
        if _program_start_inside_answer(ads_module, backend, segments, boundary_id) is not True:
            trimmed.append(ad)
            continue
        end_s = float(segments[boundary_id].start_s)
        _worker_reporting.progress(
            "ads.detect.tail.shortened",
            f"the program starts inside segment {boundary_id}, so the cut ending "
            f"{float(ad.end_s):.3f} stops at {end_s:.3f}",
        )
        trimmed.append(
            ads_module.AdSegment(  # noqa: SLF001 - preserve legacy detection result type
                float(ad.start_s), end_s, float(ad.confidence), ad.label
            )
        )
    return trimmed

def _tail_carries_program(ads_module, backend, segments, segment_id):
    """Answer whether the program is still running inside one segment.

    True when it is, and True when the question cannot be answered: the mirror
    of the opening probe, and fail-closed for the same reason.
    """
    try:
        response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
            backend,
            BOUNDARY_SEGMENT_TAIL_PROMPT,
            ads_module._render_segments_bounded([segment_id], segments),  # noqa: SLF001
            {"type": "json_object"},
        )
        parsed = json.loads(response)
        if set(parsed) != {"carries_program"} or not isinstance(parsed["carries_program"], bool):
            raise ValueError("carries_program response must contain exactly one boolean")
        return parsed["carries_program"]
    except Exception as error:  # noqa: BLE001 - an unanswered question keeps the segment
        _worker_reporting.progress("ads.detect.boundary.unanswered", f"{type(error).__name__}: {error}")
        return True

def recover_transcript_end_postroll(ads_module, backend, segments, detections, total_seconds):
    """Recover a produced advertisement appended after the program signs off.

    The opening review's mirror, and it exists for the same reason: a produced
    spot carries none of the evidence the anchor recovery needs. Nobody on the
    show reads it, it names no domain the sparse-evidence filter would see, and
    a network cross-promotion for a different podcast asks you to subscribe
    somewhere else rather than to buy anything. Two episodes reported on the
    same day ended this way -- The Daily on a Chase Sapphire spot, TechCrunch
    Daily on a Motley Fool one -- and the detector found neither.

    The cut runs to the end of the file rather than to the last advertising
    cue, because what is between them is the spot's own music bed.
    """
    if not segments or total_seconds <= 0:
        return detections
    end_s = float(segments[-1].end_s)
    floor_s = end_s - POSTROLL_RECOVERY_MAX_SECONDS
    terminal_detections = sorted(
        [ad for ad in detections if float(ad.end_s) > floor_s],
        key=lambda ad: ad.start_s,
    )
    ending_claimed = any(
        float(ad.end_s) >= end_s - POSTROLL_ALREADY_CLAIMED_SECONDS
        for ad in detections
    )

    unclaimed_gap_previous_ad = None
    unclaimed_gap_next_ad = None
    if ending_claimed:
        for previous_ad, next_ad in zip(terminal_detections, terminal_detections[1:]):
            if float(next_ad.start_s) - float(previous_ad.end_s) <= 2.0:
                continue
            if any(
                float(segment.end_s) > float(previous_ad.end_s)
                and float(segment.start_s) < float(next_ad.start_s)
                for segment in segments
            ):
                unclaimed_gap_previous_ad = previous_ad
                unclaimed_gap_next_ad = next_ad
                break
        if unclaimed_gap_previous_ad is None:
            _worker_reporting.progress("ads.detect.postroll.skipped", "the ending is already claimed")
            return detections

    if unclaimed_gap_previous_ad is not None:
        gap_floor_s = float(unclaimed_gap_previous_ad.end_s)
        window_ids = [
            segment_id for segment_id, segment in enumerate(segments)
            if float(segment.end_s) > gap_floor_s
        ][-POSTROLL_RECOVERY_MAX_SEGMENTS:]
    else:
        window_ids = [
            segment_id for segment_id, segment in enumerate(segments)
            if float(segment.end_s) > floor_s
            and not any(float(ad.end_s) > float(segment.start_s) for ad in detections)
        ][-POSTROLL_RECOVERY_MAX_SEGMENTS:]
    if len(window_ids) < 2:
        return detections

    try:
        advertising_start_id = _constrained_id(
            ads_module, backend, POSTROLL_PROGRAM_END_PROMPT, "advertising_start_id",
            window_ids, [-1, *window_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        _worker_reporting.progress("ads.detect.postroll.skipped", f"closing review failed: {type(error).__name__}: {error}")
        return detections
    if advertising_start_id == -1:
        _worker_reporting.progress("ads.detect.postroll.skipped", "the program runs to the end")
        return detections
    if (
        unclaimed_gap_next_ad is not None
        and float(segments[advertising_start_id].start_s)
        >= float(unclaimed_gap_next_ad.start_s)
    ):
        _worker_reporting.progress(
            "ads.detect.postroll.skipped",
            "closing review nominated the already-detected ending rather than the unclaimed gap",
        )
        return detections

    gap = (
        float(segments[advertising_start_id].start_s)
        - float(segments[advertising_start_id - 1].end_s)
        if advertising_start_id > 0 else 0.0
    )
    boundary_carries_program = False
    if gap >= POSTROLL_CLEAN_BREAK_SECONDS:
        _worker_reporting.progress(
            "ads.detect.boundary.clean",
            f"segment {advertising_start_id} starts {gap:.2f}s "
            "after the segment before it, "
            "so it cannot share the sign-off's last words",
        )
    elif advertising_start_id < window_ids[-1]:
        boundary_carries_program = _tail_carries_program(
            ads_module, backend, segments, advertising_start_id
        )
    if boundary_carries_program:
        # The sign-off and the spot's first words share a segment, so the cut
        # starts after it. One step only, for the same reason as the opening.
        _worker_reporting.progress(
            "ads.detect.boundary.shortened",
            f"the program is still running inside segment {advertising_start_id}, "
            "so the cut starts after it",
        )
        advertising_start_id += 1
        boundary_carries_program = False
    if (
        unclaimed_gap_next_ad is not None
        and float(segments[advertising_start_id].start_s)
        >= float(unclaimed_gap_next_ad.start_s)
    ):
        _worker_reporting.progress(
            "ads.detect.postroll.skipped",
            "closing boundary shortened onto the already-detected ending rather than the unclaimed gap",
        )
        return detections

    start_s = float(segments[advertising_start_id].start_s)
    if advertising_start_id > 0:
        start_s = max(
            float(segments[advertising_start_id - 1].end_s),
            start_s - POSTROLL_LEADER_MAX_SECONDS,
        )
    if total_seconds - start_s < POSTROLL_RECOVERY_MINIMUM_SECONDS:
        _worker_reporting.progress("ads.detect.postroll.skipped", "the ending is too short to be a produced spot")
        return detections
    share = (total_seconds - start_s) / total_seconds
    if share > MAXIMUM_SINGLE_AD_SHARE:
        _worker_reporting.progress("ads.detect.postroll.skipped", f"the ending would be {share:.0%} of the episode")
        return detections

    tail_ids = [segment_id for segment_id in window_ids if segment_id >= advertising_start_id]
    try:
        program_id = _constrained_id(
            ads_module, backend, POSTROLL_CONFIRM_PROMPT, "program_id",
            tail_ids, [-1, *tail_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        _worker_reporting.progress("ads.detect.postroll.skipped", f"closing confirmation failed: {type(error).__name__}: {error}")
        return detections
    if program_id == advertising_start_id and not boundary_carries_program:
        # Two questions disagreeing about one segment, and the one asked about
        # that segment alone wins. TechCrunch Daily ends on a promotion for
        # another podcast that describes its own content the way a show
        # describes itself, and the confirmation read the first segment of it as
        # this program; the single-segment probe, handed nothing else to weigh,
        # said there was no program in it. Believing the confirmation here costs
        # two thirds of the spot for no reason anyone could name.
        _worker_reporting.progress(
            "ads.detect.postroll.contested",
            f"the confirmation puts the program at {program_id} and the segment itself carries none; "
            "keeping the boundary",
        )
        program_id = -1

    disputed = program_id != -1
    if program_id != -1:
        # One shrink, then the answer stands. The realistic disagreement is the
        # first question overshooting by a segment or two -- The Daily's closing
        # promo for another NYT show reads as advertising and its sign-off comes
        # after it -- so the passage is narrowed to what the confirmation left
        # and asked once more. A second disagreement is not a boundary dispute,
        # it is the review being wrong about the whole ending.
        shrunk_ids = [segment_id for segment_id in tail_ids if segment_id > program_id]
        start_s = (
            max(float(segments[shrunk_ids[0] - 1].end_s),
                float(segments[shrunk_ids[0]].start_s) - POSTROLL_LEADER_MAX_SECONDS)
            if shrunk_ids else 0.0
        )
        if not shrunk_ids or total_seconds - start_s < POSTROLL_RECOVERY_MINIMUM_SECONDS:
            _worker_reporting.progress("ads.detect.postroll.skipped", f"the ending holds program content at {program_id}")
            return detections
        _worker_reporting.progress(
            "ads.detect.postroll.shrunk",
            f"program content at {program_id}, so the ending is narrowed to {shrunk_ids[0]}",
        )
        advertising_start_id = shrunk_ids[0]
        try:
            program_id = _constrained_id(
                ads_module, backend, POSTROLL_CONFIRM_PROMPT, "program_id",
                shrunk_ids, [-1, *shrunk_ids], segments,
            )
        except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
            _worker_reporting.progress("ads.detect.postroll.skipped", f"closing confirmation failed: {type(error).__name__}: {error}")
            return detections
        if program_id != -1:
            _worker_reporting.progress("ads.detect.postroll.skipped", f"the ending still holds program content at {program_id}")
            return detections

    # The receipt mirrors the opening's: the closing review found appended
    # advertising, the confirmation agreed without the ending having to be
    # narrowed, and the tail is comfortably longer than the smallest thing the
    # worker will cut.
    confidence = recovered_confidence(
        sum((
            True,
            not disputed,
            total_seconds - start_s >= 2 * POSTROLL_RECOVERY_MINIMUM_SECONDS,
        )),
        3,
    )
    _worker_reporting.progress(
        "ads.detect.postroll",
        f"{start_s:.3f}-{total_seconds:.3f} after program ID {advertising_start_id}",
    )
    return ads_module._merge_adjacent([  # noqa: SLF001
        *detections,
        # The closing review is the one pass that positively established this
        # run as the sign-off/credits/music-bed shape rather than a mid-roll
        # break, so it is the one place `credits` is attached. The detector's
        # own `ad_break` spans stay paid.
        ads_module.AdSegment(start_s, total_seconds, confidence, "ad_break",
                             kinds=(ads_module.AD_KIND_CREDITS,)),
    ])
