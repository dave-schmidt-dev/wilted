"""Ad detection and removal for audio and article content.

Tasks 4.4-4.6: Sliding-window LLM-based ad detection in transcripts,
ffmpeg-based ad segment cutting, and article promotional content removal.

Usage:
    from wilted.ads import detect_ads, cut_ads, remove_promos

    # Detect ads in a podcast transcript
    ad_segments = detect_ads(segments, backend)

    # Cut detected ads from an audio file
    cut_ads(audio_path, ad_segments, output_path)

    # Remove promotional paragraphs from article text
    cleaned = remove_promos(article_text, backend)
"""

from __future__ import annotations

import logging
import math
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from inspect import Parameter, signature
from pathlib import Path
from typing import Any

from wilted.cache import check_ffmpeg
from wilted.llm import LLMBackend, parse_json_response

logger = logging.getLogger(__name__)

# Import TranscriptSegment from transcribe.py when available;
# fall back to local definition during parallel development.
try:
    from wilted.transcribe import TranscriptSegment
except ImportError:
    from dataclasses import dataclass as _dc

    @_dc
    class TranscriptSegment:  # type: ignore[no-redef]
        """Temporary local definition until transcribe.py is merged."""

        start_s: float
        end_s: float
        text: str


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


class EmptyCutResultError(ValueError):
    """Raised when ad cutting would leave no audio content to keep.

    Signals a degenerate case (the whole clip was flagged as ads) so callers
    can preserve the original audio instead of persisting a 0-byte file over
    it. See INV-4.
    """


@dataclass
class AdSegment:
    """A detected advertisement segment in an audio transcript."""

    start_s: float
    end_s: float
    confidence: float
    label: str  # "sponsor_read", "self_promo", "ad_break", "newsletter_pitch"


@dataclass(frozen=True)
class _CoarseAdRun:
    """Internal ad run retaining stable global transcript segment IDs."""

    start_id: int
    end_id: int
    confidence: float
    label: str


# ---------------------------------------------------------------------------
# Ad detection prompts
# ---------------------------------------------------------------------------

_AD_DETECT_SYSTEM_PROMPT = """\
You are an ad detection system. Classify EVERY supplied transcript segment, in its given ID order.
An ad is actual spoken promotional or persuasive sponsor copy intended to sell a product, service,
or subscription. Include an entire consecutive ad pod, including generic or topical two-sentence
openings, endorsements, product claims, URLs, offer codes, and final calls to action.
Include trailing legal disclaimers, offer restrictions, and terms that conclude the same ad pod.
Do NOT mark a brief sponsor acknowledgement or sponsor list, show housekeeping, an ad-free
subscription mention, sponsorship contact information, editorial discussion, or criticism of ads.

Return only one JSON object, with no prose or Markdown:
{"ads":[[1,"sponsor_read"]]}
Each ad entry is [global ID, label]. Include ONLY ads: every supplied ID omitted from ads is content.
Ad entries must remain in supplied order and never repeat an ID. Labels are "sponsor_read",
"self_promo", "ad_break", or "newsletter_pitch"."""

_AD_DETECT_CORRECTION_PROMPT = """\
Your previous response was invalid. Re-evaluate the same supplied segments. An ad is actual spoken
promotional or persuasive sponsor copy intended to sell a product, service, or subscription. Include
generic or topical two-sentence ad-pod openings, product claims, URLs, offer codes, and final calls
to action. Include trailing legal disclaimers, offer restrictions, and terms that conclude the same
ad pod. Do NOT mark brief sponsor acknowledgements, sponsor lists, show
housekeeping, ad-free subscription mentions, sponsorship contact information, or editorial discussion.
Return only one JSON object with no prose or Markdown:
{"ads":[[1,"sponsor_read"]]}
Each ad entry is [global ID, label]. Include ONLY ads: every supplied ID omitted from ads is content.
Ad entries must remain in supplied order and never repeat an ID. Labels are "sponsor_read",
"self_promo", "ad_break", or "newsletter_pitch"."""

_LEFT_BOUNDARY_VERIFY_SYSTEM_PROMPT = """\
You are deciding whether ONE transcript segment immediately adjacent to a detected spoken ad pod
belongs to that ad. Include the candidate only when the candidate itself promotes the sponsor or is
a grammatically incomplete continuation of the adjacent ad segment. Topical continuity, research
context, or a general opinion is not enough. Exclude editorial discussion and brief sponsor
acknowledgements. Return only the strict JSON object {"include": true} or {"include": false}, with
no prose or Markdown."""

_SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT = """\
CONFIRMED_AD_SEED_ID is inside an active spoken commercial, not the whole ad. Return the first
supplied global ID where actual podcast discussion resumes AFTER the commercial's remaining product
pitch, URL or offer, final call to action, acknowledgement, insertion gap, and trailing punctuation.
Do NOT return an ID merely because it is a new segment; it remains inside the ad unless program
discussion has clearly resumed. Return only {"content_start_id": ID}, with no prose or Markdown."""

_POD_START_VERIFY_SYSTEM_PROMPT = """\
You are finding the first left boundary of a confirmed spoken ad pod. The confirmed coarse run
cannot shrink: start_id must be at most CONFIRMED_START_ID. Include generic or story-like sponsor
copy that leads into the product pitch, but do not include the preceding editorial conversation.
Return only the strict JSON object {"start_id": ID}, with no prose or Markdown."""

_PREROLL_CONTENT_VERIFY_SYSTEM_PROMPT = """\
The excerpt begins with a confirmed commercial at ID 0. Find the first ID where the actual podcast
program begins after all consecutive pre-roll commercials and insertion gaps. Show-opening banter
or the show title counts as program. Use only a supplied ID. Return only the strict JSON object
{"content_start_id": ID}, with no prose or Markdown."""

_SPONSOR_ANCHOR_VERIFY_SYSTEM_PROMPT = """\
SPONSOR_OPENING_ID is the confirmed BEGINNING of a spoken sponsor read, not the whole ad. Sponsor
reads normally continue across many following IDs. Return the first supplied global ID where actual
podcast discussion resumes AFTER the sponsor's product pitch, URL or offer, final call to action,
sponsor acknowledgement, sponsor-related interview or housekeeping plug, and any trailing legal
terms. Do NOT return the ID immediately after the opening merely because it is a new segment; it
remains inside the ad unless program discussion has clearly resumed. Do not include post-ad editorial
discussion in the ad. Return only the strict JSON object {"content_start_id": ID}, with no prose or
Markdown."""

_PROMO_DETECT_SYSTEM_PROMPT = """\
You are a content filter. Identify promotional paragraphs in this article.
Promotional content includes: newsletter signup pitches, "related articles" sections, \
author bio/social media plugs, affiliate disclaimers, and "subscribe for more" calls to action.
Return a JSON object: {"promo_indices": [0, 5, 12]} listing the 0-based paragraph indices \
that are promotional. If none, return {"promo_indices": []}."""

