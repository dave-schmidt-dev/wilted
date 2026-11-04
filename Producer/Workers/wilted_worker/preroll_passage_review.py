"""Source-checked paid-ad review for a nominated episode opening."""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any

from . import reporting as _worker_reporting
from .commercial_preservation import _prompt_budget_values, recovered_confidence
from .constants import (
    PREROLL_RECOVERY_MAX_SECONDS,
    PREROLL_RECOVERY_MAX_SEGMENTS,
    PREROLL_RECOVERY_MINIMUM_SECONDS,
)
from .ad_audit import OpeningReviewReceipt, ValidatedQuoteEvidence
from .interval_geometry import intervals_overlap
from .prompts import PREROLL_PROGRAM_START_PROMPT, WHOLE_PASSAGE_PROMPT

MAX_REVIEW_CHARS = 12_000
RIGHT_COMPARISON_CUES = 14
MAX_QUOTE_WORDS = 12
MAX_QUOTE_CUES = 3
ROLES = ("paid_product_ad", "house_promo", "programme", "mixed", "unknown")

_WORD_RE = re.compile(r"[^\W_]+(?:['’][^\W_]+)*", re.UNICODE)
_HOUSE_LABELS = frozenset({"self_promo", "newsletter_pitch"})


@dataclass(frozen=True)
class SourceCheckedOpening:
    """Accepted opening extent and the exact lexical cuts it authorizes."""

    start_s: float
    end_s: float
    cuts: tuple[object, ...]
    receipt: OpeningReviewReceipt


def _response_schema(all_ids: list[int]) -> dict[str, Any]:
    """Build the strict, measured experiment response contract."""
    properties = {
        "classification": {"type": "string", "enum": list(ROLES)},
        "commercial_evidence_ids": {
            "type": "array", "items": {"type": "integer", "enum": all_ids},
        },
        "programme_evidence_ids": {
            "type": "array", "items": {"type": "integer", "enum": all_ids},
        },
        "commercial_quotes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "integer", "enum": all_ids},
                    "quote": {"type": "string"},
                },
                "required": ["id", "quote"],
                "additionalProperties": False,
            },
        },
    }
    return {
        "type": "json_object",
        "schema": {
            "type": "object", "properties": properties,
            "required": list(properties), "additionalProperties": False,
        },
    }


def _quote_covered_ids(anchor: int, quote: str, candidate_ids: tuple[int, ...], segments) -> tuple[int, ...] | None:
    """Match exact source text across up to 3 cues, starting in the cited cue."""
    if anchor not in candidate_ids:
        return None
    if not _WORD_RE.findall(quote) or len(_WORD_RE.findall(quote)) > MAX_QUOTE_WORDS:
        return None
    candidate_positions = {segment_id: position for position, segment_id in enumerate(candidate_ids)}
    position = candidate_positions[anchor]
    cue_ids = candidate_ids[position:position + MAX_QUOTE_CUES]
    texts = [str(getattr(segments[index], "text", "") or "") for index in cue_ids]
    source = " ".join(texts)
    anchor_end = len(texts[0])
    match_start = source.find(quote)
    while match_start >= 0:
        match_end = match_start + len(quote)
        if match_start < anchor_end:
            owners = []
            cue_start = 0
            for index, text in zip(cue_ids, texts):
                cue_end = cue_start + len(text)
                if cue_end > match_start and cue_start < match_end:
                    owners.append(index)
                cue_start = cue_end + 1
            if owners and owners[0] == anchor and len(owners) <= MAX_QUOTE_CUES:
                return tuple(owners)
        match_start = source.find(quote, match_start + 1)
    return None


