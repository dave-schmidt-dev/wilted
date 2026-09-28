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
from . import span_bounds as _worker_span_bounds
from . import tail_recovery as _worker_tail_recovery
from .ad_audit import AdAnalysis, AuditingBackend
from .ad_runtime_adaptations import install_context_aware_overlap_resolution, install_legacy_sponsor_opening_compatibility, install_produced_disclaimer_evidence, install_proportional_render_budget
from .constants import COMMERCIAL_RECOVERY_MAX_ADDITIONAL_CALLS
from .cue_timing import _near_empty_nominations, build_effective_cut_map, build_keep_map, effective_removed_intervals, render_keep_segments, serialize_ad_audit
from .nomination import _CallBudgetBackend, _experimental_speculative_cuts, detect_nominated_ad_spans
from .reporting import DiscardedRuns, WorkerError
from .span_bounds import recover_adjacent_ad_pod_continuations, reject_implausible_ad_spans
from .sponsor_evidence import explicit_sponsor_anchor_ids, explicit_sponsor_opening_pattern, sponsor_anchor_is_covered
from .tail_recovery import trim_straddling_span_tails

def analyze_ad_detections(
    ads_module,
    backend,
    segments,
    total_seconds: float,
    *,
    pod_share_bound: float | None = None,
    experimental_candidates=(),
    experimental_max_additional_model_calls: int = 0,
) -> AdAnalysis:
    """Run the archive detector and every worker safeguard with an auditable result.

    The caller owns model construction, GPU admission, and closing. This makes
    the exact live path replayable with a supplied backend and duration, while
    retaining the archive as the sole classifier and recovery implementation.

    `pod_share_bound` is the optional proportional bound on a single nominated
    pod, passed through to `detect_nominated_ad_spans`. It is `None` in
    production because no corpus case can justify a value; the seam exists so
    a bound can be supplied and measured the day a short-episode case lands.
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
        detections = detect_nominated_ad_spans(
            ads_module,
            auditing_backend,
            segments,
            total_seconds,
            pod_share_bound=pod_share_bound,
        )
    finally:
        ads_logger.removeHandler(discarded)
        ads_logger.setLevel(previous_level)
        discarded.summarize()

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
    detections = _worker_commercial_recovery.recover_unclaimed_explicit_sponsor_reads(
        ads_module,
        auditing_backend,
        segments,
        detections,
    )
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
    detections = _worker_tail_recovery.recover_transcript_end_postroll(
        ads_module, auditing_backend, segments, detections, total_seconds
    )
    detections = trim_straddling_span_tails(
        ads_module,
        auditing_backend,
        segments,
        detections,
        explicit_sponsor_opening_pattern(ads_module),
    )
    detections, confirmed_spans = _worker_span_bounds.resize_oversized_ad_spans(
        ads_module, auditing_backend, segments, detections, total_seconds
    )
    proposed_detections = detections
    detections = reject_implausible_ad_spans(detections, total_seconds, confirmed_spans)
    detections = recover_adjacent_ad_pod_continuations(
        ads_module, auditing_backend, segments, detections, total_seconds
    )
    opening_pattern = explicit_sponsor_opening_pattern(ads_module)
    dropped_anchor_ids = [
        anchor_id
        for anchor_id in explicit_sponsor_anchor_ids(segments, opening_pattern)
        if sponsor_anchor_is_covered(anchor_id, segments, proposed_detections)
        and not sponsor_anchor_is_covered(anchor_id, segments, detections)
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

def detect_and_cut(request: dict, audio_path: Path, cues: list[dict], segments, *, model_lock=None,
                   with_report: bool = False):
    """Detect ads and rewrite the audio without them.

    Returns `(output_path, ad_spans, keep_intervals)`, or the same three plus
    `(raw_nominations, audit)` when `with_report`. `output_path` is the input
    path when nothing was cut, and `keep_intervals` is empty in that case,
    which is the signal that cue timing still matches the file.
    """
    from wilted import ads as ads_module
    from wilted import llm as llm_module

    if not segments:
        # No audit exists because no analysis ran. Reporting one anyway is how
        # "nothing was examined" would come to read as "nothing was found".
        return (audio_path, [], [], [], None) if with_report else (audio_path, [], [])

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
            raise WorkerError("ads-model-unavailable", f"{type(error).__name__}: {error}") from error
        counting = AuditingBackend(backend, ads_module, len(segments))
        try:
            _worker_reporting.progress("ads.detect.start", f"{len(segments)} segments")
            # Probed before the recovery passes, not after them. The closing
            # review cuts to the end of the file and sizes itself against the
            # episode, and the case it exists for is the one where the detector
            # found nothing at all, so a probe conditional on detections would
            # never run for it. Both size guards then share this denominator.
            total = _worker_cue_timing.probe_duration(audio_path)
            analysis = analyze_ad_detections(ads_module, counting, segments, total)
            detections = list(analysis.detections)
        finally:
            try:
                backend.close()
            except Exception:  # noqa: BLE001 - a close failure cannot undo a detection
                pass
    _worker_reporting.progress("ads.detect.calls", f"{counting.calls} requests, {counting.failures} failed")
    if not detections:
        _worker_reporting.progress("ads.detect.complete", "0 spans")
        if with_report:
            return audio_path, [], [], [], serialize_ad_audit(analysis.audit)
        return audio_path, [], []

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

    if with_report:
        _, keeps = build_effective_cut_map(detections, total)
        keep_segments = [(keep.start_s, keep.end_s) for keep in keeps]
    else:
        keep_segments = ads_module._compute_keep_segments(total, detections, 0.5)  # noqa: SLF001
        keeps = build_keep_map(keep_segments)
    if not keeps:
        # Everything was called an ad. Refusing to cut is the only safe
        # reading: an empty file is worse than an unedited one.
        _worker_reporting.progress("ads.cut.refused", "every span was classified as an advertisement")
        if with_report:
            raise WorkerError("cut-unsafe", "every span was classified as an advertisement")
        return audio_path, raw_nominations, []

    output_path = Path(request["outputPath"])
    if output_path.resolve() == audio_path.resolve():
        raise WorkerError("cut-output-alias", "prepared output must not replace its input in place")
    _worker_reporting.progress("ads.cut.start", f"{len(keep_segments)} keep spans")
    # The three-value form is retained for the archive-adapter unit tests.
    # Production always asks for the report and takes the accurate path below.
    if not with_report:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        ads_module.cut_ads(audio_path, detections, output_path)
        if not output_path.exists() or output_path.stat().st_size == 0:
            output_path.unlink(missing_ok=True)
            return audio_path, raw_nominations, []
        return output_path, raw_nominations, keeps
    render_keep_segments(audio_path, output_path, keeps)
    if not output_path.exists() or output_path.stat().st_size == 0:
        raise WorkerError("cut-output-empty", "ffmpeg produced no playable audio")
    effective = effective_ad_spans(ads_module, raw_nominations, keeps, total)
    _worker_reporting.progress("ads.cut.complete", f"{output_path.stat().st_size} bytes")
    if with_report:
        return output_path, effective, keeps, raw_nominations, serialize_ad_audit(analysis.audit)
    return output_path, effective, keeps