_VALID_LABELS = {"sponsor_read", "self_promo", "ad_break", "newsletter_pitch"}
_AD_DETECT_RESPONSE_FORMAT: dict[str, Any] = {
    "type": "json_object",
    "schema": {
        "type": "object",
        "properties": {
            "ads": {
                "type": "array",
                "items": {
                    "type": "array",
                    "prefixItems": [
                        {"type": "integer"},
                        {"type": "string", "enum": sorted(_VALID_LABELS)},
                    ],
                    "minItems": 2,
                    "maxItems": 2,
                },
            }
        },
        "required": ["ads"],
        "additionalProperties": False,
    },
}
_BOUNDARY_VERIFY_RESPONSE_FORMAT: dict[str, Any] = {
    "type": "json_object",
    "schema": {
        "type": "object",
        "properties": {"include": {"type": "boolean"}},
        "required": ["include"],
        "additionalProperties": False,
    },
}
_BRACKETED_SEED_VERIFY_SYSTEM_PROMPT = """\
You are checking an earlier segment inside a bumper-bracketed break. A later supplied segment is an
explicit sponsor anchor. Decide whether the CANDIDATE IDs are genuinely earlier story-style commercial
copy from the same ad pod, or ordinary podcast/panel discussion before the sponsor read. A break
announcement or editorial discussion is content even when an earlier classifier called it an ad.
Return only the strict JSON object {"include": true} or {"include": false}, with no prose or Markdown.
"""
_MAX_CLASSIFICATION_BATCH_IDS = 64
_MAX_CLASSIFICATION_BATCH_CHARS = 12_000
_MAX_BRACKETED_POD_IDS = 128
_MAX_BRACKETED_POD_SECONDS = 10 * 60.0
_TRUNCATION_MARKER = " …[TRUNCATED]… "

_HOUSEKEEPING_CUES = (
    re.compile(r"\b(?:quick announcement|before we (?:dive|(?:get )?started))\b", re.IGNORECASE),
    re.compile(r"\b(?:thanks? (?:so much )?to|our sponsors? (?:include|are)|sponsor acknowledg)", re.IGNORECASE),
    re.compile(r"\bad[- ]free\s+(?:subscription|members?|version|feed|tier)\b", re.IGNORECASE),
    re.compile(r"\b(?:sponsorship|advertising)\s+(?:contact|inquir(?:y|ies))\b", re.IGNORECASE),
)

_SPARSE_PROMO_CUES = (
    re.compile(
        r"\b(?:brought to you by|paid for by|sponsor(?:ed|ship)?)\b",
        re.IGNORECASE,
    ),
    re.compile(r"\b[a-z0-9-]+\.(?:com|net|org|io)\b|\bdot[ -]?com\b", re.IGNORECASE),
    re.compile(r"\b(?:(?:promo|offer|discount) code|use code)\b", re.IGNORECASE),
    re.compile(
        r"\$\s*\d|\b\d+(?:\.\d+)?\s*(?:%|percent)\s+off\b|\b(?:price|priced|pricing|discount|free trial)\b",
        re.IGNORECASE,
    ),
    re.compile(r"\blimited[- ]time sale\b", re.IGNORECASE),
)

_SELF_PROMO_HOUSEKEEPING_CUES = (
    re.compile(r"\bhow can (?:folks|people|listeners|viewers|fans) support (?:us|the show)\b", re.IGNORECASE),
    re.compile(r"\b(?:premium|paid) membership\b", re.IGNORECASE),
    re.compile(r"\bad[- ]free (?:versions?|feeds?|episodes?)\b", re.IGNORECASE),
    re.compile(r"\b(?:premium|member)[ -]exclusive (?:shows?|content|episodes?)\b", re.IGNORECASE),
)

_SPARSE_CTA_VERB = re.compile(r"\b(?:visit|try|switch|sign up|download)\b", re.IGNORECASE)
_SPARSE_CTA_CONTEXT = re.compile(
    r"\b(?:today|now|free|trial|app|plan|code|offer|deal|website|dot[ -]?com)\b",
    re.IGNORECASE,
)
_SPARSE_SALES_VERB = re.compile(r"\b(?:shop|save|score|buy|order)\b", re.IGNORECASE)
_SPARSE_SALES_CONTEXT = re.compile(r"\b(?:sale|deal|offer|event)\b", re.IGNORECASE)
_SPARSE_PRODUCT_CONTEXT = re.compile(
    r"\b(?:gear|laptops?|desktops?|computers?|devices?|products?|items?|services?|plans?)\b",
    re.IGNORECASE,
)

_SPONSOR_OPENING_RE = re.compile(
    r"\b(?:this|the)\s+episode\s+is\s+(?:brought\s+to\s+you\s+by|sponsored\s+by)\b"
    r"|\bthis\s+message\s+is\s+brought\s+to\s+you\s+by\b"
    r"|\bbrought\s+to\s+you\s+by\b|\bpaid\s+for\s+by\b|\bpaid\s+ad\b",
    re.IGNORECASE,
)

_EXPLICIT_HOST_READ_OPENING_RE = re.compile(
    r"\b(?:"
    r"(?:this|the)\s+(?:episode|show)(?:\s+of\s+[^.!?]{1,80}?)?\s+(?:is\s+)?brought\s+to\s+you"
    r"(?:\s+today)?\s+by|"
    r"our\s+show(?:\s+today)?\s+(?:is\s+)?brought\s+to\s+you\s+by|"
    r"today(?:'s|’s|\s+is\s+our)\s+sponsor(?:\s+is)?|"
    r"our\s+sponsor\s+for\s+this\s+(?:section|segment|episode|show)"
    r")\b",
    re.IGNORECASE,
)

_SPONSOR_TAIL_RE = re.compile(
    r"\b(?:"
    r"thank\s+you\b.{0,160}\b(?:for\s+)?supporting\b|"
    r"(?:my|our|the)\s+interview\s+with\b.{0,240}\b(?:available|youtube|feed)\b"
    r")",
    re.IGNORECASE,
)

_OUTGOING_BREAK_RE = re.compile(r"\b(?:we(?:'|’)ll|we will)\s+be\s+right\s+back\b", re.IGNORECASE)
_RETURN_FROM_BREAK_RE = re.compile(
    r"\b(?:and\s+now\s+)?back\s+to\s+(?:the\s+)?(?:show|episode|program)\b", re.IGNORECASE
)
_TRAILING_DISCLAIMER_RE = re.compile(
    r"\b(?:"
    r"does not (?:provide|constitute) (?:legal|financial|medical|tax|investment) advice|"
    r"not intended as (?:legal|financial|medical|tax|investment) advice|"
    r"independently review and verify|"
    r"terms and conditions apply|"
    r"(?:offer|eligibility) restrictions apply|"
    r"void where prohibited"
    r")\b",
    re.IGNORECASE,
)


def _parse_ad_response(response: str, expected_ids: list[int]) -> list[tuple[int, bool, str | None]]:
    """Validate compact ad-only decisions and infer all omitted IDs as content.

    The supplied global IDs are the complete classification domain. This allows
    content to be represented implicitly, while still proving an ordered
    decision for every ID and rejecting duplicate or out-of-window ad IDs.
    """
    parsed = parse_json_response(response)
    if not isinstance(parsed, dict) or set(parsed) != {"ads"}:
        raise ValueError("response must contain exactly ads")
    ads = parsed["ads"]
    if not isinstance(ads, list):
        raise ValueError("ads must be a list")

    positions = {segment_id: position for position, segment_id in enumerate(expected_ids)}
    if len(positions) != len(expected_ids):
        raise ValueError("expected IDs must be unique")

    ad_labels: dict[int, str] = {}
    ad_ids: list[int] = []
    for item in ads:
        if not isinstance(item, list) or len(item) != 2:
            raise ValueError("each ad must be [id, label]")
        segment_id, label = item
        if isinstance(segment_id, bool) or not isinstance(segment_id, int):
            raise ValueError("ad IDs must be integers")
        if segment_id not in positions:
            raise ValueError("ads contains an unexpected ID")
        if not isinstance(label, str) or label not in _VALID_LABELS:
            raise ValueError("invalid ad label")
        ad_ids.append(segment_id)
        ad_labels[segment_id] = label
    if ad_ids != sorted(ad_ids, key=positions.__getitem__):
        raise ValueError("ads IDs must remain in supplied order")
    if len(set(ad_ids)) != len(ad_ids):
        raise ValueError("ads IDs must not be duplicated")
    return [
        (segment_id, False, None)
        if segment_id not in ad_labels
        else (segment_id, True, ad_labels[segment_id])
        for segment_id in expected_ids
    ]


