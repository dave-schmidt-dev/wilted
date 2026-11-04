"""Pure validation and envelope construction for feed ad profiles."""
from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from typing import Any

SCHEMA_VERSION: int = 1
MAX_PAYLOAD_BYTES: int = 8192
MAX_SLOTS: int = 12
MAX_PHRASES_PER_LIST: int = 8
MAX_PHRASE_LENGTH: int = 120
MAX_FEED_ID_LENGTH: int = 256
MAX_SAMPLE_COUNT: int = 20
MIN_SAMPLE_COUNT: int = 1
VALID_POSITIONS: frozenset[str] = frozenset({"pre", "mid", "post"})

_HEX64_RE = re.compile(r"^[0-9a-f]{64}$")

ENVELOPE_KEYS: frozenset[str] = frozenset({"payload", "digest"})
PAYLOAD_KEYS: frozenset[str] = frozenset({"schemaVersion", "feedID", "revision", "sampleCount", "slots"})
SLOT_KEYS: frozenset[str] = frozenset({"position", "startBasisPoints", "endBasisPoints", "entryPhrases", "returnPhrases"})
OBSERVATION_KEYS: frozenset[str] = frozenset({"schemaVersion", "feedID", "episodeID", "sourceHash", "slots"})


def _is_int(val: Any) -> bool:
    """Return True if val is a strict integer, excluding bool."""
    return isinstance(val, int) and not isinstance(val, bool)


def _validate_phrase(phrase: Any) -> bool:
    """Validate that phrase is a non-empty literal string <= 120 chars without addresses or control characters."""
    if not isinstance(phrase, str):
        return False
    if len(phrase) == 0 or len(phrase) > MAX_PHRASE_LENGTH:
        return False
    if any(unicodedata.category(character) in {"Cc", "Cs"} for character in phrase):
        return False
    if not phrase.strip():
        return False
    # Markers are literal data, never regex or model instructions. Avoid storing
    # addresses; semantic words such as "terms" or "episode" are valid speech.
    if "://" in phrase or "www." in phrase.casefold():
        return False
    return True


def _validate_phrases(phrases: Any) -> bool:
    """Validate a list of up to 8 literal phrases."""
    if not isinstance(phrases, list):
        return False
    if len(phrases) > MAX_PHRASES_PER_LIST:
        return False
    for p in phrases:
        if not _validate_phrase(p):
            return False
    return True


def _validate_slot(slot: Any) -> bool:
    """Validate a single slot dictionary against the frozen wire v1 schema."""
    if not isinstance(slot, dict):
        return False
    if set(slot.keys()) != SLOT_KEYS:
        return False
    pos = slot["position"]
    if not isinstance(pos, str) or pos not in VALID_POSITIONS:
        return False
    start = slot["startBasisPoints"]
    if not _is_int(start) or not (0 <= start <= 10000):
        return False
    end = slot["endBasisPoints"]
    if not _is_int(end) or not (0 <= end <= 10000):
        return False
    if start >= end:
        return False
    if not _validate_phrases(slot["entryPhrases"]):
        return False
    if not _validate_phrases(slot["returnPhrases"]):
        return False
    return True


def _validate_payload_dict(payload: Any) -> bool:
    """Validate a payload dictionary against the frozen wire v1 schema."""
    if not isinstance(payload, dict):
        return False
    if set(payload.keys()) != PAYLOAD_KEYS:
        return False
    if not _is_int(payload["schemaVersion"]) or payload["schemaVersion"] != SCHEMA_VERSION:
        return False
    feed_id = payload["feedID"]
    if not isinstance(feed_id, str) or len(feed_id) < 1 or len(feed_id) > MAX_FEED_ID_LENGTH:
        return False
    rev = payload["revision"]
    if not _is_int(rev) or rev < 1:
        return False
    sample_count = payload["sampleCount"]
    if not _is_int(sample_count) or not (MIN_SAMPLE_COUNT <= sample_count <= MAX_SAMPLE_COUNT):
        return False
    slots = payload["slots"]
    if not isinstance(slots, list) or len(slots) > MAX_SLOTS:
        return False
    for slot in slots:
        if not _validate_slot(slot):
            return False
    return True


