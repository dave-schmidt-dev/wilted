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
from .constants import COMMERCIAL_RECOVERY_CONTEXT_CHARS, COMMERCIAL_RECOVERY_CONTEXT_IDS, COMMERCIAL_RECOVERY_MAX_CANDIDATE_SECONDS, COMMERCIAL_RECOVERY_MAX_CANDIDATE_SHARE, EXPLICIT_SPONSOR_DOT_DOMAIN_RE, EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE, EXPLICIT_SPONSOR_NAME_LEADING_FILLER, EXPLICIT_SPONSOR_NAME_MAX_WORDS, EXPLICIT_SPONSOR_NAME_MINIMUM_CHARACTERS, EXPLICIT_SPONSOR_NAME_WORD_RE, EXPLICIT_SPONSOR_OFFER_CODE_RE, EXPLICIT_SPONSOR_PREROLL_ANCHOR_MAX_SECONDS, EXPLICIT_SPONSOR_PREROLL_LEFT_GAP_MAX_SECONDS, EXPLICIT_SPONSOR_SPOKEN_PATH_RE, EXPLICIT_SPONSOR_URL_RE, EXPLICIT_SUPPORT_OPENING_COMPATIBILITY_PATTERN, PARTNER_SPONSOR_OPENING_COMPATIBILITY_PATTERN

def explicit_sponsor_name_phrases(text, opening_pattern):
    """The names a host read might be repeating, longest first.

    A read says its sponsor over and over; a conversation that happens to open
    like one says it once. Counting that recurrence is the evidence that
    survives a transcript with no punctuation, and no punctuation is what the
    detector is handed: `videogame.town` reaches it as three ordinary words
    with no dot anywhere in them.

    Which words are the name is not knowable from the text alone, because
    nothing marks where it ends -- "brought to you by Video Game Town Video
    Game Town is an independent" runs the name straight into the next
    sentence. So return every prefix instead and let recurrence pick: only the
    real name comes back again.
    """
    match = opening_pattern.search(text)
    if match is None:
        return []
    words = [word.lower() for word in EXPLICIT_SPONSOR_NAME_WORD_RE.findall(text[match.end():])]
    while words and words[0] in EXPLICIT_SPONSOR_NAME_LEADING_FILLER:
        words.pop(0)
    phrases = []
    for length in range(min(len(words), EXPLICIT_SPONSOR_NAME_MAX_WORDS), 0, -1):
        phrase = " ".join(words[:length])
        # Short enough to be a common word is short enough to recur honestly.
        if len(phrase.replace(" ", "")) >= EXPLICIT_SPONSOR_NAME_MINIMUM_CHARACTERS:
            phrases.append(phrase)
    return phrases

def sponsor_name_recurrence_text(text, opening_pattern):
    """The part of the anchor segment where a name could come *back*.

    The anchor names its sponsor once by definition -- that is what "brought to
    you by" is followed by -- so counting that naming would give every anchor a
    free mention. Skip past the opening and the longest name it could have
    introduced, and count only what follows.
    """
    match = opening_pattern.search(text)
    if match is None:
        return text
    trailing = text[match.end():]
    words = list(EXPLICIT_SPONSOR_NAME_WORD_RE.finditer(trailing))
    if len(words) <= EXPLICIT_SPONSOR_NAME_MAX_WORDS:
        return ""
    return trailing[words[EXPLICIT_SPONSOR_NAME_MAX_WORDS - 1].end():]

def count_sponsor_name_mentions(text, phrases, counts):
    """Add this segment's mentions of each candidate name to the running count."""
    lowered = text.lower()
    for phrase in phrases:
        start = 0
        while True:
            found = lowered.find(phrase, start)
            if found < 0:
                break
            counts[phrase] = counts.get(phrase, 0) + 1
            start = found + len(phrase)