def _validate_response(raw: str, candidate_ids: tuple[int, ...], all_ids: list[int], segments) -> dict[str, Any]:
    """Validate shape, source IDs, and quote provenance without fuzzy matching."""
    parsed = json.loads(raw)
    fields = {
        "classification", "commercial_evidence_ids", "programme_evidence_ids",
        "commercial_quotes",
    }
    if not isinstance(parsed, dict) or set(parsed) != fields:
        raise ValueError("whole-passage response has an invalid shape")
    if parsed["classification"] not in ROLES or not isinstance(parsed["classification"], str):
        raise ValueError("whole-passage classification is invalid")
    allowed_ids = set(all_ids)
    for name in ("commercial_evidence_ids", "programme_evidence_ids"):
        values = parsed[name]
        if (not isinstance(values, list)
                or any(type(value) is not int or value not in allowed_ids for value in values)
                or len(values) != len(set(values))):
            raise ValueError(f"{name} contains invalid or duplicate IDs")
    if not isinstance(parsed["commercial_quotes"], list):
        raise ValueError("commercial_quotes is not an array")

    quote_anchors: set[int] = set()
    quote_metadata = []
    for item in parsed["commercial_quotes"]:
        if (not isinstance(item, dict) or set(item) != {"id", "quote"}
                or type(item["id"]) is not int or item["id"] not in allowed_ids
                or item["id"] in quote_anchors):
            raise ValueError("commercial quote has an invalid or duplicate ID")
        quote, anchor = item["quote"], item["id"]
        if not isinstance(quote, str) or not quote.strip() or len(_WORD_RE.findall(quote)) > MAX_QUOTE_WORDS:
            raise ValueError("commercial quote is empty or exceeds 12 words")
        covered_ids = _quote_covered_ids(anchor, quote, candidate_ids, segments)
        if covered_ids is None:
            raise ValueError("commercial quote does not match exact candidate source words")
        quote_anchors.add(anchor)
        quote_metadata.append({
            "id": anchor, "coveredIDs": list(covered_ids),
            "wordCount": len(_WORD_RE.findall(quote)),
            "sha256": hashlib.sha256(quote.encode("utf-8")).hexdigest(),
        })

    commercial_ids = parsed["commercial_evidence_ids"]
    if not set(commercial_ids).issubset(quote_anchors):
        raise ValueError("commercial evidence ID has no validated exact quote")
    candidate_set = set(candidate_ids)
    candidate_commercial = sorted(candidate_set.intersection(commercial_ids))
    candidate_programme = sorted(candidate_set.intersection(parsed["programme_evidence_ids"]))
    eligible = (
        parsed["classification"] == "paid_product_ad"
        and bool(candidate_commercial)
        and not candidate_programme
    )
    return {
        "classification": parsed["classification"],
        "commercialEvidenceIDs": sorted(commercial_ids),
        "programmeEvidenceIDs": sorted(parsed["programme_evidence_ids"]),
        "candidateCommercialEvidenceIDs": candidate_commercial,
        "candidateProgrammeEvidenceIDs": candidate_programme,
        "validatedQuoteMetadata": quote_metadata,
        "eligiblePaidCandidate": eligible,
    }


def _measured_generate(backend, system_prompt: str, user_content: str, response_format: dict):
    """Measure and send exactly one bounded inference request."""
    measure = getattr(backend, "measure_prompt", None)
    if not callable(measure):
        raise ValueError("opening review requires a measured prompt budget")
    prepared = measure(system_prompt, user_content, response_format=response_format)
    tokens, context, reserve = _prompt_budget_values(prepared)
    if tokens + reserve > context:
        raise ValueError("opening review exceeds the measured model context")
    return backend.generate(
        system_prompt, user_content, response_format=response_format,
        prepared_prompt=prepared,
    )


def _known_house_ids(backend, detections, ads_module, segments) -> set[int]:
    """Collect observed house classifications from the primary source pass."""
    house_ids: set[int] = set()
    for lineage in getattr(backend, "lineages", ()):
        for segment_id, states in lineage.classifications.items():
            if any(state in {f"ad:{label}" for label in _HOUSE_LABELS} for state in states):
                house_ids.add(segment_id)
    house_kind = getattr(ads_module, "AD_KIND_HOUSE", None)
    for ad in detections:
        if (getattr(ad, "label", None) in _HOUSE_LABELS
                or house_kind in ads_module.ad_segment_kinds(ad)):
            house_ids.update(
                index for index, segment in enumerate(segments)
                if intervals_overlap(
                    float(ad.start_s), float(ad.end_s),
                    float(segment.start_s), float(segment.end_s),
                )
            )
    return house_ids


