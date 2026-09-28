#!/usr/bin/env python3
"""Prepare one downloaded podcast episode: transcript, ad detection, ad removal.

This is the bridge to Wilted's project-owned Python runtime. The valuable,
hard-to-reproduce part is `wilted.ads` -- roughly 1,500 lines of tuned prompts
and boundary verification -- and the transcript parsers beside it. None of that
is reimplemented here; this module is the process boundary the native app talks
to.

Protocol, deliberately narrow:

  stdin   one JSON request object, then EOF
  stderr  newline-delimited JSON progress records, one per line
  stdout  one JSON response object

The worker performs no network access. Every document it needs -- the published
transcript, the episode page -- is fetched by the caller and passed in as text,
so the transport policy (HTTPS only, size caps, redirect rules) stays in one
place on the Swift side and no credentialed feed URL ever reaches this process.

Run it with the generated project-local environment and source tree:

    PYTHONPATH=Producer/Runtime/src Producer/Runtime/.venv/bin/python wilted_pipeline.py
"""

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

from wilted_worker import ad_audit as _worker_ad_audit
from wilted_worker import ad_removal as _worker_ad_removal
from wilted_worker import ad_runtime_adaptations as _worker_ad_runtime_adaptations
from wilted_worker import commercial_preservation as _worker_commercial_preservation
from wilted_worker import commercial_recovery as _worker_commercial_recovery
from wilted_worker import commercial_seeds as _worker_commercial_seeds
from wilted_worker import constants as _worker_constants
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import edge_recovery as _worker_edge_recovery
from wilted_worker import glossary as _worker_glossary
from wilted_worker import gpu_admission as _worker_gpu_admission
from wilted_worker import nomination as _worker_nomination
from wilted_worker import prompts as _worker_prompts
from wilted_worker import reporting as _worker_reporting
from wilted_worker import review_formats as _worker_review_formats
from wilted_worker import span_bounds as _worker_span_bounds
from wilted_worker import sponsor_evidence as _worker_sponsor_evidence
from wilted_worker import tail_recovery as _worker_tail_recovery
from wilted_worker import transcript_sources as _worker_transcript_sources
from wilted_worker.ad_audit import AdAnalysis
from wilted_worker.ad_audit import AdAnalysisAudit
from wilted_worker.ad_audit import AuditCandidate
from wilted_worker.ad_audit import AuditingBackend
from wilted_worker.ad_audit import CountingBackend
from wilted_worker.ad_audit import preflight_ad_removal
from wilted_worker.ad_removal import analyze_ad_detections
from wilted_worker.ad_removal import detect_and_cut
from wilted_worker.ad_removal import effective_ad_spans
from wilted_worker.ad_runtime_adaptations import _CONTEXT_AWARE_OVERLAP_MARKER
from wilted_worker.ad_runtime_adaptations import _PROPORTIONAL_RENDER_MARKER
from wilted_worker.ad_runtime_adaptations import _proportional_render_budgets
from wilted_worker.ad_runtime_adaptations import install_context_aware_overlap_resolution
from wilted_worker.ad_runtime_adaptations import install_legacy_sponsor_opening_compatibility
from wilted_worker.ad_runtime_adaptations import install_produced_disclaimer_evidence
from wilted_worker.ad_runtime_adaptations import install_proportional_render_budget
from wilted_worker.commercial_preservation import _commercial_envelope_preserved
from wilted_worker.commercial_preservation import recovered_confidence
from wilted_worker.commercial_seeds import commercial_evidence_seed_ids
from wilted_worker.commercial_seeds import recover_sparse_commercial_reads
from wilted_worker.commercial_seeds import sparse_commercial_seeds
from wilted_worker.commercial_seeds import sparse_pause_envelope
from wilted_worker.constants import ALIGNED_STT_CACHE_MAXIMUM_ENTRIES
from wilted_worker.constants import ALIGNED_STT_MODEL
from wilted_worker.constants import COMMERCIAL_PRESERVATION_FLANK_STEPS
from wilted_worker.constants import COMMERCIAL_RECOVERY_CONTEXT_CHARS
from wilted_worker.constants import COMMERCIAL_RECOVERY_MAX_CANDIDATES
from wilted_worker.constants import CUT_TOOLS
from wilted_worker.constants import EXPLICIT_SPONSOR_CTA_RE
from wilted_worker.constants import EXPLICIT_SPONSOR_DOT_DOMAIN_RE
from wilted_worker.constants import EXPLICIT_SPONSOR_LITERAL_DOMAIN_RE
from wilted_worker.constants import EXPLICIT_SPONSOR_OFFER_CODE_RE
from wilted_worker.constants import EXPLICIT_SPONSOR_SPOKEN_PATH_RE
from wilted_worker.constants import MAXIMUM_TOTAL_AD_SHARE
from wilted_worker.constants import MAXIMUM_UNCONFIRMED_AD_SHARE
from wilted_worker.constants import MINIMUM_PROGRAMME_SHARE
from wilted_worker.constants import MINIMUM_PROSE_WORDS
from wilted_worker.constants import NOMINATED_SECONDS_FLOOR
from wilted_worker.constants import NOMINATED_SHARE_FLOOR
from wilted_worker.constants import PRODUCED_DISCLAIMER_CUE_PATTERN
from wilted_worker.constants import PROTOCOL_VERSION
from wilted_worker.constants import RECOVERED_CONFIDENCE_CEILING
from wilted_worker.constants import RECOVERED_CONFIDENCE_FLOOR
from wilted_worker.constants import RENDER_DURATION_TOLERANCE_S
from wilted_worker.constants import STRADDLING_TAIL_MAX_PROBES
from wilted_worker.constants import STT_EVICTION_BARRIER_TIMEOUT_S
from wilted_worker.constants import TIMED_MEDIA_TYPES
from wilted_worker.cue_timing import CachedAlignedSegment
from wilted_worker.cue_timing import _near_empty_nominations
from wilted_worker.cue_timing import _run_render_with_progress
from wilted_worker.cue_timing import build_effective_cut_map
from wilted_worker.cue_timing import build_keep_map
from wilted_worker.cue_timing import cues_to_text
from wilted_worker.cue_timing import effective_removed_intervals
from wilted_worker.cue_timing import in_time_order
from wilted_worker.cue_timing import probe_duration
from wilted_worker.cue_timing import remap_cues
from wilted_worker.cue_timing import render_keep_segments
from wilted_worker.cue_timing import segments_to_cues
from wilted_worker.cue_timing import serialize_ad_audit
from wilted_worker.cue_timing import serialize_keep_map
from wilted_worker.cue_timing import validate_aligned_segments
from wilted_worker.edge_recovery import recover_transcript_start_preroll
from wilted_worker.glossary import GLOSSARY_MAXIMUM_TERMS
from wilted_worker.glossary import apply_glossary
from wilted_worker.glossary import build_glossary
from wilted_worker.glossary import polish_with_notes
from wilted_worker.gpu_admission import _speech_rpc_with_progress
from wilted_worker.gpu_admission import prepare_ad_model_lock
from wilted_worker.nomination import _CallBudgetBackend
from wilted_worker.nomination import _experimental_speculative_cuts
from wilted_worker.nomination import detect_nominated_ad_spans
from wilted_worker.prompts import AD_POD_CONTINUATION_PROMPT
from wilted_worker.prompts import BOUNDARY_SEGMENT_TAIL_PROMPT
from wilted_worker.prompts import COMMERCIAL_CONFLICTING_EVIDENCE_PROMPT
from wilted_worker.prompts import COMMERCIAL_PREFIX_CUE_PROMPT
from wilted_worker.prompts import COMMERCIAL_PREFIX_ROLE_PROMPT
from wilted_worker.prompts import OVERSIZED_SPAN_RESCAN_PROMPT
from wilted_worker.prompts import PREROLL_CONFIRM_PROMPT
from wilted_worker.prompts import PREROLL_PROGRAM_START_PROMPT
from wilted_worker.reporting import DiscardedRuns
from wilted_worker.reporting import ForwardedWarnings
from wilted_worker.reporting import WorkerError
from wilted_worker.reporting import progress
from wilted_worker.span_bounds import _rescan_unconfirmed_oversized_span
from wilted_worker.span_bounds import reject_implausible_ad_spans
from wilted_worker.span_bounds import resize_oversized_ad_spans
from wilted_worker.sponsor_evidence import consecutive_preroll_start
from wilted_worker.sponsor_evidence import count_sponsor_name_mentions
from wilted_worker.sponsor_evidence import explicit_sponsor_anchor_ids
from wilted_worker.sponsor_evidence import explicit_sponsor_name_phrases
from wilted_worker.sponsor_evidence import explicit_sponsor_opening_pattern
from wilted_worker.sponsor_evidence import sponsor_name_recurrence_text
from wilted_worker.tail_recovery import recover_transcript_end_postroll
from wilted_worker.tail_recovery import trim_straddling_span_tails
from wilted_worker.transcript_sources import _aligned_cache_directory
from wilted_worker.transcript_sources import _aligned_cache_path
from wilted_worker.transcript_sources import _load_cached_aligned_segments
from wilted_worker.transcript_sources import _store_cached_aligned_segments
from wilted_worker.transcript_sources import extract_prose
from wilted_worker.transcript_sources import parse_published_transcript
from wilted_worker.transcript_sources import published_transcript_matches_audio

