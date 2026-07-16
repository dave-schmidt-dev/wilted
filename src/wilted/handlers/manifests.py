"""Artifact manifest builders for pipeline stage handlers."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import TYPE_CHECKING

from wilted.background_work.contracts import ArtifactManifest

if TYPE_CHECKING:
    from wilted.db import Item


def _sha256_hex(payload: str) -> str:
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def classify_input_digest(item: Item) -> str:
    """Canonical digest of classify handler inputs for one item."""
    parts: list[str] = [str(item.id), item.guid or "", item.title or ""]
    if item.transcript_file:
        path = Path(item.transcript_file)
        if path.exists():
            parts.append(path.read_text(encoding="utf-8")[:8000])
    return _sha256_hex("|".join(parts))


def classify_output_digest(item: Item) -> str:
    """Digest of classification outputs persisted on the item row."""
    payload = {
        "playlist": item.playlist_assigned,
        "relevance_score": item.relevance_score,
        "summary": item.summary,
    }
    return _sha256_hex(json.dumps(payload, sort_keys=True, separators=(",", ":")))


def build_classify_manifest(item: Item, *, operation_version: int) -> ArtifactManifest:
    """Build a completion manifest after classify handler work."""
    return ArtifactManifest(
        item_id=str(item.id),
        input_digest=classify_input_digest(item),
        operation_version=operation_version,
        output_digests=(classify_output_digest(item),),
        completeness_checks=("analysis_state_ready",),
    )


def prepare_input_digest(item: Item) -> str:
    """Canonical digest of prepare handler inputs for one item."""
    parts: list[str] = [str(item.id), item.item_type or "", item.guid or ""]
    if item.transcript_file:
        path = Path(item.transcript_file)
        if path.exists():
            parts.append(path.read_text(encoding="utf-8")[:8000])
    if item.enclosure_url:
        parts.append(item.enclosure_url)
    return _sha256_hex("|".join(parts))


def prepare_output_digest(item: Item) -> str:
    """Digest of preparation outputs persisted on the item row."""
    payload = {
        "audio_file": item.audio_file,
        "transcript_file": item.transcript_file,
        "word_count": item.word_count,
        "duration_seconds": item.duration_seconds,
    }
    return _sha256_hex(json.dumps(payload, sort_keys=True, separators=(",", ":")))


def build_prepare_manifest(item: Item, *, operation_version: int) -> ArtifactManifest:
    """Build a completion manifest after prepare handler work."""
    return ArtifactManifest(
        item_id=str(item.id),
        input_digest=prepare_input_digest(item),
        operation_version=operation_version,
        output_digests=(prepare_output_digest(item),),
        completeness_checks=("preparation_state_ready",),
    )


def build_discover_manifest(
    *,
    feed_id: int,
    operation_version: int,
    stats: dict[str, int],
) -> ArtifactManifest:
    """Build a completion manifest after one feed poll."""
    payload = {"feed_id": feed_id, **stats}
    digest = _sha256_hex(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    return ArtifactManifest(
        item_id=str(feed_id),
        input_digest=digest,
        operation_version=operation_version,
        output_digests=(digest,),
        completeness_checks=("feed_polled",),
    )


def build_report_manifest(
    *,
    report_id: int,
    report_date: str,
    operation_version: int,
    item_count: int,
) -> ArtifactManifest:
    """Build a completion manifest after report assembly."""
    payload = {"report_id": report_id, "report_date": report_date, "item_count": item_count}
    digest = _sha256_hex(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    return ArtifactManifest(
        item_id=str(report_id),
        input_digest=digest,
        operation_version=operation_version,
        output_digests=(digest,),
        completeness_checks=("report_snapshot",),
    )


def build_briefing_manifest(
    *,
    artifact_id: str,
    operation_version: int,
    word_count: int,
) -> ArtifactManifest:
    """Build a completion manifest after compact briefing generation."""
    payload = {"artifact_id": artifact_id, "word_count": word_count}
    digest = _sha256_hex(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    return ArtifactManifest(
        item_id=artifact_id,
        input_digest=digest,
        operation_version=operation_version,
        output_digests=(digest,),
        completeness_checks=("briefing_artifact",),
    )
