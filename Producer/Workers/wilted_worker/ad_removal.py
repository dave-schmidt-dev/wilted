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
from . import commercial_recovery as _worker_commercial_recovery
from . import commercial_seeds as _worker_commercial_seeds
from . import cue_timing as _worker_cue_timing
from . import edge_recovery as _worker_edge_recovery
from . import gpu_admission as _worker_gpu_admission
from . import reporting as _worker_reporting
from . import silence_trim as _worker_silence_trim
from . import span_bounds as _worker_span_bounds
from . import tail_recovery as _worker_tail_recovery
from .ad_audit import AdAnalysis, AdAnalysisAudit, AuditingBackend, DeclinedCommercialEvidenceSeed, uncertain_ad_analysis, expected_backend_unavailable
from .ad_runtime_adaptations import install_context_aware_overlap_resolution, install_legacy_sponsor_opening_compatibility, install_produced_disclaimer_evidence, install_proportional_render_budget
from .constants import COMMERCIAL_RECOVERY_MAX_ADDITIONAL_CALLS
from .cue_timing import _near_empty_nominations, build_effective_cut_map, effective_removed_intervals, render_keep_segments, serialize_ad_audit
from .boundary_review import reject_programme_conflicts
from .interval_geometry import interval_contains, intervals_overlap
from .nomination import _CallBudgetBackend, _experimental_speculative_cuts
from .reporting import DiscardedRuns, WorkerError
from .span_bounds import enforce_total_ad_share_ceiling, recover_adjacent_ad_pod_continuations, reject_implausible_ad_spans
from .sponsor_evidence import explicit_sponsor_anchor_ids, explicit_sponsor_opening_pattern, sponsor_anchor_is_covered
from .tail_recovery import trim_straddling_span_tails

