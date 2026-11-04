"""Live-equivalent model replay for the private ad corpus."""
from __future__ import annotations

import contextlib
import sys
from pathlib import Path


def replay_analysis(
    case: dict,
    *,
    cache: Path,
    store: Path | None = None,
    remove_self_promotion: bool = False,
    ad_profile: dict | None = None,
    feed_id: str | None = None,
    episode_id: str | None = None,
):
    """Run the same ad-analysis entry as preparation and return its observation."""
    import ad_corpus as corpus

    resolved_store = store if store is not None else corpus.DEFAULT_AD_CORPUS_INPUTS
    segments, _source = corpus.case_segments(case, store=resolved_store, cache=cache)
    if segments is None:
        return None
    sources = corpus.runtime_sources()
    if not (sources / "wilted" / "ads.py").is_file():
        raise RuntimeError(
            f"no Wilted runtime source under {sources}; restore Producer/Runtime/src "
            "from the repository or set WILTED_PIPELINE_PYTHONPATH to a runtime src directory"
        )
    sys.path.insert(0, str(sources))
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import wilted_pipeline as wp  # noqa: PLC0415 - deferred; loading it is expensive
    from wilted import ads as ads_module  # noqa: PLC0415
    from wilted import llm as llm_module  # noqa: PLC0415

    aligned = [
        wp.CachedAlignedSegment(
            text=segment["text"], start_s=float(segment["start_s"]), end_s=float(segment["end_s"]),
        )
        for segment in segments
    ]
    total = float(case["audioDurationSeconds"])
    source_hash = case.get("sourceHash")
    resolved_episode_id = episode_id or str(case["id"])
    profile_payload = None
    profile_digest = None
    if ad_profile is not None:
        from wilted_worker.feed_profiles import validate_profile  # noqa: PLC0415
        profile_digest = ad_profile.get("digest") if isinstance(ad_profile, dict) else None
        profile_payload = validate_profile(ad_profile, feed_id)
    model = str(llm_module.DEFAULT_GGUF_MODEL)
    from wilted.execution_capability import execution_capability_scope  # noqa: PLC0415

    analyze_ad_detections, prepare_ad_model_lock = corpus._replay_worker_functions()
    lock = prepare_ad_model_lock(model, aligned_stt=False)
    with execution_capability_scope(owner_id="wilted-ad-corpus-replay", data_dir=cache.parent), \
            (lock or contextlib.nullcontext()):
        backend = llm_module.create_backend("gguf", model=model)
        backend.load()
        try:
            profile_kwargs = {}
            if ad_profile is not None:
                profile_kwargs.update(
                    ad_profile=profile_payload,
                    ad_profile_digest=profile_digest,
                    ad_profile_status=("invalid" if profile_payload is None else "applied"),
                )
            if feed_id:
                profile_kwargs.update(
                    feed_id=feed_id, episode_id=resolved_episode_id, source_hash=source_hash,
                )
            if remove_self_promotion:
                analysis = analyze_ad_detections(
                    ads_module, backend, aligned, total, remove_self_promotion=True, **profile_kwargs,
                )
            else:
                analysis = analyze_ad_detections(
                    ads_module, backend, aligned, total, **profile_kwargs,
                )
        except wp.WorkerError as error:
            raise corpus.ReplayRefused(error.code, str(error)) from error
        finally:
            backend.close()

    from wilted_worker.ad_outcome import decide_ad_outcome  # noqa: PLC0415
    detections = list(analysis.detections)
    outcome = decide_ad_outcome(analysis.audit, detections)
    if outcome.keep_whole_reason is not None:
        analysis.audit.incomplete_error = outcome.keep_whole_reason
        analysis.audit.warning = f"original audio includes ads: {outcome.keep_whole_reason}"
        detections = []
    return (
        [corpus.Span(float(ad.start_s), float(ad.end_s)) for ad in detections],
        wp.serialize_ad_audit(analysis.audit),
        analysis.audit.ad_profile_observation,
    )
