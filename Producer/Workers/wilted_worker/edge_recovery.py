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
from .constants import AD_POD_CONTINUATION_MAX_SECONDS, AD_POD_CONTINUATION_MAX_SEGMENTS, PREROLL_ALREADY_CLAIMED_SECONDS, PREROLL_COLD_OPEN_MAX_ID, PREROLL_RECOVERY_MAX_SECONDS, PREROLL_RECOVERY_MAX_SEGMENTS, PREROLL_RECOVERY_MINIMUM_SECONDS
from .prompts import AD_POD_CONTINUATION_PROMPT, BOUNDARY_SEGMENT_PROMPT, PREROLL_CONFIRM_PROMPT, PREROLL_PROGRAM_START_PROMPT

def recover_transcript_start_preroll(ads_module, backend, segments, detections):
    """Recover a produced advertisement carried before the program starts.

    Two questions rather than one, and the second is not the first asked
    again: it is handed only the passage the first answer nominated and asked
    to find program content inside it. A cold open wrongly nominated has its
    hosts talking in that passage, so the second question finds them and the
    cut never happens.
    """
    if not segments:
        return detections
    # Only an opening already claimed from its first second is left alone. A
    # detection that begins a few seconds in is the case this exists for: the
    # advertisement's opening sentences were not recognised as advertising, so
    # what survives the cut is a commercial, and it is the first thing the
    # listener hears. Giant Bombcast 955 kept thirteen seconds of an insurance
    # spot that way, with the detector's own span starting at 13.0.
    if any(ad.start_s <= segments[0].start_s + PREROLL_ALREADY_CLAIMED_SECONDS for ad in detections):
        return detections
    window_ids = [0]
    for segment_id in range(1, len(segments)):
        if (len(window_ids) >= PREROLL_RECOVERY_MAX_SEGMENTS
                or segments[segment_id].start_s > PREROLL_RECOVERY_MAX_SECONDS):
            break
        window_ids.append(segment_id)
    if len(window_ids) < 2:
        return detections

    try:
        program_start_id = _constrained_id(
            ads_module, backend, PREROLL_PROGRAM_START_PROMPT, "program_start_id",
            window_ids, window_ids, segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        _worker_reporting.progress("ads.detect.preroll.skipped", f"opening review failed: {type(error).__name__}: {error}")
        return detections
    if program_start_id == 0:
        _worker_reporting.progress("ads.detect.preroll.skipped", "the program starts at the first segment")
        return detections

    q1_program_start_id = program_start_id
    nominated_end_s = float(segments[program_start_id].start_s)
    _worker_reporting.progress("ads.detect.preroll.nominated", f"program ID {program_start_id} at {nominated_end_s:.3f}s")
    if nominated_end_s < PREROLL_RECOVERY_MINIMUM_SECONDS:
        _worker_reporting.progress("ads.detect.preroll.skipped", f"the opening is only {nominated_end_s:.1f}s long")
        return detections

    opening_ids = list(range(program_start_id))
    try:
        program_id = _constrained_id(
            ads_module, backend, PREROLL_CONFIRM_PROMPT, "program_id",
            opening_ids, [-1, *opening_ids], segments,
        )
    except Exception as error:  # noqa: BLE001 - an unanswered question never cuts audio
        _worker_reporting.progress("ads.detect.preroll.skipped", f"opening confirmation failed: {type(error).__name__}: {error}")
        return detections
    if 0 <= program_id <= PREROLL_COLD_OPEN_MAX_ID:
        _worker_reporting.progress("ads.detect.preroll.skipped", f"the opening holds program content at {program_id}")
        return detections
    confirmation_agreed = program_id == -1
    if program_id != -1:
        # The confirmation read only the passage the boundary question
        # nominated, and it placed the program earlier inside that passage.
        # Believing it cuts strictly less audio than the nomination asked for,
        # so the safe move is to take its boundary rather than to cut nothing:
        # abandoning the whole recovery here is what left Economics of Everyday
        # Things 70 opening on two untouched sponsor reads.
        program_start_id = program_id
        nominated_end_s = float(segments[program_start_id].start_s)
        _worker_reporting.progress("ads.detect.preroll.shortened",
                 f"program moved to ID {program_start_id} at {nominated_end_s:.3f}s")
        if nominated_end_s < PREROLL_RECOVERY_MINIMUM_SECONDS:
            _worker_reporting.progress("ads.detect.preroll.skipped",
                     f"the shortened opening is only {nominated_end_s:.1f}s long")
            return detections
        if program_start_id < q1_program_start_id:
            continuation_ids = [program_start_id]
            window_limit = min(
                len(segments),
                max(q1_program_start_id + 4, program_start_id + AD_POD_CONTINUATION_MAX_SEGMENTS),
            )
            for segment_id in range(program_start_id + 1, window_limit):
                if (
                    float(segments[segment_id].start_s) - float(segments[program_start_id].start_s)
                    > AD_POD_CONTINUATION_MAX_SECONDS
                ):
                    break
                continuation_ids.append(segment_id)
            if len(continuation_ids) >= 2:
                _worker_reporting.progress(
                    "ads.detect.preroll.continuation.reviewing",
                    f"checking continuation from ID {program_start_id} up to Q1 ID {q1_program_start_id}",
                )
                try:
                    continued_id = _constrained_id(
                        ads_module,
                        backend,
                        AD_POD_CONTINUATION_PROMPT,
                        "program_start_id",
                        continuation_ids,
                        [-1, *continuation_ids],
                        segments,
                    )
                    if continued_id > program_start_id:
                        extended_start_id = min(continued_id, q1_program_start_id)
                        if extended_start_id > program_start_id:
                            program_start_id = extended_start_id
                            confirmation_agreed = (extended_start_id == q1_program_start_id)
                            _worker_reporting.progress(
                                "ads.detect.preroll.extended",
                                f"opening extended to ID {program_start_id} at {float(segments[program_start_id].start_s):.3f}s",
                            )
                        else:
                            _worker_reporting.progress(
                                "ads.detect.preroll.continuation.skipped",
                                f"continuation ID {continued_id} did not advance past ID {program_start_id}",
                            )
                    else:
                        _worker_reporting.progress(
                            "ads.detect.preroll.continuation.skipped",
                            f"continuation found no subsequent programme return (got {continued_id})",
                        )
                except Exception as error:  # noqa: BLE001 - uncertain continuation preserves shortened boundary
                    _worker_reporting.progress(
                        "ads.detect.preroll.continuation.skipped",
                        f"opening continuation review failed: {type(error).__name__}: {error}",
                    )

    # The cut runs to where the program begins rather than to the last
    # advertising cue, because the insertion gap between them is the spot's
    # own music bed and leaving it behind is leaving the advertisement in.
    end_s = float(segments[program_start_id].start_s)
    # The receipt is: the boundary review named where the program resumes, the
    # confirmation did not move it, and the opening is comfortably longer than
    # the smallest thing the worker will cut. A moved boundary or a bare-minimum
    # opening is weaker evidence and reports lower.
    confidence = recovered_confidence(
        sum((
            True,
            confirmation_agreed,
            end_s >= 2 * PREROLL_RECOVERY_MINIMUM_SECONDS,
        )),
        3,
    )
    preroll = ads_module.AdSegment(0.0, end_s, confidence, "ad_break")  # noqa: SLF001 - legacy result type
    _worker_reporting.progress("ads.detect.preroll", f"0.000-{end_s:.3f} before program ID {program_start_id}")
    return ads_module._merge_adjacent(  # noqa: SLF001 - retain legacy overlap semantics
        sorted([preroll, *detections], key=lambda ad: ad.start_s)
    )

def _program_starts_inside(ads_module, backend, segments, segment_id):
    """Answer whether the program begins inside one segment, so a cut can stop short of it.

    Returns True when it does, and True as well when the question cannot be
    answered: an unreadable answer must not license taking a segment that might
    hold the program.
    """
    try:
        response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
            backend,
            BOUNDARY_SEGMENT_PROMPT,
            ads_module._render_segments_bounded([segment_id], segments),  # noqa: SLF001
            {"type": "json_object"},
        )
        parsed = json.loads(response)
        if set(parsed) != {"starts_program"} or not isinstance(parsed["starts_program"], bool):
            raise ValueError("starts_program response must contain exactly one boolean")
        return parsed["starts_program"]
    except Exception as error:  # noqa: BLE001 - an unanswered question keeps the segment
        _worker_reporting.progress("ads.detect.boundary.unanswered", f"{type(error).__name__}: {error}")
        return True

def _program_start_inside_answer(ads_module, backend, segments, segment_id):
    """True, False, or None when the question could not be answered.

    `_program_starts_inside` folds the third case into True, which is right
    where the caller has already been told a boundary is near and is only
    deciding how far to stop short. A safeguard that screens every span has no
    such warrant, so it needs the three answers apart.
    """
    try:
        response, _tokens = ads_module._generate_constrained_response(  # noqa: SLF001
            backend,
            BOUNDARY_SEGMENT_PROMPT,
            ads_module._render_segments_bounded([segment_id], segments),  # noqa: SLF001
            {"type": "json_object"},
        )
        parsed = json.loads(response)
        if set(parsed) != {"starts_program"} or not isinstance(parsed["starts_program"], bool):
            raise ValueError("starts_program response must contain exactly one boolean")
        return parsed["starts_program"]
    except Exception as error:  # noqa: BLE001 - an unreadable answer is not a verdict
        _worker_reporting.progress("ads.detect.tail.unanswered", f"{type(error).__name__}: {error}")
        return None