def _backend_supports_response_format(backend: LLMBackend) -> bool:
    """Return whether a backend or test double accepts ``response_format``.

    Existing third-party and test backends may still expose the original
    two-argument method. Signature inspection keeps those implementations
    usable without treating an inference-time ``TypeError`` as an API probe.
    """
    generate = backend.generate
    side_effect = getattr(generate, "side_effect", None)
    if side_effect is not None and not callable(side_effect):
        # ``MagicMock(side_effect=[...])`` accepts arbitrary keywords while
        # returning its queued responses, and is a common test double.
        return True
    if callable(side_effect):
        generate = side_effect
    else:
        wrapped = getattr(generate, "_mock_wraps", None)
        if callable(wrapped):
            generate = wrapped
    try:
        parameters = signature(generate).parameters.values()
    except (TypeError, ValueError):
        return False
    return any(
        parameter.kind is Parameter.VAR_KEYWORD or parameter.name == "response_format" for parameter in parameters
    )


def _generate_ad_classification(
    backend: LLMBackend, system_prompt: str, transcript_text: str
) -> tuple[str, int]:
    """Generate a compact ad response, applying constraints when supported."""
    return _generate_constrained_response(backend, system_prompt, transcript_text, _AD_DETECT_RESPONSE_FORMAT)


def _generate_constrained_response(
    backend: LLMBackend,
    system_prompt: str,
    transcript_text: str,
    response_format: dict[str, Any],
) -> tuple[str, int]:
    """Generate a constrained JSON response when the backend supports it."""
    if _backend_supports_response_format(backend):
        return backend.generate(system_prompt, transcript_text, response_format=response_format)
    return backend.generate(system_prompt, transcript_text)


def _id_response_format(property_name: str, permitted_ids: list[int]) -> dict[str, Any]:
    """Build a strict response schema limited to the supplied global IDs."""
    return {
        "type": "json_object",
        "schema": {
            "type": "object",
            "properties": {property_name: {"type": "integer", "enum": permitted_ids}},
            "required": [property_name],
            "additionalProperties": False,
        },
    }


def _is_sponsor_housekeeping(text: str) -> bool:
    """Return whether text has multiple independent non-ad housekeeping signals."""
    return sum(bool(pattern.search(text)) for pattern in _HOUSEKEEPING_CUES) >= 2


def _override_sponsor_housekeeping(
    classifications: list[tuple[int, bool, str | None]], segments: list[TranscriptSegment]
) -> list[tuple[int, bool, str | None]]:
    """Convert high-confidence housekeeping false positives to content before voting."""
    return [
        (segment_id, False, None) if is_ad and _is_sponsor_housekeeping(segments[segment_id].text) else entry
        for entry in classifications
        for segment_id, is_ad, _label in [entry]
    ]


def _has_sparse_promo_evidence(coarse_run: _CoarseAdRun, segments: list[TranscriptSegment]) -> bool:
    """Return whether a one- or two-segment run contains a strong promotional cue."""
    text = " ".join(segments[segment_id].text for segment_id in range(coarse_run.start_id, coarse_run.end_id + 1))
    if any(pattern.search(text) for pattern in _SPARSE_PROMO_CUES):
        return True
    return _has_sparse_call_to_action(text)


def _has_sparse_call_to_action(text: str) -> bool:
    """Return whether bounded generic wording supplies a commercial call to action."""
    verb_matches = list(_SPARSE_CTA_VERB.finditer(text))
    context_matches = list(_SPARSE_CTA_CONTEXT.finditer(text))
    if any(abs(verb.start() - context.start()) <= 80 for verb in verb_matches for context in context_matches):
        return True

    sales_matches = list(_SPARSE_SALES_VERB.finditer(text))
    sales_context_matches = list(_SPARSE_SALES_CONTEXT.finditer(text))
    product_matches = list(_SPARSE_PRODUCT_CONTEXT.finditer(text))
    return any(
        max(match.start(), context.start(), product.start())
        - min(match.start(), context.start(), product.start())
        <= 120
        for match in sales_matches
        for context in sales_context_matches
        for product in product_matches
    )


def _has_strong_sparse_seed(coarse_run: _CoarseAdRun, segments: list[TranscriptSegment]) -> bool:
    """Return whether a small coarse run has a CTA strong enough for wider start review."""
    if coarse_run.end_id - coarse_run.start_id + 1 > 2:
        return False
    text = " ".join(segments[segment_id].text for segment_id in range(coarse_run.start_id, coarse_run.end_id + 1))
    return _has_sparse_call_to_action(text)


def _is_self_promo_housekeeping_run(coarse_run: _CoarseAdRun, segments: list[TranscriptSegment]) -> bool:
    """Return whether a self-promo run is multi-cue membership housekeeping."""
    if coarse_run.label != "self_promo":
        return False
    text = " ".join(segments[segment_id].text for segment_id in range(coarse_run.start_id, coarse_run.end_id + 1))
    return sum(bool(pattern.search(text)) for pattern in _SELF_PROMO_HOUSEKEEPING_CUES) >= 2


def _has_independent_commercial_cue(text: str) -> bool:
    """Return whether text has a commercial signal beyond a sponsor acknowledgement."""
    if any(pattern.search(text) for pattern in _SPARSE_PROMO_CUES[1:]):
        return True
    return _has_sparse_call_to_action(text)


def _verify_bracketed_early_seed(
    coarse_run: _CoarseAdRun,
    outgoing_id: int,
    sponsor_id: int,
    segments: list[TranscriptSegment],
    backend: LLMBackend,
) -> bool:
    """Independently accept an early story-ad seed, failing closed on editorial or invalid output."""
    local_min = max(outgoing_id + 1, coarse_run.start_id - 4)
    local_max = min(sponsor_id, coarse_run.end_id + 4)
    context_ids = sorted({*range(local_min, local_max + 1), sponsor_id})
    transcript_text = _render_segments_bounded(
        context_ids,
        segments,
        headers=[
            f"CANDIDATE_MIN_ID={coarse_run.start_id}",
            f"CANDIDATE_MAX_ID={coarse_run.end_id}",
            f"SPONSOR_ANCHOR_ID={sponsor_id}",
            "BOUNDED_CONTEXT:",
        ],
    )
    try:
        response, _tokens = _generate_constrained_response(
            backend,
            _BRACKETED_SEED_VERIFY_SYSTEM_PROMPT,
            transcript_text,
            _BOUNDARY_VERIFY_RESPONSE_FORMAT,
        )
        return _parse_boundary_response(response)
    except Exception as exc:
        logger.warning(
            "Bracketed early-seed verifier failed for run %d-%d; preserving pre-anchor content: %s",
            coarse_run.start_id,
            coarse_run.end_id,
            exc,
        )
        return False