def analyze_ad_detections(
    ads_module,
    backend,
    segments,
    total_seconds: float,
    *,
    experimental_candidates=(),
    experimental_max_additional_model_calls: int = 0,
    remove_self_promotion: bool = False,
) -> AdAnalysis:
    """Run the archive detector and every worker safeguard with an auditable result.

    The caller owns model construction, GPU admission, and closing. This makes
    the exact live path replayable with a supplied backend and duration, while
    retaining the archive as the sole classifier and recovery implementation.
    """
    auditing_backend = backend if isinstance(backend, AuditingBackend) else AuditingBackend(
        backend, ads_module, len(segments)
    )
    auditing_backend.bind_segment_count(len(segments))
    install_legacy_sponsor_opening_compatibility(ads_module)
    install_produced_disclaimer_evidence(ads_module)
    install_proportional_render_budget(ads_module)
    install_context_aware_overlap_resolution(ads_module)
    discarded = DiscardedRuns(segments)
    ads_logger = logging.getLogger("wilted.ads")
    previous_level = ads_logger.level
    ads_logger.addHandler(discarded)
    ads_logger.setLevel(logging.INFO)
    try:
        if remove_self_promotion:
            detections = ads_module.detect_ads(segments, auditing_backend, remove_self_promotion=True)
        else:
            detections = ads_module.detect_ads(segments, auditing_backend)
    finally:
        ads_logger.removeHandler(discarded)
        ads_logger.setLevel(previous_level)
        discarded.summarize()

    if auditing_backend.unexpected_error is not None:
        raise auditing_backend.unexpected_error
    if auditing_backend.context_capacity_error is not None:
        raise WorkerError("ads-context-capacity-unavailable", str(auditing_backend.context_capacity_error))
    preliminary_audit = auditing_backend.audit(detections, segments)
    if auditing_backend.contract_errors:
        raise WorkerError("ads-audit-contract-unavailable", auditing_backend.contract_errors[0])
    if auditing_backend.mostly_failed:
        raise WorkerError(
            "ads-backend-failed",
            f"the model failed {auditing_backend.failures} of {auditing_backend.calls} requests; last error: "
            f"{type(auditing_backend.last_error).__name__}: {auditing_backend.last_error}",
        )
    if preliminary_audit.unresolved_ids:
        details = ", ".join(str(segment_id) for segment_id in preliminary_audit.unresolved_ids)
        raise WorkerError(
            "ads-classification-unresolved",
            f"classifier exhausted normal and corrective retries for global IDs: {details}",
        )
    covered_ids = {
        segment_id
        for lineage in auditing_backend.lineages
        for segment_id in lineage.classifications
    }
    missing_ids = sorted(set(range(len(segments))) - covered_ids)
    if missing_ids:
        details = ", ".join(str(segment_id) for segment_id in missing_ids)
        raise WorkerError(
            "ads-classification-incomplete",
            f"classifier produced no successfully validated coverage for global IDs: {details}",
        )

    commercial_recovery_backend = _CallBudgetBackend(
        auditing_backend, COMMERCIAL_RECOVERY_MAX_ADDITIONAL_CALLS
    )
    opening_pattern = explicit_sponsor_opening_pattern(ads_module)
    explicit_anchor_ids = explicit_sponsor_anchor_ids(segments, opening_pattern)
    detections = _worker_commercial_recovery.recover_unclaimed_explicit_sponsor_reads(
        ads_module,
        auditing_backend,
        segments,
        detections,
    )
    prefix_rebase_anchor_ids = frozenset(explicit_anchor_ids)
    detections = _worker_commercial_seeds.recover_commercial_evidence_reads(
        ads_module, commercial_recovery_backend, segments, detections, total_seconds
    )
    detections = _worker_commercial_seeds.recover_sparse_commercial_reads(
        ads_module, commercial_recovery_backend, segments, detections,
        total_seconds, preliminary_audit,
    )
    detections = _worker_edge_recovery.recover_transcript_start_preroll(
        ads_module, auditing_backend, segments, detections
    )
    held_spans = []
    detections = _worker_tail_recovery.recover_transcript_end_postroll(
        ads_module, auditing_backend, segments, detections, total_seconds,
    )
    detections = trim_straddling_span_tails(
        ads_module,
        auditing_backend,
        segments,
        detections,
        explicit_sponsor_opening_pattern(ads_module),
        held_spans=held_spans,
    )
    detections = _worker_tail_recovery.trim_credit_span_heads(
        ads_module, auditing_backend, segments, detections, held_spans
    )
    detections, confirmed_spans = _worker_span_bounds.resize_oversized_ad_spans(
        ads_module, auditing_backend, segments, detections, total_seconds,
        rebase_anchor_ids=prefix_rebase_anchor_ids, held_spans=held_spans,
    )
    proposed_detections = detections
    detections = reject_implausible_ad_spans(
        detections, total_seconds, confirmed_spans, held_spans
    )
    detections = recover_adjacent_ad_pod_continuations(
        ads_module, auditing_backend, segments, detections, total_seconds, held_spans
    )
    detections = enforce_total_ad_share_ceiling(detections, total_seconds, held_spans)
    detections = reject_programme_conflicts(detections, held_spans)
    dropped_anchor_ids = [
        anchor_id
        for anchor_id in explicit_anchor_ids
        if sponsor_anchor_is_covered(anchor_id, segments, proposed_detections)
        and not sponsor_anchor_is_covered(anchor_id, segments, detections)
        and not any(
            held.reason in {"sponsor-prefix-programme-found", "programme-boundary",
                            "total-share-ceiling", "programme-boundary-conflict"}
            and intervals_overlap(
                held.start_s, held.end_s,
                float(segments[anchor_id].start_s), float(segments[anchor_id].end_s),
            )
            for held in held_spans
        )
    ]
    if dropped_anchor_ids:
        details = ", ".join(
            f"raw anchor ID {anchor_id} at {float(segments[anchor_id].start_s):.3f}s"
            for anchor_id in dropped_anchor_ids
        )
        _worker_reporting.progress("ads.detect.recovery.audit.failed", details)
        raise WorkerError(
            "ads-recovery-audit-failed",
            "explicit sponsor anchors were dropped after review twice declined to vouch for the "
            f"span covering them: {details}",
        )
    audit = auditing_backend.audit(detections, segments)
    audit.held_spans = tuple(held_spans)
    audit.declined_commercial_evidence_seeds = tuple(
        DeclinedCommercialEvidenceSeed(
            ids=seed_ids,
            start_s=float(segments[seed_ids[0]].start_s),
            end_s=float(segments[seed_ids[-1]].end_s),
            reason=(
                "dropped-after-proposal"
                if any(
                    intervals_overlap(
                        float(ad.start_s), float(ad.end_s),
                        float(segments[seed_ids[0]].start_s), float(segments[seed_ids[-1]].end_s),
                    )
                    for ad in proposed_detections
                )
                else ("review-declined" if all(
                    auditing_backend.commercial_review_states.get(segment_id) == "programme"
                    for segment_id in seed_ids
                ) else "review-unresolved")
            ),
        )
        for seed_ids in _worker_commercial_seeds.commercial_evidence_seed_ids(segments, detections)
    )
    if auditing_backend.unexpected_error is not None:
        raise auditing_backend.unexpected_error
    if auditing_backend.context_capacity_error is not None:
        raise WorkerError("ads-context-capacity-unavailable", str(auditing_backend.context_capacity_error))
    if auditing_backend.contract_errors:
        raise WorkerError("ads-audit-contract-unavailable", auditing_backend.contract_errors[0])
    if auditing_backend.mostly_failed:
        raise WorkerError(
            "ads-backend-failed",
            f"the model failed {auditing_backend.failures} of {auditing_backend.calls} requests; last error: "
            f"{type(auditing_backend.last_error).__name__}: {auditing_backend.last_error}",
        )
    audit.near_empty = _near_empty_nominations(detections, total_seconds)
    audit = _experimental_speculative_cuts(
        audit,
        auditing_backend,
        segments,
        total_seconds,
        experimental_candidates,
        experimental_max_additional_model_calls,
    )
    audit.model_requests = auditing_backend.calls
    audit.model_failures = auditing_backend.failures
    if audit.unresolved_ids:
        details = ", ".join(str(segment_id) for segment_id in audit.unresolved_ids)
        raise WorkerError(
            "ads-classification-unresolved",
            f"classifier exhausted normal and corrective retries for global IDs: {details}",
        )
    return AdAnalysis(tuple(detections), audit)

