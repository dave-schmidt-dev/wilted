"""Worker module split from wilted_pipeline.py."""
from __future__ import annotations
import json
from . import reporting as _worker_reporting
from .prompts import BOUNDARY_SEGMENT_PROMPT

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