def _recover_bracketed_ad_pods(
    segments: list[TranscriptSegment], backend: LLMBackend, positive_runs: list[_CoarseAdRun]
) -> list[AdSegment]:
    """Recover explicit bumper-bracketed commercial pods that classification missed.

    Empty insertion slots use the same bumpers, so both an explicit sponsor opening and a second,
    independent commercial cue are required before cutting anything.
    """
    recovered: list[AdSegment] = []
    for outgoing_id, outgoing in enumerate(segments):
        if not _OUTGOING_BREAK_RE.search(outgoing.text):
            continue
        for return_id in range(outgoing_id + 1, len(segments)):
            if (
                return_id - outgoing_id > _MAX_BRACKETED_POD_IDS
                or segments[return_id].start_s - outgoing.start_s > _MAX_BRACKETED_POD_SECONDS
            ):
                break
            if not _RETURN_FROM_BREAK_RE.search(segments[return_id].text):
                continue
            interior_ids = range(outgoing_id + 1, return_id)
            sponsor_id = next(
                (segment_id for segment_id in interior_ids if _SPONSOR_OPENING_RE.search(segments[segment_id].text)),
                None,
            )
            interior = " ".join(segment.text for segment in segments[outgoing_id + 1 : return_id])
            if sponsor_id is None or not _has_independent_commercial_cue(interior):
                break
            earlier_positive_runs = [
                run
                for run in positive_runs
                if run.end_id > outgoing_id and run.start_id < sponsor_id and run.start_id < return_id
            ]
            if earlier_positive_runs:
                first_positive = min(earlier_positive_runs, key=lambda run: run.start_id)
                if _verify_bracketed_early_seed(first_positive, outgoing_id, sponsor_id, segments, backend):
                    recovered_start_id = max(
                        outgoing_id + 1,
                        _verify_pod_start(first_positive, segments, backend),
                    )
                    for _ in range(2):
                        candidate_id = recovered_start_id - 1
                        if candidate_id <= outgoing_id:
                            break
                        if (
                            _probe_boundary_candidate(
                                candidate_id,
                                recovered_start_id,
                                "left",
                                segments,
                                backend,
                            )
                            is not True
                        ):
                            break
                        recovered_start_id = candidate_id
                else:
                    recovered_start_id = sponsor_id
            else:
                recovered_start_id = sponsor_id
            content_id = return_id + 1
            while content_id < len(segments) and not re.search(r"[A-Za-z0-9]{2,}", segments[content_id].text):
                content_id += 1
            end_id = content_id - 1 if content_id < len(segments) else len(segments) - 1
            recovered.append(
                AdSegment(
                    _refine_ad_start_from_tokens(segments[recovered_start_id]),
                    segments[end_id].end_s,
                    1.0,
                    "ad_break",
                )
            )
            break
    return recovered


def _recover_explicit_sponsor_pods(
    segments: list[TranscriptSegment], backend: LLMBackend, positive_runs: list[_CoarseAdRun]
) -> tuple[list[AdSegment], list[tuple[int, int]]]:
    """Recover verified host reads and claim their positive seed ranges."""
    recovered: list[AdSegment] = []
    claimed_ranges: list[tuple[int, int]] = []
    recovered_id_ranges: list[tuple[int, int]] = []
    for anchor_id, anchor in enumerate(segments):
        if _EXPLICIT_HOST_READ_OPENING_RE.search(anchor.text) is None:
            continue
        if any(start_id <= anchor_id <= end_id for start_id, end_id in recovered_id_ranges):
            continue

        context_ids = [anchor_id]
        context_truncated = False
        for segment_id in range(anchor_id + 1, len(segments)):
            if len(context_ids) >= 64 or segments[segment_id].start_s - anchor.start_s > 10 * 60:
                context_truncated = True
                break
            context_ids.append(segment_id)
        if len(context_ids) < 2:
            continue

        window_max = context_ids[-1]
        context_runs = [run for run in positive_runs if run.start_id <= window_max and run.end_id >= anchor_id]
        if not context_runs:
            continue
        claimed_ranges.extend((min(anchor_id, run.start_id), run.end_id) for run in context_runs)
        transcript_text = _render_segments_bounded(
            context_ids,
            segments,
            headers=[f"SPONSOR_OPENING_ID={anchor_id}", "BOUNDED_CONTEXT:"],
        )
        try:
            response, _tokens = _generate_constrained_response(
                backend,
                _SPONSOR_ANCHOR_VERIFY_SYSTEM_PROMPT,
                transcript_text,
                _id_response_format("content_start_id", context_ids[1:]),
            )
            content_start_id = _parse_preroll_content_response(response, anchor_id + 1, window_max)
        except Exception as exc:
            logger.warning("Sponsor-anchor verifier failed for ID %d; not recovering pod: %s", anchor_id, exc)
            continue

        tail_seen = False
        for _ in range(3):
            candidate_text = segments[content_start_id].text.strip()
            is_tail = _SPONSOR_TAIL_RE.search(candidate_text) is not None
            is_tail_punctuation = tail_seen and bool(candidate_text) and not any(
                char.isalnum() for char in candidate_text
            )
            if not (is_tail or is_tail_punctuation):
                break
            tail_seen = True
            content_start_id += 1
            if content_start_id > window_max:
                break
        if content_start_id > window_max:
            logger.warning("Sponsor-anchor verifier for ID %d ended without verified program content", anchor_id)
            continue
        if context_truncated and content_start_id == window_max:
            logger.warning("Sponsor-anchor verifier for ID %d ended at a truncated context edge", anchor_id)
            continue
        recovered_end_id = content_start_id - 1
        if not any(run.start_id <= recovered_end_id and run.end_id >= anchor_id for run in positive_runs):
            logger.warning("Sponsor-anchor verifier for ID %d did not overlap a positive classification", anchor_id)
            continue

        recovered.append(
            AdSegment(
                _refine_ad_start_from_tokens(anchor, _EXPLICIT_HOST_READ_OPENING_RE),
                _last_meaningful_ad_end(content_start_id, anchor_id, segments),
                1.0,
                "sponsor_read",
            )
        )
        recovered_id_ranges.append((anchor_id, recovered_end_id))
    return recovered, claimed_ranges


def _parse_boundary_response(response: str) -> bool:
    """Validate one immediate-neighbor boundary response."""
    parsed = parse_json_response(response)
    if not isinstance(parsed, dict) or set(parsed) != {"include"} or not isinstance(parsed["include"], bool):
        raise ValueError("boundary response must be exactly {'include': true|false}")
    return parsed["include"]


def _parse_pod_start_response(response: str, window_min: int, coarse_start: int) -> int:
    """Validate one bounded left-edge pod-start response."""
    parsed = parse_json_response(response)
    if not isinstance(parsed, dict) or set(parsed) != {"start_id"}:
        raise ValueError("pod-start response must contain exactly start_id")
    start_id = parsed["start_id"]
    if isinstance(start_id, bool) or not isinstance(start_id, int):
        raise ValueError("pod-start response start_id must be an integer")
    if not window_min <= start_id <= coarse_start:
        raise ValueError("pod-start response cannot shrink or exceed the supplied window")
    return start_id


def _parse_preroll_content_response(response: str, minimum_id: int, window_max: int) -> int:
    """Validate the first program-content ID returned for a pre-roll pod."""
    parsed = parse_json_response(response)
    if not isinstance(parsed, dict) or set(parsed) != {"content_start_id"}:
        raise ValueError("pre-roll response must contain exactly content_start_id")
    content_start_id = parsed["content_start_id"]
    if isinstance(content_start_id, bool) or not isinstance(content_start_id, int):
        raise ValueError("pre-roll content_start_id must be an integer")
    if not minimum_id <= content_start_id <= window_max:
        raise ValueError("pre-roll response cannot precede the coarse run or exceed supplied context")
    return content_start_id


