"""Source-checked paid-ad review for a nominated episode opening."""
from __future__ import annotations

import json
import hashlib
import math
from dataclasses import dataclass
from typing import Any

from . import reporting as _worker_reporting
from .commercial_preservation import _prompt_budget_values, recovered_confidence
from .constants import (
    PREROLL_RECOVERY_MAX_SECONDS,
    PREROLL_RECOVERY_MAX_SEGMENTS,
    PREROLL_RECOVERY_MINIMUM_SECONDS,
)
from .ad_audit import OpeningReviewReceipt
from .interval_geometry import intervals_overlap
from .prompts import PREROLL_PROGRAM_START_PROMPT, WHOLE_PASSAGE_PROMPT
from .review_diagnostics import opening_failure_reason
from .opening_review_response import (
    _WORD_RE, response_schema as _response_schema, validate_response as _validate_response,
    build_quote_repair_request, quote_repair_allowed, validated_quote_evidence,
    repair_quotes_match_literals,
)

MAX_REVIEW_CHARS = 12_000
RIGHT_COMPARISON_CUES = 14
_HOUSE_LABELS = frozenset({"self_promo", "newsletter_pitch"})


@dataclass(frozen=True)
class SourceCheckedOpening:
    """Accepted opening extent and the exact lexical cuts it authorizes."""

    start_s: float
    end_s: float
    cuts: tuple[object, ...]
    receipt: OpeningReviewReceipt


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


def _generate_preroll_nomination(backend, ads_module, segments, cue_ids, attempted_ids=None):
    """Fit Q1 to a complete-cue prefix, then infer once from that measurement."""
    fitted_ids = list(cue_ids)
    if isinstance(attempted_ids, list):
        attempted_ids[:] = fitted_ids
    measure = getattr(backend, "measure_prompt", None)
    if not callable(measure):
        raise ValueError("opening review requires a measured prompt budget")

    def render(ids):
        return "\n".join(
            ads_module._segment_prefix(index, segments[index])
            + str(getattr(segments[index], "text", "") or "")
            for index in ids
        )

    q1_text = render(fitted_ids)
    while len(q1_text) > MAX_REVIEW_CHARS and len(fitted_ids) > 2:
        fitted_ids.pop()
        q1_text = render(fitted_ids)
    if isinstance(attempted_ids, list):
        attempted_ids[:] = fitted_ids
    if len(q1_text) > MAX_REVIEW_CHARS:
        raise ValueError("opening nomination cannot fit two complete cues within its text bound")

    while True:
        if isinstance(attempted_ids, list):
            attempted_ids[:] = fitted_ids
        response_format = ads_module._id_response_format("program_start_id", fitted_ids)
        try:
            prepared = measure(
                PREROLL_PROGRAM_START_PROMPT, q1_text, response_format=response_format,
            )
        except ValueError as error:
            try:
                token_count, context_size, output_reserve = _prompt_budget_values(error)
            except ValueError:
                # Missing or invalid measurements are not evidence that trimming helps.
                raise error
            if token_count + output_reserve <= context_size:
                raise error
            capacity_error = error
        else:
            token_count, context_size, output_reserve = _prompt_budget_values(prepared)
            if token_count + output_reserve <= context_size:
                return (
                    fitted_ids,
                    backend.generate(
                        PREROLL_PROGRAM_START_PROMPT,
                        q1_text,
                        response_format=response_format,
                        prepared_prompt=prepared,
                    ),
                )
            capacity_error = ValueError("opening nomination exceeds the measured model context")

        if len(fitted_ids) <= 2:
            raise capacity_error
        fitted_ids.pop()
        q1_text = render(fitted_ids)


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