def run(request: dict) -> dict:
    audio_path = Path(request["audioPath"])
    if not audio_path.exists():
        raise WorkerError("audio-missing", f"no audio at {audio_path}")
    requested_version = request.get("protocolVersion")
    if requested_version is not None and requested_version != PROTOCOL_VERSION:
        raise WorkerError("protocol-version-unsupported", f"expected protocolVersion {PROTOCOL_VERSION}")

    transcript_policy = request.get("transcriptPolicy")
    if transcript_policy is None:
        # Protocol-v1 callers predate explicit snapshots. Preserve their
        # published-first ordering and their existing STT switch exactly.
        allow_published_transcript = True
        allow_speech_to_text = request.get("allowSpeechToText", True)
    elif transcript_policy == "bestAvailable":
        allow_published_transcript = True
        allow_speech_to_text = True
    elif transcript_policy == "alwaysTranscribe":
        allow_published_transcript = False
        allow_speech_to_text = True
    elif transcript_policy == "noLocalSTT":
        allow_published_transcript = True
        allow_speech_to_text = False
    else:
        raise WorkerError("invalid-request", f"unknown transcriptPolicy: {transcript_policy}")

    remove_ads = request.get("removeAds", True)
    strict_v2 = requested_version == PROTOCOL_VERSION
    if strict_v2 and remove_ads and transcript_policy == "noLocalSTT":
        raise WorkerError("aligned-stt-required", "ad removal requires audio-aligned Parakeet timing; noLocalSTT forbids it")
    if remove_ads:
        if strict_v2 and "outputPath" not in request:
            raise WorkerError("cut-output-missing", "ad removal requires a distinct outputPath")
        if strict_v2 and Path(request["outputPath"]).resolve() == audio_path.resolve():
            raise WorkerError("cut-output-alias", "prepared output must not alias the downloaded audio")
        _worker_ad_audit.preflight_ad_removal(request)
        if strict_v2 and request.get("alignedTranscriptModel", ALIGNED_STT_MODEL) != ALIGNED_STT_MODEL:
            raise WorkerError("aligned-stt-model-required", f"ad removal requires {ALIGNED_STT_MODEL}")

    cues: list[dict] = []
    segments = None
    timing = "none"
    text: str | None = None
    language = request.get("language")

    # A removal request must be timed from this exact downloaded audio. Do not
    # fetch or parse publisher cues which are guaranteed not to drive it.
    published = request.get("publishedTranscript") if allow_published_transcript and not (remove_ads and strict_v2) else None
    if published:
        _worker_reporting.progress("transcript.published.parse", published.get("mediaType", ""))
        # Sorted for the same reason speech-to-text is: a feed's own file is no
        # more guaranteed to be in time order, and the detector reads it by
        # position either way.
        segments = in_time_order(parse_published_transcript(
            published.get("body", ""), published.get("mediaType", ""), published.get("url", "")
        ))
        if segments and not published_transcript_matches_audio(segments, audio_path):
            # Dropped rather than kept with a warning: these segments are what
            # the detector cuts from, so keeping them would aim the cut at the
            # wrong seconds of a file they do not describe. Speech-to-text
            # below reads the audio that was actually downloaded.
            segments = None
        if segments:
            cues = segments_to_cues(segments)
            timing = "published"
            language = published.get("languageCode") or language
            _worker_reporting.progress("transcript.published.accepted", f"{len(cues)} cues")

    if ((remove_ads and strict_v2) or not cues) and allow_speech_to_text:
        aligned_model = (ALIGNED_STT_MODEL if remove_ads and strict_v2
                         else (request.get("alignedTranscriptModel") or ALIGNED_STT_MODEL))
        source_hash = request.get("sourceHash")
        try:
            audio_duration = _worker_cue_timing.probe_duration(audio_path) if remove_ads else None
            if isinstance(source_hash, str) and source_hash and isinstance(aligned_model, str) and aligned_model:
                segments = _load_cached_aligned_segments(request, source_hash, aligned_model)
            if segments is None:
                segments = _worker_transcript_sources.transcribe_with_daemon(audio_path, aligned_model)
                if isinstance(source_hash, str) and source_hash and isinstance(aligned_model, str) and aligned_model:
                    _store_cached_aligned_segments(request, source_hash, aligned_model, segments)
            if remove_ads and strict_v2:
                segments = validate_aligned_segments(segments, audio_duration)
            cues = segments_to_cues(segments)
            timing = "aligned"
        except Exception as error:  # noqa: BLE001 - a failed tier falls through
            segments = None
            _worker_reporting.progress("transcript.stt.failed", f"{type(error).__name__}: {error}")
            if remove_ads and strict_v2:
                if isinstance(error, WorkerError):
                    raise
                raise WorkerError("aligned-stt-unavailable", f"ad removal requires aligned speech-to-text: {type(error).__name__}: {error}") from error
    if not cues:
        page = request.get("episodePage")
        if page:
            _worker_reporting.progress("transcript.prose.extract", "")
            text = extract_prose(page)
            if text:
                _worker_reporting.progress("transcript.prose.accepted", f"{len(text.split())} words")

    if not cues and not text:
        _worker_reporting.progress("transcript.absent", "no published, aligned, or prose transcript")

    output_path, ad_spans, keeps, raw_nominations, ad_audit = audio_path, [], [], [], None
    if remove_ads and (strict_v2 or segments):
        if not segments or (strict_v2 and timing != "aligned"):
            if strict_v2:
                raise WorkerError("aligned-stt-required", "ad removal requires valid audio-aligned speech-to-text")
            remove_ads = False
        else:
            from wilted import llm as llm_module

            model = request.get("llmModel") or str(llm_module.DEFAULT_GGUF_MODEL)
            model_lock = _worker_gpu_admission.prepare_ad_model_lock(model, aligned_stt=timing == "aligned")
            if strict_v2:
                output_path, ad_spans, keeps, raw_nominations, ad_audit = _worker_ad_removal.detect_and_cut(
                    request, audio_path, cues, segments, model_lock=model_lock, with_report=True
                )
            else:
                output_path, ad_spans, keeps = _worker_ad_removal.detect_and_cut(
                    request, audio_path, cues, segments, model_lock=model_lock
                )
            if keeps:
                before = len(cues)
                cues = remap_cues(cues, keeps)
                _worker_reporting.progress("transcript.remap", f"{before} cues to {len(cues)} on the cut timeline")

    if cues:
        cues = polish_with_notes(request, cues)
        text = cues_to_text(cues)

    # Measure the delivered file rather than subtracting what was removed: the
    # encoder decides the final frame boundaries, and a duration that disagrees
    # with the audio would desynchronise the very cues this pipeline exists to
    # align. A probe failure is not fatal -- the caller keeps its own value.
    try:
        duration = _worker_cue_timing.probe_duration(output_path)
    except Exception as error:  # noqa: BLE001 - the caller has a fallback
        duration = None
        _worker_reporting.progress("audio.probe.failed", f"{type(error).__name__}: {error}")

    outcome = "disabled" if not remove_ads else ("cut" if keeps else "noAds")
    if strict_v2 and remove_ads and (duration is None or not duration > 0 or not duration < float("inf")):
        raise WorkerError("output-duration-invalid", "ad removal output has no finite measured duration")
    if strict_v2 and remove_ads and ad_audit is None:
        raise WorkerError("ads-audit-missing", "ad removal produced no auditable detector evidence")
    return {
        "ok": True,
        "protocolVersion": PROTOCOL_VERSION,
        "durationSeconds": duration,
        "timing": timing if cues else "none",
        "cues": cues,
        "text": text,
        "languageCode": language,
        "audioPath": str(output_path),
        "audioChanged": str(output_path) != str(audio_path),
        "adSegments": ad_spans,
        # The exact original-to-output time map, so the caller can move a
        # listener's saved position onto the cut audio instead of losing it.
        # Empty means nothing was cut and every timestamp still matches.
        "keepIntervals": serialize_keep_map(keeps),
        "removedSeconds": round(sum(a["endSeconds"] - a["startSeconds"] for a in ad_spans), 3) if keeps else 0.0,
        # Nominations and detector evidence stay here, out of `adSegments`:
        # what was cut is the keep map's complement, and what was merely
        # proposed is review material, not a claim about the delivered audio.
        "report": {
            "outcome": outcome,
            "rawNominations": raw_nominations,
            "audit": ad_audit,
        },
    }