# ---------------------------------------------------------------------------
# Helpers — chunking
# ---------------------------------------------------------------------------


def _chunk_segments(
    segments: list[TranscriptSegment],
    chunk_minutes: float,
    overlap_minutes: float,
) -> list[list[TranscriptSegment]]:
    """Split transcript segments into overlapping time-based chunks.

    Args:
        segments: Ordered list of transcript segments.
        chunk_minutes: Duration of each chunk window in minutes.
        overlap_minutes: Overlap between consecutive windows in minutes.

    Returns:
        List of segment groups, one per chunk window.
    """
    chunk_id_groups = _chunk_segment_ids(segments, chunk_minutes, overlap_minutes)
    return [[segments[segment_id] for segment_id in chunk_ids] for chunk_ids in chunk_id_groups]


def _chunk_segment_ids(
    segments: list[TranscriptSegment],
    chunk_minutes: float,
    overlap_minutes: float,
) -> list[list[int]]:
    """Split transcript indices into the original overlapping temporal windows."""
    if not segments:
        return []

    chunk_s = chunk_minutes * 60.0
    overlap_s = overlap_minutes * 60.0
    step_s = chunk_s - overlap_s

    if step_s <= 0:
        raise ValueError("chunk_minutes must be greater than overlap_minutes")

    # Determine total time span
    total_end = max(seg.end_s for seg in segments)

    chunks: list[list[int]] = []
    window_start = 0.0

    while window_start < total_end:
        window_end = window_start + chunk_s
        # Collect all segments that overlap this window
        chunk = [
            segment_id
            for segment_id, segment in enumerate(segments)
            if segment.end_s > window_start and segment.start_s < window_end
        ]
        if chunk:
            chunks.append(chunk)
        window_start += step_s

    return chunks


def _segment_prefix(segment_id: int, segment: TranscriptSegment) -> str:
    """Render the non-text portion of one transcript segment."""
    return f"[ID {segment_id}] [{segment.start_s:.2f}s - {segment.end_s:.2f}s] "


def _truncate_head_tail(text: str, max_chars: int) -> str:
    """Bound text deterministically while retaining evidence from both ends."""
    if len(text) <= max_chars:
        return text
    if max_chars <= len(_TRUNCATION_MARKER):
        return _TRUNCATION_MARKER[:max_chars]
    remaining = max_chars - len(_TRUNCATION_MARKER)
    head_chars = (remaining + 1) // 2
    tail_chars = remaining // 2
    tail = text[-tail_chars:] if tail_chars else ""
    return text[:head_chars] + _TRUNCATION_MARKER + tail


def _render_segments_bounded(
    segment_ids: list[int],
    segments: list[TranscriptSegment],
    headers: list[str] | None = None,
    max_chars: int = _MAX_CLASSIFICATION_BATCH_CHARS,
) -> str:
    """Render required IDs under a hard cap with an equal text budget per ID."""
    header_lines = headers or []
    prefixes = [_segment_prefix(segment_id, segments[segment_id]) for segment_id in segment_ids]
    line_count = len(header_lines) + len(segment_ids)
    fixed_chars = sum(map(len, header_lines)) + sum(map(len, prefixes)) + max(0, line_count - 1)
    if fixed_chars > max_chars:
        raise ValueError("required transcript IDs and headers exceed the rendering budget")

    text_budget = max_chars - fixed_chars
    per_segment_budget, remainder = divmod(text_budget, len(segment_ids)) if segment_ids else (0, 0)
    rendered_segments = []
    for position, (segment_id, prefix) in enumerate(zip(segment_ids, prefixes, strict=True)):
        budget = per_segment_budget + (position < remainder)
        rendered_segments.append(prefix + _truncate_head_tail(segments[segment_id].text, budget))
    return "\n".join(header_lines + rendered_segments)


def _split_classification_batches(
    chunk_ids: list[int], segments: list[TranscriptSegment]
) -> list[tuple[list[int], str]]:
    """Split one temporal window into bounded disjoint ordered requests."""
    batches: list[tuple[list[int], str]] = []
    batch_ids: list[int] = []
    batch_lines: list[str] = []
    rendered_chars = 0

    for segment_id in chunk_ids:
        line = _segment_prefix(segment_id, segments[segment_id]) + segments[segment_id].text
        added_chars = len(line) + bool(batch_lines)
        if batch_ids and (
            len(batch_ids) >= _MAX_CLASSIFICATION_BATCH_IDS
            or rendered_chars + added_chars > _MAX_CLASSIFICATION_BATCH_CHARS
        ):
            batches.append((batch_ids, _render_segments_bounded(batch_ids, segments)))
            batch_ids, batch_lines, rendered_chars = [], [], 0
            added_chars = len(line)
        batch_ids.append(segment_id)
        batch_lines.append(line)
        rendered_chars += added_chars

    if batch_ids:
        batches.append((batch_ids, _render_segments_bounded(batch_ids, segments)))
    return batches


def _classify_batch(
    batch_ids: list[int],
    segments: list[TranscriptSegment],
    backend: LLMBackend,
    window_index: int,
    batch_path: str,
    transcript_text: str | None = None,
) -> list[tuple[int, bool, str | None]]:
    """Classify one batch, recursively halving invalid multi-ID responses."""
    if transcript_text is None:
        transcript_text = _render_segments_bounded(batch_ids, segments)

    last_error: Exception | None = None
    for attempt, prompt in enumerate((_AD_DETECT_SYSTEM_PROMPT, _AD_DETECT_CORRECTION_PROMPT), start=1):
        try:
            response, _tokens = _generate_ad_classification(backend, prompt, transcript_text)
            classifications = _parse_ad_response(response, batch_ids)
            return _override_sponsor_housekeeping(classifications, segments)
        except Exception as exc:
            last_error = exc
            if attempt == 1:
                logger.warning(
                    "Window %d batch %s: invalid ad-detection response; retrying: %s",
                    window_index,
                    batch_path,
                    exc,
                )

    if len(batch_ids) == 1:
        logger.warning(
            "Window %d batch %s: singleton failed after corrective retry; classifying ID %d as content: %s",
            window_index,
            batch_path,
            batch_ids[0],
            last_error,
        )
        return [(batch_ids[0], False, None)]

    midpoint = len(batch_ids) // 2
    left_ids, right_ids = batch_ids[:midpoint], batch_ids[midpoint:]
    logger.warning(
        "Window %d batch %s: failed after corrective retry; splitting %d IDs into %d and %d: %s",
        window_index,
        batch_path,
        len(batch_ids),
        len(left_ids),
        len(right_ids),
        last_error,
    )
    return _classify_batch(left_ids, segments, backend, window_index, f"{batch_path}L") + _classify_batch(
        right_ids, segments, backend, window_index, f"{batch_path}R"
    )


# ---------------------------------------------------------------------------
# Ad detection — sliding window
# ---------------------------------------------------------------------------


