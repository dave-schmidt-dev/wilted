"""Durable compact-briefing artifacts for runner → TUI handoff (Task 5.2).

The runner publishes finalized briefing media here. The next lease-holding TUI
adopts the newest valid owed artifact through ``StationController.submit`` —
the runner never writes station state.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path  # noqa: TC003 — used at runtime for artifact I/O
from typing import TYPE_CHECKING

import wilted

if TYPE_CHECKING:
    from wilted.station_runtime.briefing import Briefing, WeatherSnapshot

logger = logging.getLogger(__name__)

_MANIFEST_NAME = "manifest.json"
_AUDIO_NAME = "briefing.wav"


@dataclass(frozen=True, slots=True)
class BriefingArtifactRef:
    """Pointer to one persisted briefing artifact on disk."""

    artifact_id: str
    manifest_path: Path
    audio_path: Path
    generated_at: datetime
    max_age_s: float
    adopted_at: str | None


def briefing_artifacts_dir() -> Path:
    """Return the root directory for durable briefing artifacts."""
    return wilted.DATA_DIR / "briefings"


def _artifact_dir(artifact_id: str) -> Path:
    return briefing_artifacts_dir() / artifact_id


def persist_briefing_artifact(
    briefing: Briefing,
    *,
    window_start: str,
    window_end: str,
) -> str:
    """Write one briefing artifact and return its stable artifact id.

    Args:
        briefing: Freshly generated briefing including synth output.
        window_start: Idempotency window start (local date or ISO timestamp).
        window_end: Idempotency window end.

    Returns:
        Artifact directory name (``{window_start}_{window_end}``).
    """
    artifact_id = f"{window_start}_{window_end}"
    target = _artifact_dir(artifact_id)
    target.mkdir(parents=True, exist_ok=True)

    audio = briefing.synth_result
    if audio is None or not getattr(audio, "audio_bytes", b""):
        raise ValueError("briefing synth_result must include audio bytes")

    audio_path = target / _AUDIO_NAME
    audio_path.write_bytes(audio.audio_bytes)

    manifest = {
        "artifact_id": artifact_id,
        "window_start": window_start,
        "window_end": window_end,
        "generated_at": briefing.generated_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "max_age_s": briefing.max_age_s,
        "max_duration_s": briefing.max_duration_s,
        "script": briefing.script,
        "word_count": briefing.word_count,
        "estimated_duration_s": briefing.estimated_duration_s,
        "adopted_at": None,
        "items": [
            {
                "item_id": item.item_id,
                "title": item.title,
                "summary": item.summary,
                "source_name": item.source_name,
                "relevance_score": item.relevance_score,
                "playlist": item.playlist,
            }
            for item in briefing.items
        ],
        "weather": _weather_to_dict(briefing.weather),
        "audio": {
            "path": _AUDIO_NAME,
            "duration_ms": audio.duration_ms,
            "byte_size": len(audio.audio_bytes),
        },
    }
    manifest_path = target / _MANIFEST_NAME
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    logger.info("Persisted briefing artifact %s at %s", artifact_id, target)
    return artifact_id


def _weather_to_dict(weather: WeatherSnapshot | None) -> dict | None:
    if weather is None:
        return None
    return {
        "period_name": weather.period_name,
        "short_forecast": weather.short_forecast,
        "temperature": weather.temperature,
        "temperature_unit": weather.temperature_unit,
    }


def _parse_generated_at(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value).astimezone(UTC)


def _load_ref(manifest_path: Path) -> BriefingArtifactRef | None:
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    artifact_id = payload.get("artifact_id")
    generated_at = payload.get("generated_at")
    max_age_s = payload.get("max_age_s")
    if not artifact_id or not generated_at or max_age_s is None:
        return None
    audio_name = payload.get("audio", {}).get("path", _AUDIO_NAME)
    audio_path = manifest_path.parent / str(audio_name)
    if not audio_path.is_file():
        return None
    return BriefingArtifactRef(
        artifact_id=str(artifact_id),
        manifest_path=manifest_path,
        audio_path=audio_path,
        generated_at=_parse_generated_at(str(generated_at)),
        max_age_s=float(max_age_s),
        adopted_at=payload.get("adopted_at"),
    )


def load_newest_owed_briefing(*, now: datetime | None = None) -> BriefingArtifactRef | None:
    """Return the newest unadopted, non-stale briefing artifact if any."""
    root = briefing_artifacts_dir()
    if not root.is_dir():
        return None

    resolved_now = now if now is not None else datetime.now(UTC)
    candidates: list[BriefingArtifactRef] = []
    for manifest_path in root.glob("*/manifest.json"):
        ref = _load_ref(manifest_path)
        if ref is None or ref.adopted_at is not None:
            continue
        age_s = (resolved_now - ref.generated_at).total_seconds()
        if age_s > ref.max_age_s:
            continue
        candidates.append(ref)

    if not candidates:
        return None
    return max(candidates, key=lambda ref: ref.generated_at)


def load_briefing_from_artifact(ref: BriefingArtifactRef) -> Briefing:
    """Reconstruct a :class:`Briefing` from a persisted artifact."""
    from wilted.station_runtime.briefing import Briefing, BriefingAudio, BriefingItem, WeatherSnapshot

    payload = json.loads(ref.manifest_path.read_text(encoding="utf-8"))
    audio_bytes = ref.audio_path.read_bytes()
    audio_meta = payload.get("audio", {})
    synth_result = BriefingAudio(
        audio_bytes=audio_bytes,
        duration_ms=int(audio_meta.get("duration_ms", 0)),
    )

    weather_payload = payload.get("weather")
    weather: WeatherSnapshot | None = None
    if isinstance(weather_payload, dict):
        weather = WeatherSnapshot(
            period_name=weather_payload.get("period_name"),
            short_forecast=str(weather_payload.get("short_forecast", "")),
            temperature=weather_payload.get("temperature"),
            temperature_unit=weather_payload.get("temperature_unit"),
        )

    items = tuple(
        BriefingItem(
            item_id=str(row["item_id"]),
            title=str(row["title"]),
            summary=row.get("summary"),
            source_name=row.get("source_name"),
            relevance_score=row.get("relevance_score"),
            playlist=row.get("playlist"),
        )
        for row in payload.get("items", [])
    )

    return Briefing(
        generated_at=ref.generated_at,
        max_age_s=float(payload.get("max_age_s", ref.max_age_s)),
        max_duration_s=float(payload.get("max_duration_s", 300.0)),
        items=items,
        weather=weather,
        script=str(payload.get("script", "")),
        word_count=int(payload.get("word_count", 0)),
        estimated_duration_s=float(payload.get("estimated_duration_s", 0.0)),
        synth_result=synth_result,
    )


def mark_briefing_adopted(artifact_id: str, *, adopted_at: str | None = None) -> None:
    """Record that the TUI adopted one briefing artifact into station state."""
    manifest_path = _artifact_dir(artifact_id) / _MANIFEST_NAME
    if not manifest_path.is_file():
        raise FileNotFoundError(f"briefing artifact manifest not found: {artifact_id}")
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    payload["adopted_at"] = adopted_at or datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