def explicit_sponsor_domain_seen(text):
    """Return whether one passage contains a domain or platform address."""
    return any(
        pattern.search(text) is not None
        for pattern in (
            EXPLICIT_SPONSOR_DOT_DOMAIN_RE,
            EXPLICIT_SPONSOR_URL_RE,
            EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE,
            EXPLICIT_SPONSOR_SPOKEN_PATH_RE,
        )
    )

def explicit_sponsor_destination_seen(text):
    """Return whether one passage contains a bounded sponsor destination."""
    return (
        explicit_sponsor_domain_seen(text)
        or EXPLICIT_SPONSOR_OFFER_CODE_RE.search(text) is not None
    )

def explicit_sponsor_anchor_ids(segments, opening_pattern):
    """Return deterministic anchor IDs from the raw aligned STT pass only."""
    return [
        segment_id
        for segment_id, segment in enumerate(segments)
        if opening_pattern.search(segment.text or "") is not None
    ]

def sponsor_anchor_is_covered(anchor_id, segments, detections):
    """Return whether a proposed raw-timed cut contains an anchor cue whole."""
    anchor = segments[anchor_id]
    return any(
        float(ad.start_s) <= float(anchor.start_s)
        and float(ad.end_s) >= float(anchor.end_s)
        for ad in detections
    )

def explicit_sponsor_opening_pattern(ads_module):
    """Build the worker-only anchor pattern without widening archive detection."""
    archive_opening_pattern = ads_module._EXPLICIT_HOST_READ_OPENING_RE  # noqa: SLF001
    return re.compile(
        f"(?:{archive_opening_pattern.pattern})"
        f"|{EXPLICIT_SUPPORT_OPENING_COMPATIBILITY_PATTERN}"
        f"|{PARTNER_SPONSOR_OPENING_COMPATIBILITY_PATTERN}",
        archive_opening_pattern.flags,
    )

def consecutive_preroll_start(ads_module, backend, segments, anchor_id):
    """Return zero only when the immediate prefix verifies as the same pod."""
    anchor = segments[anchor_id]
    first_start_s = float(segments[0].start_s)
    if (
        anchor_id != 1
        or float(anchor.start_s) - first_start_s > EXPLICIT_SPONSOR_PREROLL_ANCHOR_MAX_SECONDS
    ):
        return float(anchor.start_s)
    prefix_id = anchor_id - 1
    gap_s = float(anchor.start_s) - float(segments[prefix_id].end_s)
    if gap_s > EXPLICIT_SPONSOR_PREROLL_LEFT_GAP_MAX_SECONDS:
        return float(anchor.start_s)
    try:
        include = ads_module._probe_boundary_candidate(  # noqa: SLF001
            prefix_id,
            anchor_id,
            "left",
            segments,
            backend,
        )
    except Exception:  # noqa: BLE001 - model uncertainty must preserve source audio
        include = None
    result = "true" if include is True else "false" if include is False else "unanswered"
    _worker_reporting.progress(
        "ads.detect.recovery.preroll.left",
        f"prefix ID {prefix_id} gap={max(0.0, gap_s):.3f}s include={result}",
    )
    if include is True:
        _worker_reporting.progress(
            "ads.detect.recovery.preroll.extended",
            f"explicit anchor ID {anchor_id} joined opening prefix ID {prefix_id}",
        )
        return 0.0
    return float(anchor.start_s)

