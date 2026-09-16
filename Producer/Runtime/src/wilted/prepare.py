"""Prepare stage orchestrator — processes selected items for playback.

Handles the selected → processing → ready lifecycle for both podcast episodes
and articles. Each model family (LLM, transcription, TTS) is loaded once,
used for all relevant items, then unloaded.

Usage:
    from wilted.prepare import run_prepare
    stats = run_prepare()
    # stats = {"prepared": 3, "errors": 1, "skipped": 0}

CLI:
    wilted prepare
"""

from __future__ import annotations

import logging
import shutil
import time
from pathlib import Path
from typing import TYPE_CHECKING

import wilted
import wilted.ads as _ads_mod
import wilted.cache as _cache_mod
import wilted.engine as _engine_mod
import wilted.llm as _llm_mod
from wilted.background_work.contracts import (
    AnalysisState,
    ContentState,
    FetchState,
    PlaybackState,
    PreparationState,
    RetentionFacts,
    RetentionState,
)
from wilted.content_state import items_for_prepare, read_content_state, transition_item
from wilted.db import Item
from wilted.download import DownloadError, download_podcast
from wilted.feed_refs import FeedReferenceError, is_bws_enclosure_reference, resolve_enclosure_url, resolve_feed_url
from wilted.transcribe import (
    TranscriptionError,
    TranscriptSegment,
    evict_stt_model,
    get_transcript,
    load_transcript,
    save_transcript,
    segments_to_text,
)

if TYPE_CHECKING:
    from collections.abc import Callable

    from wilted.llm import LLMBackend
    from wilted.processing_jobs import JobCheckpoint

logger = logging.getLogger(__name__)


def _set_status(item, status: str, error_message: str | None = None) -> None:
    """Update an item's orthogonal state and persist to DB."""
    current = read_content_state(item)
    base_fetch = current.fetch if current else FetchState.CONTENT_READY
    base_analysis = current.analysis if current else AnalysisState.READY
    base_playback = current.playback if current else PlaybackState.UNPLAYED
    base_retention = current.retention if current else RetentionFacts(state=RetentionState.ACTIVE)

    if status == "processing":
        prep = PreparationState.QUEUED
        legacy = "processing"
    elif status == "ready":
        prep = PreparationState.READY
        legacy = "ready"
    elif status == "error":
        prep = PreparationState.ERROR
        legacy = "error"
    else:
        prep = PreparationState.NOT_QUEUED
        legacy = status

    transition_item(
        item,
        ContentState(
            fetch=base_fetch,
            analysis=base_analysis,
            preparation=prep,
            playback=base_playback,
            retention=base_retention,
        ),
        legacy_status=legacy,
        error_message=error_message,
    )


# ---------------------------------------------------------------------------
# Podcast preparation
# ---------------------------------------------------------------------------


# A resumed transcript is trusted only when its final segment spans at least
# this fraction of the audio's duration. Deliberately conservative (LOW): the
# gate exists to reject a *truncated* transcript (e.g. a crash mid-Tier-3 that
# still flushed a short prefix), not to demand near-total coverage. Legitimate
# transcripts routinely end well before the file's last second (trailing music,
# silence, outros), so a high threshold like 0.98 would force needless
# re-transcription of perfectly complete transcripts. Pinned by test.
_COVERAGE_TOLERANCE = 0.5