def detect_ads(
    segments: list[TranscriptSegment],
    backend: LLMBackend,
    chunk_minutes: float = 10.0,
    overlap_minutes: float = 2.0,
    confidence_threshold: float = 0.8,
) -> list[AdSegment]:
    """Detect advertisements in a transcript using LLM-based sliding window analysis.

    Args:
        segments: Ordered transcript segments with timing info.
        backend: A loaded LLM backend for inference.
        chunk_minutes: Size of each analysis window in minutes.
        overlap_minutes: Overlap between consecutive windows.
        confidence_threshold: Minimum confidence to keep a detection.

    Returns:
        Sorted list of AdSegment detections, merged and filtered.
    """
    if not segments:
        return []

    chunks = _chunk_segment_ids(segments, chunk_minutes, overlap_minutes)
    if not chunks:
        return []

    raw_classifications: list[list[tuple[int, bool, str | None]]] = []

    for chunk_index, chunk_ids in enumerate(chunks):
        window_classifications: list[tuple[int, bool, str | None]] = []
        for batch_index, (batch_ids, transcript_text) in enumerate(_split_classification_batches(chunk_ids, segments)):
            window_classifications.extend(
                _classify_batch(
                    batch_ids,
                    segments,
                    backend,
                    chunk_index,
                    str(batch_index),
                    transcript_text,
                )
            )

        raw_classifications.append(window_classifications)
        logger.debug("Window %d: classified %d transcript segments", chunk_index, len(window_classifications))

    coarse_runs = _resolve_overlaps(raw_classifications, segments)
    eligible_runs = [run for run in coarse_runs if run.confidence >= confidence_threshold]
    promo_evidenced_runs: list[_CoarseAdRun] = []
    for run in eligible_runs:
        if _is_self_promo_housekeeping_run(run, segments):
            logger.info("Discarding self-promo housekeeping run %d-%d", run.start_id, run.end_id)
            continue
        coarse_size = run.end_id - run.start_id + 1
        if coarse_size <= 2 and not _has_sparse_promo_evidence(run, segments):
            logger.info("Discarding sparse ad run %d-%d without promotional evidence", run.start_id, run.end_id)
            continue
        promo_evidenced_runs.append(run)
    bracketed_pods = _recover_bracketed_ad_pods(segments, backend, eligible_runs)
    anchor_pods, claimed_anchor_ranges = _recover_explicit_sponsor_pods(segments, backend, eligible_runs)
    recovered_pods = [*bracketed_pods, *anchor_pods]
    recovered_ranges = [(pod.start_s, pod.end_s) for pod in recovered_pods]
    verified_runs: list[AdSegment] = []
    for run in promo_evidenced_runs:
        overlaps_recovery = any(
            segments[run.start_id].start_s <= end_s and segments[run.end_id].end_s >= start_s
            for start_s, end_s in recovered_ranges
        )
        claimed_by_anchor = any(
            run.start_id <= end_id and run.end_id >= start_id for start_id, end_id in claimed_anchor_ranges
        )
        if overlaps_recovery or claimed_by_anchor:
            continue
        verified = _verify_ad_boundaries(run, segments, backend)
        if verified is not None:
            verified_runs.append(verified)
    return _merge_adjacent(sorted([*verified_runs, *recovered_pods], key=lambda pod: pod.start_s))


def _resolve_overlaps(
    raw_classifications: list[list[tuple[int, bool, str | None]]], segments: list[TranscriptSegment]
) -> list[_CoarseAdRun]:
    """Resolve overlap votes by global segment ID; a tie is content."""
    votes: list[list[tuple[bool, str | None]]] = [[] for _ in segments]
    for chunk in raw_classifications:
        for segment_id, is_ad, label in chunk:
            votes[segment_id].append((is_ad, label))

    decisions: list[tuple[bool, float, str]] = []
    for segment_votes in votes:
        ad_votes = [(is_ad, label) for is_ad, label in segment_votes if is_ad]
        ratio = len(ad_votes) / len(segment_votes) if segment_votes else 0.0
        is_ad = bool(segment_votes) and len(ad_votes) > len(segment_votes) - len(ad_votes)
        labels = [label for _is_ad, label in ad_votes if label is not None]
        dominant_label = max(sorted(set(labels)), key=labels.count) if labels else "ad_break"
        decisions.append((is_ad, ratio, dominant_label))
    decisions = _complete_trailing_disclaimer_decisions(decisions, segments)

    result: list[_CoarseAdRun] = []
    index = 0
    while index < len(segments):
        if not decisions[index][0]:
            index += 1
            continue
        start_id, confidences, labels = index, [], []
        while index < len(segments) and decisions[index][0]:
            confidences.append(decisions[index][1])
            labels.extend(label for is_ad, label in votes[index] if is_ad and label is not None)
            index += 1
        result.append(
            _CoarseAdRun(
                start_id=start_id,
                end_id=index - 1,
                confidence=sum(confidences) / len(confidences),
                label=max(sorted(set(labels)), key=labels.count),
            )
        )
    return result


def _complete_trailing_disclaimer_decisions(
    decisions: list[tuple[bool, float, str]], segments: list[TranscriptSegment]
) -> list[tuple[bool, float, str]]:
    """Attach explicit trailing disclaimers after final vote aggregation.

    A strong disclaimer phrase must immediately follow a final ad decision.
    Punctuation-only segments continue only an already recognized disclaimer
    tail. Inferred segments inherit the adjacent ad's confidence and label.
    """
    completed = list(decisions)
    disclaimer_tail = False
    for segment_id in range(1, len(completed)):
        previous_is_ad, previous_confidence, previous_label = completed[segment_id - 1]
        is_ad, _confidence, _label = completed[segment_id]
        if is_ad:
            disclaimer_tail = _TRAILING_DISCLAIMER_RE.search(segments[segment_id].text) is not None
            continue
        if not previous_is_ad:
            disclaimer_tail = False
            continue

        text = segments[segment_id].text.strip()
        is_explicit_disclaimer = _TRAILING_DISCLAIMER_RE.search(text) is not None
        is_punctuation_continuation = disclaimer_tail and bool(text) and not any(char.isalnum() for char in text)
        if is_explicit_disclaimer or is_punctuation_continuation:
            completed[segment_id] = (True, previous_confidence, previous_label)
            disclaimer_tail = is_explicit_disclaimer or disclaimer_tail
        else:
            disclaimer_tail = False
    return completed


def _probe_boundary_candidate(
    candidate_id: int,
    adjacent_ad_id: int,
    edge: str,
    segments: list[TranscriptSegment],
    backend: LLMBackend,
) -> bool | None:
    """Ask whether one immediate neighbor belongs to an existing ad run."""
    context_ids = list(range(max(0, candidate_id - 1), min(len(segments), candidate_id + 2)))
    candidate = segments[candidate_id]
    transcript_text = _render_segments_bounded(
        context_ids,
        segments,
        headers=[
            f"EDGE={edge}",
            f"CANDIDATE_ID={candidate_id}",
            f"CANDIDATE_TIMESTAMPS={candidate.start_s:.2f}s-{candidate.end_s:.2f}s",
            f"ADJACENT_AD_ID={adjacent_ad_id}",
            "BOUNDED_CONTEXT:",
        ],
    )
    try:
        response, _tokens = _generate_constrained_response(
            backend,
            _LEFT_BOUNDARY_VERIFY_SYSTEM_PROMPT,
            transcript_text,
            _BOUNDARY_VERIFY_RESPONSE_FORMAT,
        )
        return _parse_boundary_response(response)
    except Exception as exc:
        logger.warning("Boundary verifier failed for %s candidate %d; not expanding edge: %s", edge, candidate_id, exc)
        return None