def effective_ad_spans(ads_module, raw_nominations, keeps, total_seconds) -> list[dict]:
    """The removed intervals the keep map actually cuts, with their kinds.

    Effective-cut selection is the keep map's complement, not the nomination
    list: a nomination can be cut down or absorbed by its neighbour. Every
    nomination overlapping an interval contributes its kind, so a cut that
    removes a paid read and a house promotion together still reports both and
    is treated as a paid removal. An interval no nomination overlaps reports
    the label `advertisement` and a paid kind, the conservative reading.
    """
    spans = []
    for start, end in effective_removed_intervals(keeps, total_seconds):
        overlapping = [
            ad for ad in raw_nominations
            if ad["endSeconds"] > start and ad["startSeconds"] < end
        ]
        kinds = tuple(sorted({kind for ad in overlapping for kind in ad["kinds"]}))
        if not kinds:
            kinds = (ads_module.AD_KIND_PAID,)
        spans.append({
            "startSeconds": round(start, 3), "endSeconds": round(end, 3),
            "label": overlapping[0]["label"] if overlapping else "advertisement",
            **_ad_kind_fields(ads_module, kinds),
            "confidence": max((ad["confidence"] for ad in overlapping), default=0.0),
        })
    return spans

def _ad_kind_fields(ads_module, kinds) -> dict:
    """The kind fields every published span carries.

    `kind` is the single strongest kind for the span -- paid advertising,
    house promotion, or credits -- while `kinds` is the full set a merged span
    can carry, so two adjacent differently labelled runs report both rather
    than attributing the whole run to the survivor's label. `disposition` is
    the corpus's scoring vocabulary: `must-cut` for a span that contains paid
    advertising, `acceptable-cut` for house promotion and credits, which David
    decided on 2026-09-17 are not advertising.
    """
    if ads_module.AD_KIND_PAID in kinds:
        disposition = "must-cut"
    else:
        disposition = "acceptable-cut"
    for kind in (ads_module.AD_KIND_PAID, ads_module.AD_KIND_HOUSE, ads_module.AD_KIND_CREDITS):
        if kind in kinds:
            return {"kind": kind, "kinds": list(kinds), "disposition": disposition}
    # An unknown vocabulary is paid advertising by default: cutting a sold
    # placement is required, leaving programme in is not.
    return {"kind": ads_module.AD_KIND_PAID, "kinds": list(kinds), "disposition": "must-cut"}