def _recompute_coverage(
    segments: list[TranscriptSegment],
    audio_file: str | None,
) -> float | None:
    """Fraction of the audio's duration spanned by the transcript's last segment.

    A coarse completeness signal for a resumed transcript: ``segments[-1].end_s
    / duration``. Returns ``None`` — meaning "indeterminable", which the caller
    treats as non-blocking — when there are no segments, no ``audio_file``, the
    file is absent on disk, or ffprobe reports a non-positive duration. The
    ffprobe probe here is blessed on the resume path only; the normal transcribe
    path already probes duration in :func:`_process_podcast`.

    Args:
        segments: Transcript segments (may be empty).
        audio_file: Path to the source audio, or ``None``.

    Returns:
        Coverage ratio in ``(0, ~1]``, or ``None`` when it cannot be computed.
    """
    if not segments or not audio_file:
        return None
    audio_path = Path(audio_file)
    if not audio_path.exists():
        return None
    try:
        duration = _engine_mod.AudioEngine().get_file_duration(audio_path)
    except Exception:
        logger.debug("Coverage: could not probe duration for %s", audio_path)
        return None
    if duration <= 0:
        return None
    return segments[-1].end_s / duration


def _transcribe_podcast(
    item,
    coordinator,
    *,
    tier3_transcribe: Callable[[Path], list[TranscriptSegment]] | None = None,
    checkpoint: JobCheckpoint | None = None,
) -> list:
    """Download a podcast episode and produce its transcript (no LLM).

    Steps 1-2 of podcast preparation: download the audio and get a
    three-tier transcript, saving both audio_file and transcript_file to
    the DB. The transcript step is wrapped in ``coordinator.run_transcribe``
    so any Tier-3 GPU transcription holds the single ML lease — it can never
    overlap a resident LLM (PM-5).

    Resume (INV-6): when ``checkpoint`` is supplied and a prior attempt of this
    job already persisted a complete transcript to the Item row (atomic save,
    S2), the download and the GPU transcribe lease are skipped entirely. The
    decision is gated on the authoritative ``item.transcript_file`` + on-disk
    transcript, never on the (non-authoritative) marker; the marker only
    supplies a cheap coverage hint. With ``checkpoint=None`` (the CLI/batch
    path) this function behaves exactly as before: no marker read, no probe.

    Args:
        item: A Peewee Item instance with status='processing',
            item_type='podcast_episode'.
        coordinator: A ``ModelCoordinator`` used to lease the transcribe call.
        tier3_transcribe: Optional Tier-3 fallback transcriber.
        checkpoint: Optional live handle for reading/recording the in-flight
            progress marker. ``None`` disables resume and marker recording.

    Returns:
        The list of transcript segments (needed by :func:`_process_podcast`).
    """
    item_id = item.id
    logger.info("Preparing podcast item %d: %s", item_id, item.title)

    # Resume fast-path (INV-6). A previous attempt of this job may have
    # atomically written a complete transcript + Item row (S2) before its lease
    # was lost. Trust that authoritative row — not the marker — and re-validate
    # word count and audio coverage before skipping the download + transcribe
    # lease. A missing/stale marker just means the coverage hint is recomputed;
    # it can never cause a wrong skip.
    if checkpoint is not None and item.transcript_file:
        segments = load_transcript(Path(item.transcript_file))
        if segments is not None and len(segments_to_text(segments).split()) == item.word_count:
            progress = checkpoint.read_progress()
            coverage = progress.get("coverage_ratio")
            if not isinstance(coverage, (int, float)):
                coverage = _recompute_coverage(segments, item.audio_file)
            if coverage is not None and coverage >= _COVERAGE_TOLERANCE:
                logger.info(
                    "Resuming item %d: complete transcript already on disk, skipping transcription",
                    item_id,
                )
                return segments
        logger.warning(
            "Item %d transcript present but failed resume validation; re-transcribing",
            item_id,
        )

    # Step 1: Download audio
    if not item.enclosure_url:
        _set_status(item, "error", "No enclosure URL")
        raise PrepareError(f"Item {item_id} has no enclosure_url")

    try:
        enclosure_url = resolve_enclosure_url(item.enclosure_url, item.feed.feed_url)
        private_enclosure = is_bws_enclosure_reference(item.enclosure_url)
        if private_enclosure:
            audio_path = download_podcast(
                item_id,
                enclosure_url,
                url_label=item.enclosure_url,
                filename_override="episode.mp3",
            )
        else:
            audio_path = download_podcast(item_id, enclosure_url)
    except FeedReferenceError:
        _set_status(
            item,
            "error",
            "Could not resolve credentialed podcast episode; run Wilted through its runtime launcher",
        )
        raise PrepareError(f"Could not resolve credentialed podcast episode for item {item_id}") from None
    except DownloadError as e:
        _set_status(item, "error", f"Download failed: {e}")
        raise PrepareError(f"Download failed for item {item_id}: {e}") from e

    # Update audio_file in DB and on the in-memory instance so Phase B's
    # _process_podcast can recover audio_path via item.audio_file (a
    # bare Item.update() does not mutate the instance).
    Item.update(audio_file=str(audio_path)).where(Item.id == item_id).execute()
    item.audio_file = str(audio_path)

    # Step 2: Get transcript (three-tier). Lease the transcribe call so the
    # Tier-3 isolated GPU child never runs while an LLM is resident (PM-5).
    try:
        segments = coordinator.run_transcribe(
            lambda: get_transcript(
                item_id=item_id,
                guid=item.guid,
                feed_xml=_get_feed_xml(item),
                episode_url=item.canonical_url or item.source_url,
                audio_path=audio_path,
                redact_feed_urls=private_enclosure,
                tier3_transcribe=tier3_transcribe,
            )
        )
    except TranscriptionError as e:
        _set_status(item, "error", f"Transcription failed: {e}")
        raise PrepareError(f"Transcription failed for item {item_id}: {e}") from e

    # Save transcript
    transcript_dir = wilted.DATA_DIR / "transcripts"
    transcript_dir.mkdir(parents=True, exist_ok=True)
    transcript_path = transcript_dir / f"{item_id}_transcript.json"
    save_transcript(segments, transcript_path)

    transcript_text = segments_to_text(segments)
    word_count = len(transcript_text.split())

    Item.update(
        transcript_file=str(transcript_path),
        word_count=word_count,
    ).where(Item.id == item_id).execute()
    item.transcript_file = str(transcript_path)
    item.word_count = word_count

    # Record a non-authoritative progress marker so a future resume attempt can
    # cheaply confirm this transcript is complete. Coverage is only probed when
    # a checkpoint is present, keeping the CLI/batch path (checkpoint=None)
    # probe-free and byte-identical to prior behavior.
    if checkpoint is not None:
        ratio = _recompute_coverage(segments, str(audio_path)) or 0.0
        checkpoint.record(
            stage="transcribed",
            word_count=word_count,
            coverage_ratio=round(ratio, 4),
        )

    return segments