def _verify_sparse_content_start(
    coarse_run: _CoarseAdRun,
    confirmed_start_id: int,
    segments: list[TranscriptSegment],
    backend: LLMBackend,
) -> int | None:
    """Find bounded first content after a sparse ad seed, failing closed."""
    window_max = min(len(segments) - 1, coarse_run.end_id + 16)
    context_ids = list(range(coarse_run.end_id, window_max + 1))
    transcript_text = _render_segments_bounded(
        context_ids,
        segments,
        headers=[
            f"CONFIRMED_START_ID={confirmed_start_id}",
            f"CONFIRMED_AD_SEED_ID={coarse_run.end_id}",
            f"CANDIDATE_CONTENT_MAX_ID={window_max}",
            "BOUNDED_CONTEXT:",
        ],
    )
    try:
        response, _tokens = _generate_constrained_response(
            backend,
            _SPARSE_CONTENT_VERIFY_SYSTEM_PROMPT,
            transcript_text,
            _id_response_format("content_start_id", context_ids[1:]),
        )
        content_start_id = _parse_preroll_content_response(response, coarse_run.end_id + 1, window_max)
        if content_start_id == window_max:
            raise ValueError("sparse content-start response ended at unsafe window edge")
        return content_start_id
    except Exception as exc:
        logger.warning(
            "Sparse content verifier failed; suppressing coarse run %d-%d: %s",
            coarse_run.start_id,
            coarse_run.end_id,
            exc,
        )
        return None


def _verify_pod_start(coarse_run: _CoarseAdRun, segments: list[TranscriptSegment], backend: LLMBackend) -> int:
    """Find one bounded left boundary for a strong sparse commercial seed."""
    window_min = max(0, coarse_run.start_id - 16)
    context_ids = list(range(window_min, coarse_run.start_id + 1))
    transcript_text = _render_segments_bounded(
        context_ids,
        segments,
        headers=[
            f"CANDIDATE_START_MIN_ID={window_min}",
            f"CONFIRMED_START_ID={coarse_run.start_id}",
            f"CONFIRMED_END_ID={coarse_run.end_id}",
            "BOUNDED_CONTEXT:",
        ],
    )
    try:
        response, _tokens = _generate_constrained_response(
            backend,
            _POD_START_VERIFY_SYSTEM_PROMPT,
            transcript_text,
            _id_response_format("start_id", context_ids),
        )
        return _parse_pod_start_response(response, window_min, coarse_run.start_id)
    except Exception as exc:
        logger.warning("Pod-start verifier failed; retaining coarse start %d: %s", coarse_run.start_id, exc)
        return coarse_run.start_id


def _verify_preroll_content_start(
    coarse_run: _CoarseAdRun, segments: list[TranscriptSegment], backend: LLMBackend
) -> int | None:
    """Return first program-content ID after an explicit transcript-start pre-roll."""
    if coarse_run.start_id != 0 or coarse_run.end_id + 1 >= len(segments):
        return None
    opening_text = " ".join(
        segments[segment_id].text for segment_id in range(coarse_run.start_id, coarse_run.end_id + 1)
    )
    if _SPONSOR_OPENING_RE.search(opening_text) is None:
        return None
    window_max = min(len(segments) - 1, coarse_run.end_id + 48)
    context_ids = list(range(coarse_run.start_id, window_max + 1))
    transcript_text = _render_segments_bounded(context_ids, segments)
    try:
        response, _tokens = _generate_constrained_response(
            backend,
            _PREROLL_CONTENT_VERIFY_SYSTEM_PROMPT,
            transcript_text,
            _id_response_format("content_start_id", list(range(coarse_run.end_id + 1, window_max + 1))),
        )
        return _parse_preroll_content_response(response, coarse_run.end_id + 1, window_max)
    except Exception as exc:
        logger.warning("Pre-roll verifier failed; retaining coarse end %d: %s", coarse_run.end_id, exc)
        return None


def _refine_ad_start_from_tokens(
    segment: TranscriptSegment, opening_pattern: re.Pattern[str] = _SPONSOR_OPENING_RE
) -> float:
    """Return a sponsor-opening token time when one safely narrows this segment.

    Sentence alignment can combine the end of interview speech with an ad opening.
    Token timing is optional and only trusted when it is monotonic, stays inside
    the parent segment, and contains an explicit sponsor-opening phrase.
    """
    if not math.isfinite(segment.start_s) or not math.isfinite(segment.end_s):
        return segment.start_s

    tokens = getattr(segment, "tokens", None)
    if not tokens:
        return segment.start_s

    pieces: list[str] = []
    spans: list[tuple[int, int, float]] = []
    previous_end = segment.start_s
    for token in tokens:
        try:
            text = str(token.text)
            start_s = float(token.start_s)
            end_s = float(token.end_s)
        except (AttributeError, TypeError, ValueError):
            return segment.start_s
        if (
            not text
            or not math.isfinite(start_s)
            or not math.isfinite(end_s)
            or start_s < previous_end
            or end_s < start_s
            or end_s > segment.end_s
        ):
            return segment.start_s
        start_char = sum(len(piece) for piece in pieces)
        pieces.append(text)
        spans.append((start_char, start_char + len(text), start_s))
        previous_end = end_s

    match = opening_pattern.search("".join(pieces))
    if match is None:
        return segment.start_s
    for start_char, end_char, start_s in spans:
        if start_char <= match.start() < end_char:
            return start_s
    return segment.start_s


def _last_meaningful_ad_end(
    content_start_id: int, minimum_ad_id: int, segments: list[TranscriptSegment]
) -> float:
    """Return the final spoken ad endpoint before content or punctuation gaps."""
    ad_end_id = content_start_id - 1
    while ad_end_id > minimum_ad_id:
        text = segments[ad_end_id].text.strip()
        if text and any(char.isalnum() for char in text):
            break
        ad_end_id -= 1
    return segments[ad_end_id].end_s


def _verify_ad_boundaries(
    coarse_run: _CoarseAdRun, segments: list[TranscriptSegment], backend: LLMBackend
) -> AdSegment | None:
    """Conservatively expand one coarse run through immediate-neighbor probes."""
    preroll_content_start = _verify_preroll_content_start(coarse_run, segments, backend)
    if preroll_content_start is not None:
        return AdSegment(
            _refine_ad_start_from_tokens(segments[coarse_run.start_id]),
            segments[preroll_content_start].start_s,
            coarse_run.confidence,
            coarse_run.label,
        )

    verified_start = coarse_run.start_id
    if coarse_run.start_id > 0 and _has_strong_sparse_seed(coarse_run, segments):
        verified_start = _verify_pod_start(coarse_run, segments, backend)
    for _ in range(2):
        candidate_id = verified_start - 1
        if candidate_id < 0:
            break
        if _probe_boundary_candidate(candidate_id, verified_start, "left", segments, backend) is not True:
            break
        verified_start = candidate_id

    verified_end = coarse_run.end_id
    coarse_size = coarse_run.end_id - coarse_run.start_id + 1
    if coarse_size <= 2 and verified_end + 1 < len(segments):
        content_start_id = _verify_sparse_content_start(coarse_run, verified_start, segments, backend)
        if content_start_id is None:
            return None
        verified_end = content_start_id - 1

    return AdSegment(
        _refine_ad_start_from_tokens(segments[verified_start]),
        _last_meaningful_ad_end(verified_end + 1, coarse_run.end_id, segments),
        coarse_run.confidence,
        coarse_run.label,
    )