def detect_and_cut(request: dict, audio_path: Path, cues: list[dict], segments, *, model_lock=None):
    """Detect ads and rewrite the audio without them.

    Returns `(output_path, ad_spans, keep_intervals, raw_nominations, audit)`.
    `output_path` is the input path when nothing was cut, and `keep_intervals`
    is empty in that case, which is the signal that cue timing still matches
    the file. `audit` is the serialized detector evidence for every run that
    analyzed the transcript; it is `None` only when there were no segments to
    analyze.
    """
    from wilted import ads as ads_module
    from wilted import llm as llm_module

    if not segments:
        # No audit exists because no analysis ran. Reporting one anyway is how
        # "nothing was examined" would come to read as "nothing was found".
        return audio_path, [], [], [], None

    model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
    model_lock = model_lock or _worker_gpu_admission.prepare_ad_model_lock(model, aligned_stt=False)
    # The previous project loads lazily and explicitly, under a coordinator
    # that keeps one model resident at a time. Without `load()` every
    # inference raises, and the detector's tolerance for bad completions turns
    # that into a clean, instant, wrong "no advertisements".
    with model_lock or contextlib.nullcontext():
        _worker_reporting.progress("ads.model.locked", "shared GPU inference lock acquired")
        _worker_reporting.progress("ads.model.load", Path(model).name)
        backend = None
        try:
            backend = llm_module.create_backend("gguf", model=model)
            backend.load()
        except Exception as error:  # noqa: BLE001 - reported, not raised through
            if backend is not None:
                try:
                    backend.close()
                except Exception:  # noqa: BLE001 - the load failure is the report
                    pass
            if not expected_backend_unavailable(error):
                raise
            reason = f"ad-detection model unavailable: {type(error).__name__}: {error}"
            warning = f"original audio includes ads: {reason}"
            _worker_reporting.progress("ads.uncertain", warning)
            audit = AdAnalysisAudit(model_failures=1, incomplete_error=reason, warning=warning)
            return audio_path, [], [], [], serialize_ad_audit(audit)

        try:
            counting = AuditingBackend(backend, ads_module, len(segments))
        except WorkerError as error:
            if error.code == "ads-audit-contract-unavailable":
                if backend is not None:
                    try:
                        backend.close()
                    except Exception:
                        pass
                reason = f"archived classifier contract unavailable: {error}"
                warning = f"original audio includes ads: {reason}"
                _worker_reporting.progress("ads.uncertain", warning)
                audit = AdAnalysisAudit(incomplete_error=reason, warning=warning)
                return audio_path, [], [], [], serialize_ad_audit(audit)
            raise

        try:
            remove_self_promotion = request.get("removeSelfPromotion") is True
            if remove_self_promotion:
                _worker_reporting.progress(
                    "ads.detect.self_promotion",
                    "removing the show's own promotion for this feed",
                )
            _worker_reporting.progress("ads.detect.start", f"{len(segments)} segments")
            # Probed before the recovery passes, not after them. The closing
            # review cuts to the end of the file and sizes itself against the
            # episode, and the case it exists for is the one where the detector
            # found nothing at all, so a probe conditional on detections would
            # never run for it. Both size guards then share this denominator.
            total = _worker_cue_timing.probe_duration(audio_path)
            try:
                if remove_self_promotion:
                    analysis = analyze_ad_detections(
                        ads_module, counting, segments, total, remove_self_promotion=True
                    )
                else:
                    analysis = analyze_ad_detections(ads_module, counting, segments, total)
                detections = list(analysis.detections)
            except WorkerError as error:
                if error.code in {
                    "ads-classification-unresolved",
                    "ads-classification-incomplete",
                    "ads-recovery-audit-failed",
                    "ads-audit-contract-unavailable",
                    "ads-backend-failed",
                    "ads-context-capacity-unavailable",
                }:
                    analysis = uncertain_ad_analysis(counting, segments, str(error))
                    return audio_path, [], [], [], serialize_ad_audit(analysis.audit)
                raise
            unresolved_seeds = [
                seed for seed in analysis.audit.declined_commercial_evidence_seeds
                if seed.reason != "review-declined" and not any(
                    # A positively preserved mixed cue resolves its own CTA evidence.
                    held.reason in {"sponsor-prefix-programme-found", "programme-boundary"}
                    and interval_contains(held.start_s, held.end_s, seed.start_s, seed.end_s)
                    for held in analysis.audit.held_spans
                )
            ]
            if (
                any(span.reason in {"total-share-ceiling", "programme-boundary-conflict",
                                    "boundary-review-unresolved", "credits-boundary-unresolved"}
                    for span in analysis.audit.held_spans)
                or unresolved_seeds
            ):
                # An unresolved span keeps the whole original and carries its
                # reason in the report.
                analysis = uncertain_ad_analysis(
                    counting, segments, "ad review could not safely resolve all proposed commercial spans",
                    held_spans=analysis.audit.held_spans, proposed_detections=detections, audit=analysis.audit,
                )
                return audio_path, [], [], [], serialize_ad_audit(analysis.audit)
        finally:
            try:
                backend.close()
            except Exception:  # noqa: BLE001 - a close failure cannot undo a detection
                pass
    _worker_reporting.progress("ads.detect.calls", f"{counting.calls} requests, {counting.failures} failed")
    if not detections:
        _worker_reporting.progress("ads.detect.complete", "0 spans")
        return audio_path, [], [], [], serialize_ad_audit(analysis.audit)

    raw_nominations = []
    for ad in detections:
        raw_nominations.append({
            "startSeconds": round(float(ad.start_s), 3),
            "endSeconds": round(float(ad.end_s), 3),
            "label": ad.label,
            **_ad_kind_fields(ads_module, ads_module.ad_segment_kinds(ad)),
            "confidence": round(float(ad.confidence), 4),
        })
    _worker_reporting.progress("ads.detect.complete", f"{len(raw_nominations)} spans")

    try:
        _, keeps = build_effective_cut_map(detections, total)
        keep_segments = [(keep.start_s, keep.end_s) for keep in keeps]
    except WorkerError as error:
        if error.code == "cut-unsafe":
            reason = f"ad cut unsafe: {error}"
            warning = f"original audio includes ads: {reason}"
            _worker_reporting.progress("ads.uncertain", warning)
            analysis.audit.incomplete_error = reason
            analysis.audit.warning = warning
            return audio_path, [], [], raw_nominations, serialize_ad_audit(analysis.audit)
        raise

    if not keeps:
        # Everything was called an ad. Refusing to cut is the only safe
        # reading: an empty file is worse than an unedited one.
        _worker_reporting.progress("ads.cut.refused", "every span was classified as an advertisement")
        reason = "every span was classified as an advertisement; refusing unsafe cut"
        warning = f"original audio includes ads: {reason}"
        _worker_reporting.progress("ads.uncertain", warning)
        analysis.audit.incomplete_error = reason
        analysis.audit.warning = warning
        return audio_path, [], [], raw_nominations, serialize_ad_audit(analysis.audit)

    output_path = Path(request["outputPath"])
    if output_path.resolve() == audio_path.resolve():
        raise WorkerError("cut-output-alias", "prepared output must not replace its input in place")
    _worker_reporting.progress("ads.cut.start", f"{len(keep_segments)} keep spans")
    # Long pauses come out of the rendered map only. The ad spans below stay
    # the complement of the ad-only map, so silence never counts as an ad.
    rendered = _worker_silence_trim.trimmed_keeps(audio_path, keeps)
    render_keep_segments(audio_path, output_path, rendered)
    if not output_path.exists() or output_path.stat().st_size == 0:
        raise WorkerError("cut-output-empty", "ffmpeg produced no playable audio")
    effective = effective_ad_spans(ads_module, raw_nominations, keeps, total)
    _worker_reporting.progress("ads.cut.complete", f"{output_path.stat().st_size} bytes")
    return output_path, effective, rendered, raw_nominations, serialize_ad_audit(analysis.audit)