def main() -> int:
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as error:
        json.dump({"ok": False, "code": "bad-request", "message": str(error)}, sys.stdout)
        return 2
    if not isinstance(request, dict):
        json.dump({"ok": False, "code": "bad-request", "message": "request must be an object"}, sys.stdout)
        return 2

    data_dir = Path(request.get("workDir") or tempfile.gettempdir()) / "wilted-pipeline"
    data_dir.mkdir(parents=True, exist_ok=True)
    warnings = ForwardedWarnings()
    # The root logger, not `wilted`: the speech daemon client and the
    # transcript parsers log under their own names.
    logging.getLogger().addHandler(warnings)
    try:
        # The previous project gates model construction behind an explicit
        # capability so nothing loads a multi-gigabyte model by accident. This
        # process exists to do exactly that, so it claims the capability once
        # around the whole run.
        from wilted.execution_capability import execution_capability_scope

        with execution_capability_scope(owner_id="wilted-native-pipeline", data_dir=data_dir):
            result = run(request)
    except WorkerError as error:
        warnings.summarize()
        json.dump({"ok": False, "code": error.code, "message": str(error)}, sys.stdout)
        return 1
    except Exception as error:  # noqa: BLE001 - the caller needs a result, not a traceback
        warnings.summarize()
        json.dump({"ok": False, "code": "worker-failed",
                   "message": f"{type(error).__name__}: {error}"}, sys.stdout)
        return 1
    warnings.summarize()
    json.dump(result, sys.stdout)
    return 0

if __name__ == "__main__":
    sys.exit(main())
