"""Decide and audit cuts from online-labeller validated breaks.

The cut stage never loads the local classifier. It turns the request's
``labelledBreaks`` into nominations, leaves rejected breaks audible, applies
the same share ceiling the local path uses, then places edges with the
existing ``cue_timing`` and ``silence_trim`` helpers.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

from . import cue_timing as _worker_cue_timing
from . import reporting as _worker_reporting
from . import silence_trim as _worker_silence_trim
from .ad_outcome import UNRESOLVED_SPANS_REASON
from .cue_timing import build_effective_cut_map, render_keep_segments
from .labeller_cues import build_labeller_cues, serialize_labeller_cues
from .reporting import WorkerError
from .span_bounds import enforce_total_ad_share_ceiling

_AD_KIND_PAID = "paid advertising"
_AD_KIND_HOUSE = "house promotion"
_CUTTABLE_KINDS = frozenset({"sponsor", "network-promo"})
_HOUSE_KIND = "house-promo"
_MUST_CUT = "must-cut"
_ACCEPTABLE_CUT = "acceptable-cut"
_HOUSE_DISABLED_REASON = "house-promotion-disabled"
_ACCEPTABLE_REASON = "acceptable-cut"
_OUT_OF_RANGE_REASON = "out-of-range"
_MALFORMED_REASON = "malformed"


@dataclass(frozen=True)
class _LabelledDetection:
    """A nomination the cut stage will feed to ``build_effective_cut_map``."""

    start_s: float
    end_s: float
    label: str
    kinds: tuple[str, ...]
    confidence: float = 1.0


@dataclass(frozen=True)
class _LeftInBreak:
    """One proposed break that stays audible, with why."""

    start_s: float | None
    end_s: float | None
    kind: str | None
    label: str | None
    advertisers: tuple[str, ...]
    reason: str


@dataclass(frozen=True)
class LabelledDecision:
    """Cut nominations, left-in breaks, and an optional whole-original reason."""

    detections: tuple[_LabelledDetection, ...]
    left_in: tuple[_LeftInBreak, ...]
    keep_whole_reason: str | None
    breaks_proposed: int
    held_spans: tuple[tuple[float, float, str], ...] = ()


class _KindModule:
    """Minimal kind vocabulary for ``effective_ad_spans`` / ``_ad_kind_fields``."""

    AD_KIND_PAID = _AD_KIND_PAID
    AD_KIND_HOUSE = _AD_KIND_HOUSE
    AD_KIND_CREDITS = "credits"


def _advertisers(raw) -> tuple[str, ...]:
    value = raw.get("advertisers") if isinstance(raw, dict) else None
    if not isinstance(value, list):
        return ()
    return tuple(str(item) for item in value if isinstance(item, str))


def _parse_timing(raw: dict, total_seconds: float) -> tuple[float, float] | None:
    """Return finite in-range ``(start, end)`` or ``None`` when the break is unusable."""
    try:
        start = float(raw["start"])
        end = float(raw["end"])
    except (KeyError, TypeError, ValueError):
        return None
    if not (math.isfinite(start) and math.isfinite(end)):
        return None
    if start < 0 or end <= start or start >= total_seconds or end > total_seconds:
        return None
    return start, end


def decide_labelled_outcome(
    labelled_breaks,
    total_seconds: float,
    *,
    remove_self_promotion: bool,
) -> LabelledDecision:
    """Choose which validated breaks become cuts.

    Args:
        labelled_breaks: Request objects with ``start``, ``end``, ``kind``,
            ``label`` and ``advertisers``.
        total_seconds: Probed episode duration on the original clock.
        remove_self_promotion: When true, ``house-promo`` breaks labelled
            ``must-cut`` are cut; otherwise they stay in.

    Returns:
        The cut set, left-in breaks with reasons, and an optional
        whole-original reason after the share ceiling.
    """
    if not (total_seconds > 0 and total_seconds < float("inf")):
        raise WorkerError("cut-unsafe", "source duration is not finite and positive")
    if not isinstance(labelled_breaks, list):
        raise WorkerError("invalid-request", "cut stage requires labelledBreaks")

    detections: list[_LabelledDetection] = []
    left_in: list[_LeftInBreak] = []
    for raw in labelled_breaks:
        if not isinstance(raw, dict):
            left_in.append(_LeftInBreak(None, None, None, None, (), _MALFORMED_REASON))
            continue
        kind = raw.get("kind") if isinstance(raw.get("kind"), str) else None
        label = raw.get("label") if isinstance(raw.get("label"), str) else None
        advertisers = _advertisers(raw)
        timing = _parse_timing(raw, total_seconds)
        if timing is None:
            reason = _MALFORMED_REASON
            try:
                start_value = float(raw["start"])
                end_value = float(raw["end"])
            except (KeyError, TypeError, ValueError):
                left_in.append(
                    _LeftInBreak(None, None, kind, label, advertisers, reason)
                )
                continue
            if math.isfinite(start_value) and math.isfinite(end_value):
                reason = _OUT_OF_RANGE_REASON
                left_in.append(
                    _LeftInBreak(
                        start_value, end_value, kind, label, advertisers, reason
                    )
                )
            else:
                left_in.append(
                    _LeftInBreak(None, None, kind, label, advertisers, reason)
                )
            continue
        start_s, end_s = timing
        if label == _ACCEPTABLE_CUT and kind in {_HOUSE_KIND, *_CUTTABLE_KINDS}:
            left_in.append(
                _LeftInBreak(
                    start_s, end_s, kind, label, advertisers, _ACCEPTABLE_REASON
                )
            )
            continue
        if label != _MUST_CUT or kind not in {_HOUSE_KIND, *_CUTTABLE_KINDS}:
            left_in.append(
                _LeftInBreak(
                    start_s, end_s, kind, label, advertisers, _MALFORMED_REASON
                )
            )
            continue
        if kind == _HOUSE_KIND and not remove_self_promotion:
            left_in.append(
                _LeftInBreak(
                    start_s, end_s, kind, label, advertisers, _HOUSE_DISABLED_REASON
                )
            )
            continue
        kinds = (_AD_KIND_HOUSE,) if kind == _HOUSE_KIND else (_AD_KIND_PAID,)
        detections.append(_LabelledDetection(start_s, end_s, kind, kinds))

    held: list[tuple[float, float, str]] = []
    held_spans: list = []
    kept = enforce_total_ad_share_ceiling(detections, total_seconds, held_spans)
    # The ceiling is all-or-nothing; a partial result is treated the same way,
    # so a held break can never go missing from both the cuts and the report.
    if len(kept) < len(detections):
        for span in held_spans:
            held.append((float(span.start_s), float(span.end_s), span.reason))
        return LabelledDecision(
            detections=(),
            left_in=tuple(left_in),
            keep_whole_reason=UNRESOLVED_SPANS_REASON,
            breaks_proposed=len(labelled_breaks),
            held_spans=tuple(held),
        )
    return LabelledDecision(
        detections=tuple(kept),
        left_in=tuple(left_in),
        keep_whole_reason=None,
        breaks_proposed=len(labelled_breaks),
        held_spans=(),
    )


def serialize_labelled_audit(decision: LabelledDecision, request: dict) -> dict:
    """Publish the labelled-path audit the cut stage returns in ``report.audit``.

    Args:
        decision: The outcome from :func:`decide_labelled_outcome`.
        request: The worker request, for labeller provenance fields.

    Returns:
        A JSON-ready audit with ``adEngine: "labelled"``, break counts, left-in
        breaks and the labeller model, level and prompt version.
    """
    left_in = [
        {
            **(
                {"startSeconds": round(item.start_s, 3)}
                if item.start_s is not None
                else {}
            ),
            **({"endSeconds": round(item.end_s, 3)} if item.end_s is not None else {}),
            **({"kind": item.kind} if item.kind is not None else {}),
            **({"label": item.label} if item.label is not None else {}),
            "advertisers": list(item.advertisers),
            "reason": item.reason,
        }
        for item in decision.left_in
    ]
    audit = {
        "adEngine": "labelled",
        "breaksProposed": decision.breaks_proposed,
        "breaksCut": len(decision.detections),
        "breaksLeftIn": len(decision.left_in),
        "leftIn": left_in,
        "labellerModelID": request.get("labellerModelID"),
        "labellerLevel": request.get("labellerLevel"),
        "labellerPromptVersion": request.get("labellerPromptVersion"),
        "heldSpans": [
            {
                "reason": reason,
                "startSeconds": round(start_s, 3),
                "endSeconds": round(end_s, 3),
            }
            for start_s, end_s, reason in decision.held_spans
        ],
        "incompleteError": None,
        "warning": None,
        "unresolvedIds": [],
        "modelRequests": 0,
        "modelFailures": 0,
        "experimentalRequests": 0,
        "classifierRequests": 0,
        "classifierValidRequests": 0,
        "classifierInvalidRequests": 0,
        "exhaustedSingletonLineages": 0,
        "candidates": [],
        "declinedCommercialEvidenceSeeds": [],
        "nearEmpty": None,
        "adProfileStatus": "absent",
        "adProfileRequestedDigest": None,
        "adProfileAppliedDigest": None,
        "adProfileWindows": 0,
        "adProfileRequests": 0,
        "adProfileFailures": 0,
    }
    if decision.keep_whole_reason is not None:
        warning = f"original audio includes ads: {decision.keep_whole_reason}"
        audit["incompleteError"] = decision.keep_whole_reason
        audit["warning"] = warning
        audit["breaksCut"] = 0
    return audit


def verify_labeller_cues_digest(segments, expected_digest: str) -> None:
    """Recompute the cue digest and refuse a mismatch.

    Args:
        segments: Aligned transcript segments on the original clock.
        expected_digest: The ``labellerCuesDigest`` from the request.

    Raises:
        WorkerError: ``labelled-cues-mismatch`` when the digests differ.
    """
    if not isinstance(expected_digest, str) or not expected_digest:
        raise WorkerError("invalid-request", "cut stage requires labellerCuesDigest")
    _payload, digest = serialize_labeller_cues(build_labeller_cues(segments))
    if digest != expected_digest:
        raise WorkerError(
            "labelled-cues-mismatch",
            "aligned transcript digest does not match labellerCuesDigest",
        )


def cut_from_labelled_breaks(
    request: dict, audio_path: Path, cues: list[dict], segments
):
    """Cut and render from labelled breaks without loading the local model.

    Args:
        request: The worker request, including ``labelledBreaks`` and
            ``labellerCuesDigest``.
        audio_path: The downloaded episode audio.
        cues: Reader cues (unused for edge placement; kept for call parity).
        segments: Aligned segments used to recompute the cue digest.

    Returns:
        ``(output_path, ad_spans, keep_intervals, raw_nominations, audit)`` in
        the same shape ``detect_and_cut`` returns.
    """
    del cues  # Call parity with detect_and_cut; edges come from break times.
    # Lazy import: ``ad_removal`` dispatches into this module.
    from .ad_removal import _ad_kind_fields, effective_ad_spans

    if not segments:
        return audio_path, [], [], [], None
    verify_labeller_cues_digest(segments, request.get("labellerCuesDigest"))
    total = _worker_cue_timing.probe_duration(audio_path)
    decision = decide_labelled_outcome(
        request.get("labelledBreaks"),
        total,
        remove_self_promotion=request.get("removeSelfPromotion") is True,
    )
    audit = serialize_labelled_audit(decision, request)
    if decision.keep_whole_reason is not None:
        _worker_reporting.progress("ads.uncertain", audit["warning"])
        return audio_path, [], [], [], audit
    if not decision.detections:
        _worker_reporting.progress("ads.detect.complete", "0 spans")
        return audio_path, [], [], [], audit

    raw_nominations = []
    for ad in decision.detections:
        raw_nominations.append(
            {
                "startSeconds": round(float(ad.start_s), 3),
                "endSeconds": round(float(ad.end_s), 3),
                "label": ad.label,
                **_ad_kind_fields(_KindModule, ad.kinds),
                "confidence": round(float(ad.confidence), 4),
            }
        )
    _worker_reporting.progress("ads.detect.complete", f"{len(raw_nominations)} spans")

    try:
        _, keeps = build_effective_cut_map(decision.detections, total)
        keep_segments = [(keep.start_s, keep.end_s) for keep in keeps]
    except WorkerError as error:
        if error.code == "cut-unsafe":
            reason = f"ad cut unsafe: {error}"
            warning = f"original audio includes ads: {reason}"
            _worker_reporting.progress("ads.uncertain", warning)
            audit["incompleteError"] = reason
            audit["warning"] = warning
            audit["breaksCut"] = 0
            return audio_path, [], [], raw_nominations, audit
        raise

    if not keeps:
        reason = "every span was classified as an advertisement; refusing unsafe cut"
        warning = f"original audio includes ads: {reason}"
        _worker_reporting.progress("ads.uncertain", warning)
        audit["incompleteError"] = reason
        audit["warning"] = warning
        audit["breaksCut"] = 0
        return audio_path, [], [], raw_nominations, audit

    output_path = Path(request["outputPath"])
    if output_path.resolve() == audio_path.resolve():
        raise WorkerError(
            "cut-output-alias", "prepared output must not replace its input in place"
        )
    _worker_reporting.progress("ads.cut.start", f"{len(keep_segments)} keep spans")
    rendered = _worker_silence_trim.trimmed_keeps(audio_path, keeps)
    render_keep_segments(audio_path, output_path, rendered)
    if not output_path.exists() or output_path.stat().st_size == 0:
        raise WorkerError("cut-output-empty", "ffmpeg produced no playable audio")
    effective = effective_ad_spans(_KindModule, raw_nominations, keeps, total)
    _worker_reporting.progress(
        "ads.cut.complete", f"{output_path.stat().st_size} bytes"
    )
    return output_path, effective, rendered, raw_nominations, audit