def _record_programme_evidence(raw, all_ids, candidate_start, candidate_end, segments,
                               held_spans, total_seconds):
    """Record any independently parseable positive programme answer as a hold."""
    if not isinstance(held_spans, list):
        return
    try:
        parsed = json.loads(raw)
    except (TypeError, json.JSONDecodeError):
        return
    if not isinstance(parsed, dict):
        return
    from .boundary_review import record_programme_boundary
    if parsed.get("classification") == "programme":
        from types import SimpleNamespace
        record_programme_boundary(
            held_spans, SimpleNamespace(start_s=candidate_start, end_s=candidate_end), total_seconds,
        )
    values = parsed.get("programme_evidence_ids")
    if isinstance(values, list):
        allowed = set(all_ids)
        for segment_id in dict.fromkeys(
            value for value in values if type(value) is int and value in allowed
        ):
            record_programme_boundary(held_spans, segments[segment_id], total_seconds)


def _record_opening_hold(held_spans, start_s: float, end_s: float, reason: str,
                         total_seconds: float) -> None:
    """Use the shared hold owner for a fail-closed whole-opening decision."""
    if not isinstance(held_spans, list):
        return
    from .boundary_review import record_held_span
    record_held_span(held_spans, start_s, end_s, reason, total_seconds)


def _without_opening(ads_module, detections, start_s: float, end_s: float):
    """Remove only the reviewed opening extent, retaining out-of-range tails."""
    result = []
    for ad in detections:
        ad_start, ad_end = float(ad.start_s), float(ad.end_s)
        if not intervals_overlap(ad_start, ad_end, start_s, end_s):
            result.append(ad)
            continue
        kinds = tuple(ads_module.ad_segment_kinds(ad))
        if ad_start < start_s:
            result.append(ads_module.AdSegment(
                ad_start, min(ad_end, start_s), float(ad.confidence), ad.label, kinds=kinds,
            ))
        if end_s < ad_end:
            result.append(ads_module.AdSegment(
                max(ad_start, end_s), ad_end, float(ad.confidence), ad.label, kinds=kinds,
            ))
    return sorted(result, key=lambda ad: float(ad.start_s))


def apply_source_checked_opening_constraints(ads_module, detections, openings):
    """Keep later proposals inside accepted opening cuts, preserving tails.

    Profiles may nominate a broad cut that overlaps an already reviewed
    opening. Inside that extent, their coverage is intersected with the exact
    lexical intervals accepted by the whole-passage review. Pieces after the
    reviewed extent keep their original metadata.
    """
    result = list(detections)
    for opening in openings:
        proposals = list(result)
        retained = []
        for ad in proposals:
            ad_start, ad_end = float(ad.start_s), float(ad.end_s)
            if ad_end <= opening.start_s or ad_start >= opening.end_s:
                retained.append(ad)
                continue
            kinds = tuple(ads_module.ad_segment_kinds(ad))
            if ad_start < opening.start_s:
                retained.append(ads_module.AdSegment(
                    ad_start, opening.start_s, float(ad.confidence), ad.label, kinds=kinds,
                ))
            if ad_end > opening.end_s:
                retained.append(ads_module.AdSegment(
                    opening.end_s, ad_end, float(ad.confidence), ad.label, kinds=kinds,
                ))

        allowed_cuts = []
        for source_cut in opening.cuts:
            cut_start, cut_end = float(source_cut.start_s), float(source_cut.end_s)
            covered = sorted(
                (max(cut_start, float(ad.start_s)), min(cut_end, float(ad.end_s)))
                for ad in proposals
                if intervals_overlap(
                    cut_start, cut_end, float(ad.start_s), float(ad.end_s),
                )
            )
            merged_coverage = []
            for start_s, end_s in covered:
                if merged_coverage and start_s <= merged_coverage[-1][1]:
                    merged_coverage[-1] = (
                        merged_coverage[-1][0], max(merged_coverage[-1][1], end_s),
                    )
                else:
                    merged_coverage.append((start_s, end_s))
            kinds = tuple(ads_module.ad_segment_kinds(source_cut))
            allowed_cuts.extend(
                source_cut if start_s == cut_start and end_s == cut_end
                else ads_module.AdSegment(
                    start_s, end_s, float(source_cut.confidence), source_cut.label, kinds=kinds,
                )
                for start_s, end_s in merged_coverage
                if start_s < end_s
            )
        result = sorted([*retained, *allowed_cuts], key=lambda ad: float(ad.start_s))
    return result