def _probe_opening_sponsor_interior(
    ads_module, backend, segments, anchor_id: int, evidence_id: int, candidate_id: int,
    sponsor_name: str,
):
    """Review one cue inside a verified consecutive opening commercial."""
    context_ids = tuple(range(max(0, anchor_id - 1), min(len(segments), evidence_id + 2)))
    rendered = "\n".join(
        ads_module._segment_prefix(segment_id, segments[segment_id])  # noqa: SLF001
        + (segments[segment_id].text or "")
        for segment_id in context_ids
    )
    if len(rendered) > COMMERCIAL_RECOVERY_CONTEXT_CHARS:
        raise ValueError("complete opening commercial context exceeds the rendering budget")
    prompt = f"""\
Review the complete opening passage. ID {anchor_id} ends by explicitly opening a {sponsor_name}
sponsor message; earlier words in that same cue may finish the preceding ad. ID {evidence_id}
contains the later commercial evidence. Is ID {candidate_id} the product-use story, marketing
scenario, or explanation that continues into that evidence? Such stories and rhetorical questions
used to demonstrate the sponsor count as advertising. The podcast's own game, reporting, interview,
host introduction, or discussion does not. Return only strict JSON {{"include": true}} or
{{"include": false}}, with no prose."""
    response, _tokens = backend.generate(
        prompt,
        f"{rendered}\ncandidate={candidate_id}",
        response_format={
            "type": "json_object",
            "schema": {
                "type": "object",
                "properties": {"include": {"type": "boolean"}},
                "required": ["include"],
                "additionalProperties": False,
            },
        },
    )
    parsed = json.loads(response)
    if not isinstance(parsed, dict) or set(parsed) != {"include"} or type(parsed["include"]) is not bool:
        raise ValueError("opening commercial interior response must contain one boolean")
    return parsed["include"]

def _commercial_recovery_context(
    ads_module, segments, first: int, last: int, total_seconds: float,
    *, flank_limit: int | None = None,
):
    """Return a bounded whole-envelope context, or raise before model work.

    The caller supplies the complete proposed cut, never merely the evidence
    that nominated it.  This keeps an editorial cue between two commercial
    phrases visible to the independent preservation review.
    """
    candidate_ids = tuple(range(first, last + 1))
    if (not candidate_ids or not 0 <= first <= last < len(segments)
            or not total_seconds > 0 or not total_seconds < float("inf")):
        raise ValueError("commercial envelope has invalid IDs or duration")
    start_s, end_s = float(segments[first].start_s), float(segments[last].end_s)
    duration = end_s - start_s
    if (not 0 <= start_s < end_s <= total_seconds
            or duration > COMMERCIAL_RECOVERY_MAX_CANDIDATE_SECONDS
            or duration / total_seconds > COMMERCIAL_RECOVERY_MAX_CANDIDATE_SHARE):
        raise ValueError("commercial envelope duration is unsafe")
    if first == 0 or last >= len(segments) - 1:
        raise ValueError("commercial envelope lacks programme context on both sides")
    remaining = COMMERCIAL_RECOVERY_CONTEXT_IDS - len(candidate_ids)
    if remaining < 2:
        raise ValueError("commercial envelope exceeds the bounded context ID budget")
    left_extra = min(first, remaining // 2, flank_limit if flank_limit is not None else remaining)
    right_extra = min(len(segments) - last - 1, remaining - left_extra)
    if flank_limit is not None:
        right_extra = min(right_extra, flank_limit)
    left_extra = min(first, remaining - right_extra, flank_limit if flank_limit is not None else remaining)
    context_ids = tuple(range(first - left_extra, last + right_extra + 1))
    if (len(context_ids) > COMMERCIAL_RECOVERY_CONTEXT_IDS
            or (first > 0 and context_ids[0] >= first) or context_ids[-1] <= last):
        raise ValueError("commercial envelope lacks programme context on both sides")
    # This review authorizes every byte in the proposed cut, so the archive's
    # head/tail truncation is unsafe here: it can hide programme in the middle
    # of one long cue.  Decline the candidate unless the complete envelope and
    # both programme flanks fit the hard request cap.
    rendered = "\n".join(
        ads_module._segment_prefix(segment_id, segments[segment_id])  # noqa: SLF001
        + (segments[segment_id].text or "")
        for segment_id in context_ids
    )
    if len(rendered) > COMMERCIAL_RECOVERY_CONTEXT_CHARS:
        raise ValueError("complete commercial envelope exceeds the rendering budget")
    return candidate_ids, context_ids, rendered