def _record_unresolved_opening_prefix(segments, cue_ids, held_spans, total_seconds) -> None:
    """Hold every possible candidate prefix when Q1 cannot provide a boundary."""
    if not isinstance(held_spans, list) or not cue_ids:
        return
    duration = float(total_seconds)
    if not math.isfinite(duration) or duration <= 0:
        return
    try:
        end_s = float(segments[cue_ids[-1]].start_s)
    except (IndexError, TypeError, ValueError, AttributeError):
        end_s = duration
    if not math.isfinite(end_s):
        end_s = duration
    end_s = min(duration, max(0.0, end_s))
    if end_s > 0:
        _record_opening_hold(
            held_spans, 0.0, end_s, "boundary-review-unresolved", duration,
        )


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

    attempted_q1_ids = list(window_ids)
    try:
        q1_ids, (q1_response, _tokens) = _generate_preroll_nomination(
            backend, ads_module, segments, window_ids, attempted_q1_ids,
        )
        q1 = json.loads(q1_response)
        if (not isinstance(q1, dict) or set(q1) != {"program_start_id"}
                or type(q1["program_start_id"]) is not int
                or q1["program_start_id"] not in q1_ids):
            raise ValueError("opening nomination returned an invalid boundary ID")
    except Exception as error:  # noqa: BLE001 - an unanswered review never adds a cut
        _record_unresolved_opening_prefix(
            segments, attempted_q1_ids or window_ids, held_spans, total_seconds,
        )
        _worker_reporting.progress("ads.detect.preroll.skipped", f"opening nomination failed: reason={opening_failure_reason(error)}")
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
        for segment_id in sorted(known_house.intersection(candidate_ids)):
            segment = segments[segment_id]
            _record_opening_hold(
                held_spans, float(segment.start_s), float(segment.end_s),
                "house-promotion-disabled", total_seconds,
            )
    if candidate_has_hold or disabled_house:
        _worker_reporting.progress("ads.detect.preroll.skipped", "opening overlaps a held or disabled-house cue")
        return list(detections)

    response = None
    quote_origin = "initial"

    def fail_opening_review(raw, error):
        _record_programme_evidence(
            raw, all_ids, candidate_start, candidate_end, segments,
            held_spans, total_seconds,
        )
        _record_opening_hold(
            held_spans, candidate_start, candidate_end,
            "boundary-review-unresolved", total_seconds,
        )
        _worker_reporting.progress(
            "ads.detect.preroll.skipped",
            f"whole-opening review failed: reason={opening_failure_reason(error)}",
        )
        return list(detections)

    try:
        response_format = _response_schema(all_ids)
        response, _tokens = _measured_generate(
            backend, WHOLE_PASSAGE_PROMPT, prompt, response_format,
        )
        judgment = _validate_response(response, candidate_ids, all_ids, segments)
    except Exception as error:  # noqa: BLE001 - malformed or failed review keeps the source
        if (
            response is not None
            and isinstance(error, ValueError)
            and str(error) in {
                "commercial quote is empty or exceeds 12 words",
                "commercial quote does not match exact candidate source words",
            }
            and quote_repair_allowed(response, candidate_ids, all_ids)
        ):
            try:
                repair_request = build_quote_repair_request(
                    prompt, response, candidate_ids, all_ids, segments,
                )
                if repair_request is None:
                    raise ValueError("opening quote repair has no safe exact literals")
                repair_prompt, repair_response_format, repair_quote_options = repair_request
                if len(repair_prompt) > MAX_REVIEW_CHARS:
                    raise ValueError("opening quote repair exceeds its text bound")
                repaired_response, _tokens = _measured_generate(
                    backend, WHOLE_PASSAGE_PROMPT,
                    repair_prompt,
                    repair_response_format,
                )
                repaired_judgment = _validate_response(
                    repaired_response, candidate_ids, all_ids, segments,
                )
                original = json.loads(response)
                repaired = json.loads(repaired_response)
                if (
                    repaired.get("classification") != original.get("classification")
                    or repaired.get("commercial_evidence_ids") != original.get("commercial_evidence_ids")
                    or repaired.get("programme_evidence_ids") != original.get("programme_evidence_ids")
                ):
                    raise ValueError("opening quote repair changed decision")
                if not repair_quotes_match_literals(
                    repaired_response, tuple(original["commercial_evidence_ids"]),
                    repair_quote_options,
                ):
                    raise ValueError("opening quote repair used an unoffered literal")
                response, judgment = repaired_response, repaired_judgment
                quote_origin = "literal-repair"
            except Exception as repair_error:  # noqa: BLE001 - repair remains fail-closed
                return fail_opening_review(response, repair_error)
        else:
            return fail_opening_review(response, error)

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

    validated_quotes = validated_quote_evidence(judgment["validatedQuoteMetadata"])
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
        quote_origin=quote_origin,
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
