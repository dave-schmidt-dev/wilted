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

import wilted
import wilted.ads as _ads_mod
import wilted.cache as _cache_mod
import wilted.engine as _engine_mod
import wilted.llm as _llm_mod
from wilted.db import Item
from wilted.db import now_utc as _now_utc
from wilted.download import DownloadError, download_podcast
from wilted.station_runtime.coordinator import ModelCoordinator
from wilted.transcribe import (
    TranscriptionError,
    evict_stt_model,
    get_transcript,
    save_transcript,
    segments_to_text,
)

logger = logging.getLogger(__name__)


def _set_status(item, status: str, error_message: str | None = None) -> None:
    """Update an item's status and persist to DB."""
    Item.update(
        status=status,
        status_changed_at=_now_utc(),
        error_message=error_message,
    ).where(Item.id == item.id).execute()


# ---------------------------------------------------------------------------
# Podcast preparation
# ---------------------------------------------------------------------------


def _transcribe_podcast(item, coordinator) -> list:
    """Download a podcast episode and produce its transcript (no LLM).

    Steps 1-2 of podcast preparation: download the audio and get a
    three-tier transcript, saving both audio_file and transcript_file to
    the DB. The transcript step is wrapped in ``coordinator.run_transcribe``
    so any Tier-3 GPU transcription holds the single ML lease — it can never
    overlap a resident LLM (PM-5).

    Args:
        item: A Peewee Item instance with status='processing',
            item_type='podcast_episode'.
        coordinator: A ``ModelCoordinator`` used to lease the transcribe call.

    Returns:
        The list of transcript segments (needed by :func:`_process_podcast`).
    """
    item_id = item.id
    logger.info("Preparing podcast item %d: %s", item_id, item.title)

    # Step 1: Download audio
    if not item.enclosure_url:
        _set_status(item, "error", "No enclosure URL")
        raise PrepareError(f"Item {item_id} has no enclosure_url")

    try:
        audio_path = download_podcast(item_id, item.enclosure_url)
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
    # Item.update(audio_file=...) in step 2.
    audio_path = Path(item.audio_file)

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

        req = urllib.request.Request(item.feed.feed_url)
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


def run_prepare(
    *,
    use_llm: bool = True,
    llm_model: str = "hf:google/gemma-4-E4B-it-qat-q4_0-gguf/gemma-4-E4B_q4_0-it.gguf",
    llm_backend_type: str = "gguf",
    skip_tts: bool = False,
) -> dict:
    """Process all selected items through the content preparation pipeline.

    Loads each model family once, processes all relevant items, then unloads.
    Items transition: selected → processing → ready (or error).

    Args:
        use_llm: Whether to load an LLM for ad detection and promo removal.
        llm_model: Model identifier for the LLM backend.
        llm_backend_type: Backend type ('mlx' or 'gguf').
        skip_tts: If True, skip TTS generation for articles (for testing).

    Returns:
        Dict with keys: prepared, errors, skipped.
    """
    selected_items = list(Item.select().where(Item.status == "selected").order_by(Item.discovered_at))

    if not selected_items:
        logger.info("No selected items to prepare")
        return {"prepared": 0, "errors": 0, "skipped": 0}

    logger.info("Preparing %d selected items", len(selected_items))
    start = time.monotonic()

    stats = {"prepared": 0, "errors": 0, "skipped": 0}

    podcasts = [it for it in selected_items if it.item_type == "podcast_episode"]
    articles = [it for it in selected_items if it.item_type == "article"]

    # The single ML lease shared by transcribe/LLM/TTS. Plain construction
    # (no bootstrap) matches the nightly/CLI path (weather_monitor.py,
    # briefing.py).
    coordinator = ModelCoordinator()

    # Phase A: transcribe every podcast BEFORE any LLM is loaded, so the
    # Tier-3 isolated GPU child never contends with a resident LLM (PM-5).
    # Each transcribe call holds the transcribe lease. Successfully
    # transcribed items carry their segments forward to Phase B; items that
    # fail here are counted as errors and excluded from Phase B.
    transcribed_segments: dict = {}
    for item in podcasts:
        _set_status(item, "processing")
        try:
            transcribed_segments[item.id] = _transcribe_podcast(item, coordinator)
        except PrepareError as e:
            stats["errors"] += 1
            logger.error("Item %d failed: %s", item.id, e)
        except Exception:
            stats["errors"] += 1
            _set_status(item, "error", "Unexpected error during preparation")
            logger.exception("Item %d failed unexpectedly", item.id)

    # Between phases: if tier-3 STT ran through the speech daemon, hint it to drop
    # the resident parakeet model NOW — before the LLM loads below — so the two
    # models are never co-resident in the daemon while wilted loads the LLM in this
    # process (PM-5/INV-2 hygiene). Best-effort and a no-op on the isolated backend
    # (its spawn child already exited) or if the daemon is already gone.
    evict_stt_model()

    # Phase B: load the LLM once, then process podcasts (ad detection/cutting)
    # and articles (promo removal + TTS) with it resident.
    llm_backend = None
    if use_llm:
        try:
            llm_backend = _llm_mod.create_backend(llm_backend_type, model=llm_model)
            llm_backend.load()
            logger.info("LLM backend loaded: %s", llm_model)
        except Exception:
            logger.exception("Failed to load LLM backend — continuing without it")
            llm_backend = None

    try:
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
                    # In test/dry-run mode, validate prerequisites but skip TTS
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

    finally:
        # Unload LLM backend
        if llm_backend is not None:
            try:
                llm_backend.close()
                logger.info("LLM backend unloaded")
            except Exception:
                logger.exception("Failed to unload LLM backend")

    elapsed = time.monotonic() - start
    logger.info(
        "Prepare complete: %d prepared, %d errors, %d skipped in %.1fs",
        stats["prepared"],
        stats["errors"],
        stats["skipped"],
        elapsed,
    )

    return stats