def _process_podcast(item, segments, llm_backend=None) -> None:
    """Detect and cut ads for a downloaded, transcribed podcast, then probe duration.

    Steps 3-4 of podcast preparation. Runs with the LLM resident; the
    transcription (steps 1-2, :func:`_transcribe_podcast`) has already
    completed for every podcast before this is called, so no transcribe
    child overlaps the resident LLM (PM-5).

    Args:
        item: A Peewee Item instance already through :func:`_transcribe_podcast`
            (its ``audio_file`` is set).
        segments: The transcript segments returned by :func:`_transcribe_podcast`.
        llm_backend: An already-loaded LLM backend for ad detection (optional).
    """
    item_id = item.id
    # Recover the downloaded audio path saved by _transcribe_podcast's
    # Item.update(audio_file=...) in step 2. On a resume, this row was persisted
    # by an EARLIER attempt; if the audio has since been pruned from disk, fail
    # loudly (set error + raise) rather than half-prepare an item with no audio
    # (INV-6 / Fix 4). Never mark such an item "ready".
    if not item.audio_file:
        _set_status(item, "error", "No audio file on record")
        raise PrepareError(f"Item {item_id} has no audio_file")
    audio_path = Path(item.audio_file)
    if not audio_path.exists():
        _set_status(item, "error", f"Audio file missing on disk: {audio_path}")
        raise PrepareError(f"Audio file missing for item {item_id}: {audio_path}")

    # Step 3: Ad detection + cutting (if LLM backend available)
    if llm_backend and segments:
        try:
            ad_segments = _ads_mod.detect_ads(segments, llm_backend)
            if ad_segments:
                logger.info(
                    "Item %d: detected %d ad segments, cutting",
                    item_id,
                    len(ad_segments),
                )
                cleaned_path = audio_path.parent / f"cleaned_{audio_path.name}"
                _ads_mod.cut_ads(audio_path, ad_segments, cleaned_path)
                # INV-4: never replace the original with an empty/missing result.
                if not cleaned_path.exists() or cleaned_path.stat().st_size == 0:
                    logger.warning(
                        "Item %d: ad cut produced empty output, keeping original audio",
                        item_id,
                    )
                    cleaned_path.unlink(missing_ok=True)
                else:
                    # Replace original with cleaned version
                    shutil.move(str(cleaned_path), str(audio_path))
                    logger.info("Item %d: ads cut, cleaned audio saved", item_id)
            else:
                logger.info("Item %d: no ads detected", item_id)
        except Exception:
            # Ad detection/cutting is best-effort — don't fail the whole item
            logger.exception("Item %d: ad detection/cutting failed (non-fatal)", item_id)

    # Step 4: Get duration
    try:
        engine = _engine_mod.AudioEngine()
        duration = engine.get_file_duration(audio_path)
        Item.update(duration_seconds=duration).where(Item.id == item_id).execute()
    except Exception:
        logger.warning("Item %d: could not determine audio duration", item_id)