def _merge_adjacent(segments: list[AdSegment], gap_threshold: float = 2.0) -> list[AdSegment]:
    """Merge adjacent or overlapping ad segments.

    Args:
        segments: Sorted list of ad segments.
        gap_threshold: Maximum gap in seconds between segments to merge.

    Returns:
        Merged list of AdSegment, sorted by start time.
    """
    if not segments:
        return []

    sorted_segs = sorted(segments, key=lambda s: s.start_s)
    merged: list[AdSegment] = [sorted_segs[0]]

    for seg in sorted_segs[1:]:
        prev = merged[-1]
        if seg.start_s <= prev.end_s + gap_threshold:
            # A pair has no unique dominant label when its labels differ, so preserve
            # the earlier run's label instead of depending on unordered set iteration.
            merged[-1] = AdSegment(
                start_s=prev.start_s,
                end_s=max(prev.end_s, seg.end_s),
                confidence=(prev.confidence + seg.confidence) / 2.0,
                label=prev.label,
            )
        else:
            merged.append(seg)

    return merged


# ---------------------------------------------------------------------------
# Audio ad cutting with ffmpeg
# ---------------------------------------------------------------------------


def _compute_keep_segments(
    total_duration: float,
    ad_segments: list[AdSegment],
    buffer_s: float,
) -> list[tuple[float, float]]:
    """Compute content segments to keep (inverse of ad segments).

    Args:
        total_duration: Total audio duration in seconds.
        ad_segments: Sorted list of ad segments to remove.
        buffer_s: Padding in seconds around cuts for smooth transitions.

    Returns:
        List of (start, end) tuples representing content to keep,
        clamped to [0, total_duration].
    """
    if not ad_segments:
        return [(0.0, total_duration)]

    sorted_ads = sorted(ad_segments, key=lambda s: s.start_s)
    keeps: list[tuple[float, float]] = []
    current_start = 0.0

    for ad in sorted_ads:
        ad_start = max(0.0, ad.start_s - buffer_s)
        ad_end = min(total_duration, ad.end_s + buffer_s)

        if current_start < ad_start:
            keeps.append((current_start, ad_start))
        current_start = max(current_start, ad_end)

    # Keep content after last ad
    if current_start < total_duration:
        keeps.append((current_start, total_duration))

    return keeps


def cut_ads(
    audio_path: Path,
    ad_segments: list[AdSegment],
    output_path: Path,
    buffer_seconds: float = 0.5,
) -> Path:
    """Cut detected ad segments from an audio file using ffmpeg.

    Args:
        audio_path: Path to the input audio file.
        ad_segments: List of ad segments to remove.
        output_path: Path for the output audio file.
        buffer_seconds: Padding around cuts for smooth transitions.

    Returns:
        The output_path.

    Raises:
        RuntimeError: If ffmpeg is not available.
        FileNotFoundError: If audio_path does not exist.
        EmptyCutResultError: If every keep-segment is empty (nothing to keep),
            which would otherwise produce a 0-byte file. See INV-4.
        subprocess.CalledProcessError: If ffmpeg fails.
    """
    check_ffmpeg()

    if not audio_path.exists():
        raise FileNotFoundError(f"Audio file not found: {audio_path}")

    # No ads to cut — copy the file directly
    if not ad_segments:
        shutil.copy2(audio_path, output_path)
        logger.info("No ads to cut, copied %s to %s", audio_path, output_path)
        return output_path

    # Get total duration via ffprobe
    probe_result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(audio_path),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    total_duration = float(probe_result.stdout.strip())

    keep_segments = _compute_keep_segments(total_duration, ad_segments, buffer_seconds)

    if not keep_segments:
        raise EmptyCutResultError(f"All content marked as ads for {audio_path}; nothing to keep")

    tmpdir = None
    try:
        tmpdir = tempfile.mkdtemp(prefix="wilted_adcut_")
        tmp = Path(tmpdir)
        segment_files: list[Path] = []

        # Extract each keep-segment
        for i, (start, end) in enumerate(keep_segments):
            duration = end - start
            if duration <= 0:
                continue
            seg_path = tmp / f"segment_{i:03d}.mp3"
            subprocess.run(
                [
                    "ffmpeg",
                    "-i",
                    str(audio_path),
                    "-ss",
                    str(start),
                    "-t",
                    str(duration),
                    "-c:a",
                    "copy",
                    "-avoid_negative_ts",
                    "make_zero",
                    str(seg_path),
                ],
                capture_output=True,
                check=True,
            )
            segment_files.append(seg_path)

        if not segment_files:
            raise EmptyCutResultError(f"No non-empty keep-segments for {audio_path}; nothing to keep")

        # If only one segment, just move it
        if len(segment_files) == 1:
            shutil.move(str(segment_files[0]), str(output_path))
            return output_path

        # Create concat demuxer file
        concat_path = tmp / "concat_list.txt"
        with open(concat_path, "w") as f:
            for seg_path in segment_files:
                f.write(f"file '{seg_path}'\n")

        # Concatenate
        subprocess.run(
            [
                "ffmpeg",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(concat_path),
                "-c:a",
                "copy",
                str(output_path),
            ],
            capture_output=True,
            check=True,
        )

        logger.info(
            "Cut %d ad segments, kept %d segments -> %s",
            len(ad_segments),
            len(keep_segments),
            output_path,
        )
        return output_path

    finally:
        # Clean up temp files
        if tmpdir is not None:
            shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# Article promotional content removal
# ---------------------------------------------------------------------------


def remove_promos(text: str, backend: LLMBackend) -> str:
    """Remove promotional paragraphs from article text.

    Args:
        text: Full article text with paragraph breaks.
        backend: A loaded LLM backend for inference.

    Returns:
        Cleaned text with promotional paragraphs removed.
    """
    if not text.strip():
        return ""

    paragraphs = [p for p in text.split("\n\n") if p.strip()]
    if not paragraphs:
        return ""

    # Build numbered paragraph list for LLM
    numbered = "\n\n".join(f"[{i}] {para}" for i, para in enumerate(paragraphs))

    try:
        response, _tokens = backend.generate(_PROMO_DETECT_SYSTEM_PROMPT, numbered)
        parsed = parse_json_response(response)
    except Exception:
        logger.exception("Promo detection failed, returning original text")
        return text

    if not isinstance(parsed, dict):
        logger.warning("Expected JSON object, got %s", type(parsed).__name__)
        return text

    promo_indices = parsed.get("promo_indices", [])
    if not isinstance(promo_indices, list):
        logger.warning("promo_indices is not a list: %s", type(promo_indices).__name__)
        return text

    # Validate indices
    valid_indices = set()
    for idx in promo_indices:
        try:
            idx_int = int(idx)
            if 0 <= idx_int < len(paragraphs):
                valid_indices.add(idx_int)
        except (TypeError, ValueError):
            logger.warning("Skipping invalid promo index: %s", idx)

    if not valid_indices:
        return text

    # Remove promotional paragraphs
    kept = [para for i, para in enumerate(paragraphs) if i not in valid_indices]
    result = "\n\n".join(kept)

    logger.info(
        "Removed %d promotional paragraphs out of %d",
        len(valid_indices),
        len(paragraphs),
    )
    return result


def remove_promos_batch(
    items: list[tuple[int, str]],
    backend: LLMBackend,
) -> dict[int, str]:
    """Remove promotional content from multiple articles.

    Args:
        items: List of (item_id, article_text) tuples.
        backend: A loaded LLM backend (already loaded, shared across calls).

    Returns:
        Dict mapping item_id to cleaned text.
    """
    results: dict[int, str] = {}

    for item_id, text in items:
        try:
            results[item_id] = remove_promos(text, backend)
        except Exception:
            logger.exception("Promo removal failed for item %d", item_id)
            results[item_id] = text  # Fall back to original text

    return results