def recover_source_checked_preroll(
    ads_module: Any,
    backend: Any,
    segments,
    detections,
    total_seconds: float,
    remove_self_promotion: bool = False,
    held_spans=(),
    source_checked_openings: list[SourceCheckedOpening] | None = None,
):
    """Review a full nominated opening and cut only source cue intervals."""
    if not segments:
        return list(detections)
    window_ids = [0]
    for segment_id in range(1, len(segments)):
        if (len(window_ids) >= PREROLL_RECOVERY_MAX_SEGMENTS
                or float(segments[segment_id].start_s) > PREROLL_RECOVERY_MAX_SECONDS):
            break
        window_ids.append(segment_id)
    if len(window_ids) < 2:
        return list(detections)

    try:
        q1_text = "\n".join(
            ads_module._segment_prefix(index, segments[index])
            + str(getattr(segments[index], "text", "") or "")
            for index in window_ids
        )
        if len(q1_text) > MAX_REVIEW_CHARS:
            raise ValueError("opening nomination is over the complete-text bound")
        q1_format = ads_module._id_response_format("program_start_id", window_ids)
        q1_response, _tokens = _measured_generate(
            backend, PREROLL_PROGRAM_START_PROMPT, q1_text, q1_format,
        )
        q1 = json.loads(q1_response)
        if (not isinstance(q1, dict) or set(q1) != {"program_start_id"}
                or type(q1["program_start_id"]) is not int
                or q1["program_start_id"] not in window_ids):
            raise ValueError("opening nomination returned an invalid boundary ID")
    except Exception as error:  # noqa: BLE001 - an unanswered review never adds a cut
        _worker_reporting.progress("ads.detect.preroll.skipped", f"opening nomination failed: {type(error).__name__}")
        return list(detections)

    boundary_id = q1["program_start_id"]
    if boundary_id == 0:
        return list(detections)
    candidate_ids = tuple(range(boundary_id))
    candidate_start = float(segments[candidate_ids[0]].start_s)
    candidate_end = float(segments[boundary_id].start_s)
    if candidate_end < PREROLL_RECOVERY_MINIMUM_SECONDS:
        _worker_reporting.progress(
            "ads.detect.preroll.skipped", f"opening is only {candidate_end:.1f}s long",
        )
        return list(detections)
    if not candidate_start < candidate_end:
        return list(detections)
    comparison_ids = tuple(range(boundary_id, min(len(segments), boundary_id + RIGHT_COMPARISON_CUES)))
    if not comparison_ids:
        _worker_reporting.progress("ads.detect.preroll.skipped", "opening has no right comparison context")
        _record_opening_hold(held_spans, candidate_start, candidate_end,
                             "boundary-review-unresolved", total_seconds)
        return list(detections)
    all_ids = [*candidate_ids, *comparison_ids]
    prompt = (
        "Candidate IDs: " + ",".join(map(str, candidate_ids))
        + "\nComparison-only IDs: " + ",".join(map(str, comparison_ids))
        + "\nTranscript cues:\n"
        + "\n".join(
            f"[ID {index}] {str(getattr(segments[index], 'text', '') or '')}"
            for index in all_ids
        )
    )
    if len(prompt) > MAX_REVIEW_CHARS:
        _worker_reporting.progress("ads.detect.preroll.skipped", "complete opening review exceeds its text bound")
        _record_opening_hold(held_spans, candidate_start, candidate_end,
                             "boundary-review-unresolved", total_seconds)
        return list(detections)
    candidate_has_hold = any(
        intervals_overlap(candidate_start, candidate_end, float(span.start_s), float(span.end_s))
        for span in held_spans
    )
    known_house = _known_house_ids(backend, detections, ads_module, segments)
    disabled_house = (not remove_self_promotion and bool(known_house.intersection(candidate_ids)))
    if disabled_house:
        _record_opening_hold(held_spans, candidate_start, candidate_end,
                             "house-promotion-disabled", total_seconds)
    if candidate_has_hold or disabled_house:
        _worker_reporting.progress("ads.detect.preroll.skipped", "opening overlaps a held or disabled-house cue")
        return list(detections)

    response = None
    try:
        response_format = _response_schema(all_ids)
        response, _tokens = _measured_generate(
            backend, WHOLE_PASSAGE_PROMPT, prompt, response_format,
        )
        judgment = _validate_response(response, candidate_ids, all_ids, segments)
    except Exception as error:  # noqa: BLE001 - malformed or failed review keeps the source
        _record_programme_evidence(
            response, all_ids, candidate_start, candidate_end, segments,
            held_spans, total_seconds,
        )
        _record_opening_hold(held_spans, candidate_start, candidate_end,
                             "boundary-review-unresolved", total_seconds)
        _worker_reporting.progress("ads.detect.preroll.skipped", f"whole-opening review failed: {type(error).__name__}")
        return list(detections)

    _record_programme_evidence(
        response, all_ids, candidate_start, candidate_end, segments,
        held_spans, total_seconds,
    )
    if judgment["classification"] == "house_promo" and not remove_self_promotion:
        _record_opening_hold(held_spans, candidate_start, candidate_end,
                             "house-promotion-disabled", total_seconds)
        _worker_reporting.progress("ads.detect.preroll.skipped", "whole opening is disabled house promotion")
        return list(detections)
    if not judgment["eligiblePaidCandidate"]:
        if judgment["classification"] in {"mixed", "unknown"} or (
            judgment["classification"] == "paid_product_ad"
            and not judgment["candidateCommercialEvidenceIDs"]
        ):
            _record_opening_hold(held_spans, candidate_start, candidate_end,
                                 "boundary-review-unresolved", total_seconds)
        _worker_reporting.progress("ads.detect.preroll.skipped", "whole opening was not a clean paid-product passage")
        return list(detections)
    if judgment["candidateProgrammeEvidenceIDs"]:
        return list(detections)

    lexical_ids = [
        segment_id for segment_id in candidate_ids
        if _WORD_RE.search(str(getattr(segments[segment_id], "text", "") or ""))
    ]
    if not lexical_ids:
        return list(detections)
    cuts = []
    for segment_id in lexical_ids:
        segment = segments[segment_id]
        start_s, end_s = float(segment.start_s), float(segment.end_s)
        if (start_s < candidate_start or end_s > candidate_end or not start_s < end_s
                or not (start_s >= 0 and end_s < float("inf"))):
            _worker_reporting.progress("ads.detect.preroll.skipped", "opening cue timing is malformed")
            return list(detections)
        cuts.append(ads_module.AdSegment(
            start_s, end_s, recovered_confidence(2, 2), "ad_break",
            kinds=(ads_module.AD_KIND_PAID,),
        ))

    validated_quotes = tuple(sorted(
        (
            ValidatedQuoteEvidence(
                int(item["id"]), tuple(int(value) for value in item["coveredIDs"]),
                int(item["wordCount"]), str(item["sha256"]),
            )
            for item in judgment["validatedQuoteMetadata"]
        ),
        key=lambda item: item.id,
    ))
    canonical_quotes = [
        {
            "id": item.id,
            "coveredIDs": list(item.covered_ids),
            "wordCount": item.word_count,
            "sha256": item.sha256,
        }
        for item in validated_quotes
    ]
    quote_evidence_digest = hashlib.sha256(json.dumps(
        canonical_quotes, sort_keys=True, separators=(",", ":"),
    ).encode("utf-8")).hexdigest()
    receipt = OpeningReviewReceipt(
        schema_version=1,
        status="accepted",
        candidate_end_s=candidate_end,
        candidate_cue_count=len(candidate_ids),
        quote_count=len(validated_quotes),
        covered_cue_ids=tuple(sorted({
            value for item in validated_quotes for value in item.covered_ids
        })),
        quote_evidence_digest=quote_evidence_digest,
        validated_quotes=validated_quotes,
    )

    # The opening review replaces coarse existing spans inside its candidate.
    # Their portions outside the reviewed extent remain intact.
    # Accepted opening ownership starts at the file boundary even when the
    # first ASR cue starts later. Otherwise an older broad cut could leave an
    # unobserved leading sliver removed beside the source-checked cue cuts.
    retained = _without_opening(ads_module, detections, 0.0, candidate_end)
    result = sorted([*retained, *cuts], key=lambda ad: float(ad.start_s))
    if isinstance(source_checked_openings, list):
        source_checked_openings.append(SourceCheckedOpening(
            0.0, candidate_end, tuple(cuts), receipt,
        ))
    _worker_reporting.progress(
        "ads.detect.preroll.accepted",
        f"paid opening accepted across {len(lexical_ids)} source cues; positive gaps preserved",
    )
    return result