def _get_feed_xml(item) -> str | None:
    """Fetch the raw feed XML for an item's feed (for RSS transcript lookup)."""
    if not item.feed:
        return None
    try:
        import urllib.request

        req = urllib.request.Request(resolve_feed_url(item.feed.feed_url))
        import wilted

        req.add_header("User-Agent", f"Wilted/{wilted.__version__}")
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
            return resp.read().decode("utf-8", errors="replace")
    except Exception:
        logger.debug("Could not fetch feed XML for item %d", item.id)
        return None


# ---------------------------------------------------------------------------
# Article preparation
# ---------------------------------------------------------------------------


def _prepare_article(item, llm_backend=None) -> None:
    """Prepare an article: remove promos, generate TTS audio.

    Args:
        item: A Peewee Item instance with status='selected', item_type='article'.
        llm_backend: An already-loaded LLM backend for promo removal (optional).
    """
    item_id = item.id
    logger.info("Preparing article item %d: %s", item_id, item.title)

    # Read transcript text
    if not item.transcript_file:
        _set_status(item, "error", "No transcript file")
        raise PrepareError(f"Item {item_id} has no transcript_file")

    transcript_path = Path(item.transcript_file)
    if not transcript_path.exists():
        _set_status(item, "error", f"Transcript file missing: {transcript_path}")
        raise PrepareError(f"Transcript file missing for item {item_id}")

    text = transcript_path.read_text(encoding="utf-8")
    if not text.strip():
        _set_status(item, "error", "Transcript is empty")
        raise PrepareError(f"Empty transcript for item {item_id}")

    # Step 1: Remove promotional content (if LLM backend available)
    cleaned_text = text
    if llm_backend:
        try:
            cleaned_text = _ads_mod.remove_promos(text, llm_backend)
            if not cleaned_text.strip():
                # INV-4: every paragraph flagged as promo yields an empty
                # result; never overwrite the original transcript with it.
                logger.warning(
                    "Item %d: promo removal produced empty output, keeping original transcript",
                    item_id,
                )
                cleaned_text = text
            elif len(cleaned_text) < len(text):
                logger.info(
                    "Item %d: removed %d chars of promotional content",
                    item_id,
                    len(text) - len(cleaned_text),
                )
                # Save cleaned transcript back
                transcript_path.write_text(cleaned_text, encoding="utf-8")
        except Exception:
            logger.exception("Item %d: promo removal failed (non-fatal)", item_id)
            cleaned_text = text

    # Step 2: Generate TTS audio
    try:
        audio_dir = wilted.DATA_DIR / "audio" / str(item_id)
        audio_dir.mkdir(parents=True, exist_ok=True)

        engine = _engine_mod.AudioEngine()
        success = _cache_mod.generate_article_cache(
            engine,
            cleaned_text,
            item_id,
            voice=engine.voice,
            lang=engine.lang,
            speed=engine.speed,
            added=item.discovered_at,
        )

        if not success:
            _set_status(item, "error", "TTS generation cancelled or failed")
            raise PrepareError(f"TTS generation failed for item {item_id}")

        Item.update(
            audio_file=str(audio_dir),
            word_count=len(cleaned_text.split()),
        ).where(Item.id == item_id).execute()

    except PrepareError:
        raise
    except Exception as e:
        _set_status(item, "error", f"TTS generation failed: {e}")
        raise PrepareError(f"TTS generation failed for item {item_id}: {e}") from e


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