def validate_profile(envelope: Any, feed_id: Any) -> dict[str, Any] | None:
    """Validate a profile envelope for feed_id, returning the payload dict or None."""
    if not isinstance(envelope, dict):
        return None
    if not isinstance(feed_id, str) or len(feed_id) < 1 or len(feed_id) > MAX_FEED_ID_LENGTH:
        return None
    if set(envelope.keys()) != ENVELOPE_KEYS:
        return None
    payload_str = envelope["payload"]
    digest = envelope["digest"]
    if not isinstance(payload_str, str) or not isinstance(digest, str):
        return None
    if not _HEX64_RE.fullmatch(digest):
        return None
    try:
        payload_bytes = payload_str.encode("utf-8")
    except UnicodeError:
        return None
    if len(payload_bytes) > MAX_PAYLOAD_BYTES:
        return None
    computed_digest = hashlib.sha256(payload_bytes).hexdigest()
    if computed_digest != digest:
        return None
    try:
        payload_obj = json.loads(payload_str)
    except Exception:
        return None
    if not _validate_payload_dict(payload_obj):
        return None
    if payload_obj["feedID"] != feed_id:
        return None
    return payload_obj


def profile_envelope(payload_dict: Any) -> dict[str, str]:
    """Construct a digest-bound envelope for a valid payload dictionary, or raise ValueError."""
    if not _validate_payload_dict(payload_dict):
        raise ValueError("Invalid profile payload dictionary")
    serialized = json.dumps(payload_dict, separators=(",", ":"), ensure_ascii=False)
    raw_bytes = serialized.encode("utf-8")
    if len(raw_bytes) > MAX_PAYLOAD_BYTES:
        raise ValueError(
            f"Payload UTF-8 byte count {len(raw_bytes)} exceeds limit {MAX_PAYLOAD_BYTES}"
        )
    digest = hashlib.sha256(raw_bytes).hexdigest()
    return {"payload": serialized, "digest": digest}


def validate_observation(
    value: Any, feed_id: Any, episode_id: Any, source_hash: Any
) -> dict[str, Any] | None:
    """Validate an independent observation or return None."""
    if not isinstance(feed_id, str) or len(feed_id) < 1 or len(feed_id) > MAX_FEED_ID_LENGTH:
        return None
    if not isinstance(episode_id, str) or len(episode_id) < 1 or len(episode_id) > MAX_FEED_ID_LENGTH:
        return None
    if not isinstance(source_hash, str) or not _HEX64_RE.fullmatch(source_hash):
        return None

    if isinstance(value, str):
        try:
            raw_bytes = value.encode("utf-8")
        except UnicodeError:
            return None
        if len(raw_bytes) > MAX_PAYLOAD_BYTES:
            return None
        try:
            obs = json.loads(value)
        except Exception:
            return None
    elif isinstance(value, dict):
        obs = value
        try:
            raw_bytes = json.dumps(obs, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            if len(raw_bytes) > MAX_PAYLOAD_BYTES:
                return None
        except Exception:
            return None
    else:
        return None

    if not isinstance(obs, dict):
        return None
    if set(obs.keys()) != OBSERVATION_KEYS:
        return None
    if not _is_int(obs["schemaVersion"]) or obs["schemaVersion"] != SCHEMA_VERSION:
        return None
    if obs["feedID"] != feed_id:
        return None
    if obs["episodeID"] != episode_id:
        return None
    if obs["sourceHash"] != source_hash:
        return None
    slots = obs["slots"]
    if not isinstance(slots, list) or len(slots) > MAX_SLOTS:
        return None
    for slot in slots:
        if not _validate_slot(slot):
            return None
    return obs
