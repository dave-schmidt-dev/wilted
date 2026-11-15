#!/usr/bin/env python3
"""Prepare one downloaded podcast episode: transcript, labelled ad cut, silence trim.

This is the bridge to Wilted's project-owned Python runtime: the process
boundary the native app talks to.

Protocol, deliberately narrow:

  stdin   one JSON request object, then EOF
  stderr  newline-delimited JSON progress records, one per line
  stdout  one JSON response object

The worker performs no network access. Every document it needs -- the published
transcript -- is fetched by the caller and passed in as text,
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
import faulthandler
import html
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import unicodedata
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

from wilted_worker import constants as _worker_constants
from wilted_worker import cue_timing as _worker_cue_timing
from wilted_worker import cut_support as _worker_cut_support
from wilted_worker import glossary as _worker_glossary
from wilted_worker import labelled_outcome as _worker_labelled_outcome
from wilted_worker import labeller_cues as _worker_labeller_cues
from wilted_worker import reporting as _worker_reporting
from wilted_worker import silence_trim as _worker_silence_trim
from wilted_worker import transcript_sources as _worker_transcript_sources
from wilted_worker.constants import (
    ALIGNED_STT_CACHE_MAXIMUM_ENTRIES,
    ALIGNED_STT_MODEL,
    ALIGNED_STT_PREVIOUS_MODEL,
    CUT_TOOLS,
    PROTOCOL_VERSION,
    TIMED_MEDIA_TYPES,
)
from wilted_worker.cue_timing import (
    build_effective_cut_map,
    build_keep_map,
    cues_to_text,
    effective_removed_intervals,
    in_time_order,
    probe_duration,
    remap_cues,
    segments_to_cues,
    serialize_keep_map,
    validate_aligned_segments,
)
from wilted_worker.cut_support import preflight_cut_tools
from wilted_worker.glossary import polish_with_notes
from wilted_worker.reporting import (
    ForwardedWarnings,
    WorkerError,
    progress,
)
from wilted_worker.transcript_sources import (
    _aligned_cache_directory,
    _aligned_cache_path,
    _load_cached_aligned_segments,
    _store_cached_aligned_segments,
    parse_published_transcript,
    published_transcript_matches_audio,
)

def run(request: dict) -> dict:
    if request.get("operation") == "summary":
        from wilted_worker.transcript_summary import run_summary, summary_request_id
        with _worker_reporting.summary_scope(summary_request_id(request)):
            return run_summary(request)
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

    ad_stage = request.get("adStage")
    if ad_stage is not None and ad_stage not in ("transcript", "cut"):
        raise WorkerError("invalid-request", f"unknown adStage: {ad_stage}")
    remove_ads = True if ad_stage == "cut" else request.get("removeAds", True)
    if ad_stage == "transcript":
        remove_ads = False
    if remove_ads and ad_stage not in ("transcript", "cut"):
        raise WorkerError("invalid-request", "local ad finding was removed")
    need_aligned = remove_ads or ad_stage == "transcript"
    if need_aligned and requested_version != PROTOCOL_VERSION:
        raise WorkerError("protocol-version-required", f"ad removal requires protocolVersion {PROTOCOL_VERSION}")
    if need_aligned and transcript_policy == "noLocalSTT":
        raise WorkerError("aligned-stt-required", "ad removal requires audio-aligned Parakeet timing; noLocalSTT forbids it")
    if ad_stage == "cut":
        if not isinstance(request.get("labelledBreaks"), list):
            raise WorkerError("invalid-request", "cut stage requires labelledBreaks")
        if not isinstance(request.get("labellerCuesDigest"), str) or not request["labellerCuesDigest"]:
            raise WorkerError("invalid-request", "cut stage requires labellerCuesDigest")
    if remove_ads:
        if "outputPath" not in request:
            raise WorkerError("cut-output-missing", "ad removal requires a distinct outputPath")
        if Path(request["outputPath"]).resolve() == audio_path.resolve():
            raise WorkerError("cut-output-alias", "prepared output must not alias the downloaded audio")
        _worker_cut_support.preflight_cut_tools()
        requested_model = request.get("alignedTranscriptModel", ALIGNED_STT_MODEL)
        if requested_model == ALIGNED_STT_PREVIOUS_MODEL:
            _worker_reporting.progress("transcript.stt.model.substituted", f"{requested_model} -> {ALIGNED_STT_MODEL}")
        elif requested_model != ALIGNED_STT_MODEL:
            raise WorkerError("aligned-stt-model-required", f"ad removal requires {ALIGNED_STT_MODEL}")
    elif ad_stage == "transcript":
        requested_model = request.get("alignedTranscriptModel", ALIGNED_STT_MODEL)
        if requested_model == ALIGNED_STT_PREVIOUS_MODEL:
            _worker_reporting.progress("transcript.stt.model.substituted", f"{requested_model} -> {ALIGNED_STT_MODEL}")
        elif requested_model != ALIGNED_STT_MODEL:
            raise WorkerError("aligned-stt-model-required", f"ad removal requires {ALIGNED_STT_MODEL}")

    cues: list[dict] = []
    segments = None
    timing = "none"
    text: str | None = None
    language = request.get("language")

    # A removal request must be timed from this exact downloaded audio. Do not
    # fetch or parse publisher cues which are guaranteed not to drive it.
    published = request.get("publishedTranscript") if allow_published_transcript and not need_aligned else None
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

    audio_duration = None
    if (need_aligned or not cues) and allow_speech_to_text:
        aligned_model = (ALIGNED_STT_MODEL if need_aligned
                         else (request.get("alignedTranscriptModel") or ALIGNED_STT_MODEL))
        source_hash = request.get("sourceHash")
        try:
            audio_duration = _worker_cue_timing.probe_duration(audio_path) if need_aligned else None
            if isinstance(source_hash, str) and source_hash and isinstance(aligned_model, str) and aligned_model:
                segments = _load_cached_aligned_segments(request, source_hash, aligned_model)
            if segments is None:
                segments = _worker_transcript_sources.transcribe_with_daemon(audio_path, aligned_model)
                if isinstance(source_hash, str) and source_hash and isinstance(aligned_model, str) and aligned_model:
                    _store_cached_aligned_segments(request, source_hash, aligned_model, segments)
            if need_aligned:
                segments = validate_aligned_segments(segments, audio_duration)
            cues = segments_to_cues(segments)
            timing = "aligned"
        except Exception as error:  # noqa: BLE001 - a failed tier falls through
            segments = None
            _worker_reporting.progress("transcript.stt.failed", f"{type(error).__name__}: {error}")
            if need_aligned:
                if isinstance(error, WorkerError):
                    raise
                raise WorkerError("aligned-stt-unavailable", f"ad removal requires aligned speech-to-text: {type(error).__name__}: {error}") from error
    if not cues:
        _worker_reporting.progress("transcript.absent", "no published or aligned transcript")

    if ad_stage == "transcript":
        if not segments or timing != "aligned":
            raise WorkerError("aligned-stt-required", "transcript stage requires valid audio-aligned speech-to-text")
        labeller_cues_path, labeller_cues_digest = _worker_labeller_cues.write_labeller_cues(
            _worker_labeller_cues.build_labeller_cues(segments),
            Path(request.get("workDir") or tempfile.gettempdir()) / "wilted-pipeline",
        )
        return {
            "ok": True,
            "protocolVersion": PROTOCOL_VERSION,
            "adStage": "transcript",
            "timing": timing,
            "durationSeconds": audio_duration,
            "labellerCuesPath": str(labeller_cues_path),
            "labellerCuesDigest": labeller_cues_digest,
        }

    output_path, ad_spans, keeps, raw_nominations, ad_audit = audio_path, [], [], [], None
    if remove_ads:
        if not segments or timing != "aligned":
            raise WorkerError("aligned-stt-required", "ad removal requires valid audio-aligned speech-to-text")
        output_path, ad_spans, keeps, raw_nominations, ad_audit = _worker_labelled_outcome.cut_from_labelled_breaks(
            request, audio_path, cues, segments
        )
        if ad_audit and (ad_audit.get("warning") or ad_audit.get("incompleteError") or ad_audit.get("unresolvedIds")):
            if output_path.resolve() != audio_path.resolve() or ad_spans or keeps:
                raise WorkerError("ads-uncertain-output-invalid", "uncertain ad removal must retain the whole original audio")
        if (ad_audit is not None and not keeps and ad_audit.get("warning") is None
                and ad_audit.get("incompleteError") is None and not ad_audit.get("unresolvedIds")):
            # A clean no-ads result still has its long pauses trimmed. An
            # uncertain one keeps the whole original, as W-INV-013 requires.
            output_path, keeps = _worker_silence_trim.trim_unedited(
                audio_path, Path(request["outputPath"]) if request.get("outputPath") else None, audio_duration
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

    uncertain_warning = None
    if not remove_ads:
        outcome = "disabled"
    elif ad_audit and (
        ad_audit.get("warning") is not None
        or ad_audit.get("incompleteError") is not None
        or bool(ad_audit.get("unresolvedIds"))
    ):
        outcome = "uncertain"
        uncertain_warning = ad_audit.get("warning") or (
            f"original audio includes ads: {ad_audit['incompleteError']}" if ad_audit.get("incompleteError")
            else f"original audio includes ads: unresolved global IDs: {ad_audit.get('unresolvedIds')}"
        )
        output_path = audio_path
        ad_spans = []
        keeps = []
    elif ad_spans:
        outcome = "cut"
    else:
        outcome = "noAds"

    if remove_ads and (duration is None or not duration > 0 or not duration < float("inf")):
        raise WorkerError("output-duration-invalid", "ad removal output has no finite measured duration")
    if remove_ads and ad_audit is None:
        raise WorkerError("ads-audit-missing", "ad removal produced no auditable detector evidence")
    result = {
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
        "removedSeconds": round(sum(a["endSeconds"] - a["startSeconds"] for a in ad_spans), 3) if ad_spans else 0.0,
        # The pauses the map shortens. They are not ads: `adSegments` and
        # `removedSeconds` never include them, and the outcome follows the ads.
        "silenceTrims": _worker_silence_trim.silence_trim_spans(serialize_keep_map(keeps), ad_spans, audio_duration),
        # Nominations and detector evidence stay here, out of `adSegments`:
        # what was cut is the keep map's complement, and what was merely
        # proposed is review material, not a claim about the delivered audio.
        "report": {
            "outcome": outcome,
            "rawNominations": raw_nominations,
            "audit": ad_audit,
        },
    }
    if ad_stage == "cut":
        result["adStage"] = "cut"
    if uncertain_warning is not None:
        result["warning"] = uncertain_warning
        result["report"]["warning"] = uncertain_warning
    return result

TRACEBACK_TAIL_CHARS = 700


def _terminate(signum: int, frame: object) -> None:
    raise SystemExit(143)


def main() -> int:
    signal.signal(signal.SIGTERM, _terminate)
    try:
        os.setpgid(0, 0)
    except OSError:
        pass

    try:
        faulthandler.enable()
    except Exception:
        if getattr(sys, "__stderr__", None) is not None:
            with contextlib.suppress(Exception):
                faulthandler.enable(file=sys.__stderr__)

    try:
        request = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as error:
        json.dump({"ok": False, "code": "bad-request", "message": str(error)}, sys.stdout)
        return 2
    if not isinstance(request, dict):
        json.dump({"ok": False, "code": "bad-request", "message": "request must be an object"}, sys.stdout)
        return 2

    if request.get("operation") == "summary":
        from wilted_worker.transcript_summary import summary_request_id
        request_id = summary_request_id(request)
        with _worker_reporting.summary_scope(request_id):
            warnings = ForwardedWarnings()
            logging.getLogger().addHandler(warnings)
            try:
                data_dir = Path(request.get("workDir") or tempfile.gettempdir()) / "wilted-pipeline"
                data_dir.mkdir(parents=True, exist_ok=True)
                from wilted.execution_capability import execution_capability_scope
                with execution_capability_scope(owner_id="wilted-native-summary", data_dir=data_dir):
                    result = run(request)
            except WorkerError as error:
                warnings.summarize()
                json.dump({"ok": False, "operation": "summary", "protocolVersion": PROTOCOL_VERSION,
                           "requestID": request_id, "code": error.code, "message": str(error)}, sys.stdout)
                return 1
            except Exception as error:
                warnings.summarize()
                json.dump({"ok": False, "operation": "summary", "protocolVersion": PROTOCOL_VERSION,
                           "requestID": request_id, "code": "summary-failed",
                           "message": f"Local transcript summary failed ({type(error).__name__})."}, sys.stdout)
                return 1
            finally:
                logging.getLogger().removeHandler(warnings)
            warnings.summarize()
            json.dump(result, sys.stdout)
            return 0

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
    except Exception as error:  # noqa: BLE001 - structured failure reporting
        warnings.summarize()
        # The app journals the first 1,024 characters of this message, so the
        # traceback is cut to its innermost frames, where the failure is.
        frames = " ".join(traceback.format_exc().split())
        if len(frames) > TRACEBACK_TAIL_CHARS:
            frames = "…" + frames[-TRACEBACK_TAIL_CHARS:]
        message = f"{type(error).__name__}: {error} | {frames}"
        json.dump({"ok": False, "code": "worker-failed",
                   "message": message}, sys.stdout)
        return 1
    warnings.summarize()
    json.dump(result, sys.stdout)
    return 0

if __name__ == "__main__":
    sys.exit(main())