class PrepareError(RuntimeError):
    """Raised when content preparation fails for an item."""


def prepare_item(
    item: Item,
    coordinator,
    *,
    use_llm: bool = True,
    llm_model: str | None = None,
    llm_backend_type: str = "gguf",
    skip_tts: bool = False,
    backend_factory: Callable[[str, str], LLMBackend] | None = None,
    tier3_transcribe: Callable[[Path], list[TranscriptSegment]] | None = None,
    checkpoint: JobCheckpoint | None = None,
) -> bool:
    """Prepare one selected item through the content preparation pipeline.

    Args:
        item: Item row to prepare.
        coordinator: Runner-owned model coordinator for ML leasing.
        use_llm: Whether to load an LLM for ad detection and promo removal.
        llm_model: Model identifier for the LLM backend.
        llm_backend_type: Backend type ('mlx' or 'gguf').
        skip_tts: If True, skip TTS generation for articles (for testing).
        backend_factory: Factory that builds an LLM backend on demand.
        tier3_transcribe: Optional Tier-3 fallback transcriber for podcasts.
        checkpoint: Optional live progress handle enabling transcript resume
            for podcast episodes. ``None`` (CLI/batch) disables resume.

    Returns:
        True when preparation completed successfully, False otherwise.
    """
    from wilted.background_work.contracts import PlaybackState, PreparationState
    from wilted.content_state import read_content_state

    current = read_content_state(item)
    if current is not None:
        if current.preparation is PreparationState.READY:
            logger.debug("Item %d already prepared; skipping", item.id)
            return True
        if current.playback is PlaybackState.COMPLETED:
            logger.debug("Item %d already completed; skipping preparation", item.id)
            return True

    resolved_model = llm_model or _llm_mod.DEFAULT_GGUF_MODEL

    if use_llm and backend_factory is None:
        raise ValueError("use_llm requires backend_factory from a pipeline handler")

    if item.item_type == "podcast_episode":
        _set_status(item, "processing")
        try:
            segments = _transcribe_podcast(
                item,
                coordinator,
                tier3_transcribe=tier3_transcribe,
                checkpoint=checkpoint,
            )
        except PrepareError as exc:
            logger.error("Item %d failed: %s", item.id, exc)
            return False
        except Exception:
            _set_status(item, "error", "Unexpected error during preparation")
            logger.exception("Item %d failed unexpectedly", item.id)
            return False

        evict_stt_model()

        def _process_phase_b(llm_backend=None) -> None:
            _process_podcast(item, segments, llm_backend=llm_backend)
            _set_status(item, "ready")
            logger.info("Item %d prepared successfully", item.id)

        if not use_llm:
            try:
                _process_phase_b()
                return True
            except PrepareError as exc:
                logger.error("Item %d failed: %s", item.id, exc)
                return False
            except Exception:
                _set_status(item, "error", "Unexpected error during preparation")
                logger.exception("Item %d failed unexpectedly", item.id)
                return False

        try:
            backend = backend_factory(llm_backend_type, resolved_model)
        except Exception:
            logger.exception("Failed to load LLM backend — continuing without it")
            try:
                _process_phase_b()
                return True
            except PrepareError as exc:
                logger.error("Item %d failed: %s", item.id, exc)
                return False
            except Exception:
                _set_status(item, "error", "Unexpected error during preparation")
                logger.exception("Item %d failed unexpectedly", item.id)
                return False

        prepared = False

        def _process_with_loaded_llm(llm_backend) -> None:
            nonlocal prepared
            _process_phase_b(llm_backend)
            prepared = True

        try:
            coordinator.run_llm(backend, _process_with_loaded_llm)
        except Exception:
            if prepared:
                logger.exception("Failed to unload LLM backend")
                return True
            logger.exception("Failed to load LLM backend — continuing without it")
            try:
                _process_phase_b()
                return True
            except PrepareError as exc:
                logger.error("Item %d failed: %s", item.id, exc)
                return False
            except Exception:
                _set_status(item, "error", "Unexpected error during preparation")
                logger.exception("Item %d failed unexpectedly", item.id)
                return False
        return True

    if item.item_type == "article":
        _set_status(item, "processing")
        try:
            if skip_tts:
                if not item.transcript_file:
                    _set_status(item, "error", "No transcript file")
                    raise PrepareError(f"Item {item.id} has no transcript_file")
                _set_status(item, "ready")
                logger.info("Item %d prepared successfully", item.id)
                return True

            if not use_llm:
                _prepare_article(item, llm_backend=None)
                _set_status(item, "ready")
                logger.info("Item %d prepared successfully", item.id)
                return True

            try:
                backend = backend_factory(llm_backend_type, resolved_model)
            except Exception:
                logger.exception("Failed to load LLM backend — continuing without it")
                _prepare_article(item, llm_backend=None)
                _set_status(item, "ready")
                logger.info("Item %d prepared successfully", item.id)
                return True

            prepared = False

            def _prepare_with_loaded_llm(llm_backend) -> None:
                nonlocal prepared
                _prepare_article(item, llm_backend=llm_backend)
                _set_status(item, "ready")
                prepared = True
                logger.info("Item %d prepared successfully", item.id)

            try:
                coordinator.run_llm(backend, _prepare_with_loaded_llm)
            except Exception:
                if prepared:
                    logger.exception("Failed to unload LLM backend")
                    return True
                raise
            return True
        except PrepareError as exc:
            logger.error("Item %d failed: %s", item.id, exc)
            return False
        except Exception:
            _set_status(item, "error", "Unexpected error during preparation")
            logger.exception("Item %d failed unexpectedly", item.id)
            return False

    logger.warning("Item %d has unsupported item_type %r", item.id, item.item_type)
    _set_status(item, "error", f"Unsupported item type: {item.item_type}")
    return False


def run_prepare(
    *,
    coordinator,
    use_llm: bool = True,
    llm_model: str = _llm_mod.DEFAULT_GGUF_MODEL,
    llm_backend_type: str = "gguf",
    skip_tts: bool = False,
    backend_factory: Callable[[str, str], LLMBackend] | None = None,
    tier3_transcribe: Callable[[Path], list[TranscriptSegment]] | None = None,
) -> dict:
    """Process all selected items through the content preparation pipeline.

    Internal entrypoint for tests and batch helpers. Production CLI paths use
    :func:`~wilted.pipeline_submit.run_prepare_via_runner`.

    Args:
        coordinator: Runner-owned :class:`~wilted.station_runtime.coordinator.ModelCoordinator`.
        use_llm: Whether to load an LLM for ad detection and promo removal.
        llm_model: Model identifier for the LLM backend.
        llm_backend_type: Backend type ('mlx' or 'gguf').
        skip_tts: If True, skip TTS generation for articles (for testing).

    Returns:
        Dict with keys: prepared, errors, skipped.
    """
    if use_llm and backend_factory is None:
        raise ValueError("use_llm requires backend_factory from a pipeline handler")

    selected_items = items_for_prepare()

    if not selected_items:
        logger.info("No selected items to prepare")
        return {"prepared": 0, "errors": 0, "skipped": 0}

    logger.info("Preparing %d selected items", len(selected_items))
    start = time.monotonic()

    stats = {"prepared": 0, "errors": 0, "skipped": 0}

    podcasts = [it for it in selected_items if it.item_type == "podcast_episode"]
    articles = [it for it in selected_items if it.item_type == "article"]

    transcribed_segments: dict = {}
    for item in podcasts:
        _set_status(item, "processing")
        try:
            transcribed_segments[item.id] = _transcribe_podcast(
                item,
                coordinator,
                tier3_transcribe=tier3_transcribe,
            )
        except PrepareError as e:
            stats["errors"] += 1
            logger.error("Item %d failed: %s", item.id, e)
        except Exception:
            stats["errors"] += 1
            _set_status(item, "error", "Unexpected error during preparation")
            logger.exception("Item %d failed unexpectedly", item.id)

    evict_stt_model()

    def _process_phase_b(llm_backend=None) -> None:
        for item in podcasts:
            if item.id not in transcribed_segments:
                continue
            try:
                _process_podcast(item, transcribed_segments[item.id], llm_backend=llm_backend)
                _set_status(item, "ready")
                stats["prepared"] += 1
                logger.info("Item %d prepared successfully", item.id)
            except PrepareError as e:
                stats["errors"] += 1
                logger.error("Item %d failed: %s", item.id, e)
            except Exception:
                stats["errors"] += 1
                _set_status(item, "error", "Unexpected error during preparation")
                logger.exception("Item %d failed unexpectedly", item.id)

        for item in articles:
            _set_status(item, "processing")
            try:
                if skip_tts:
                    if not item.transcript_file:
                        _set_status(item, "error", "No transcript file")
                        raise PrepareError(f"Item {item.id} has no transcript_file")
                    _set_status(item, "ready")
                    stats["prepared"] += 1
                else:
                    _prepare_article(item, llm_backend=llm_backend)
                    _set_status(item, "ready")
                    stats["prepared"] += 1
                    logger.info("Item %d prepared successfully", item.id)
            except PrepareError as e:
                stats["errors"] += 1
                logger.error("Item %d failed: %s", item.id, e)
            except Exception:
                stats["errors"] += 1
                _set_status(item, "error", "Unexpected error during preparation")
                logger.exception("Item %d failed unexpectedly", item.id)

    if not use_llm:
        _process_phase_b()
    else:
        try:
            backend = backend_factory(llm_backend_type, llm_model)
        except Exception:
            logger.exception("Failed to load LLM backend — continuing without it")
            _process_phase_b()
        else:
            loaded = False
            phase_completed = False

            def _process_with_loaded_llm(llm_backend) -> None:
                nonlocal loaded, phase_completed
                loaded = True
                logger.info("LLM backend loaded: %s", llm_model)
                _process_phase_b(llm_backend)
                phase_completed = True

            try:
                coordinator.run_llm(backend, _process_with_loaded_llm)
            except Exception:
                if not loaded:
                    logger.exception("Failed to load LLM backend — continuing without it")
                    _process_phase_b()
                elif phase_completed:
                    logger.exception("Failed to unload LLM backend")
                else:
                    raise
            else:
                logger.info("LLM backend unloaded")

    elapsed = time.monotonic() - start
    logger.info(
        "Prepare complete: %d prepared, %d errors, %d skipped in %.1fs",
        stats["prepared"],
        stats["errors"],
        stats["skipped"],
        elapsed,
    )

    return stats
