"""Tests for resume-position functions in wilted.playlists."""

from __future__ import annotations

from datetime import UTC, datetime

from wilted.db import Item
from wilted.playlists import clear_resume_position, get_resume_position, set_resume_position

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_item(title: str = "Resume Test Item") -> Item:
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return Item.create(
        guid=f"resume-{title}-{now}",
        title=title,
        discovered_at=now,
        item_type="article",
        status="ready",
        status_changed_at=now,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_get_returns_none_by_default():
    """get_resume_position returns None when no position has been saved."""
    item = _make_item("default-none")
    assert get_resume_position(item.id) is None


def test_get_returns_none_for_nonexistent_item():
    """get_resume_position returns None for an item ID that does not exist."""
    assert get_resume_position(999999) is None


def test_set_and_get_round_trip():
    """set then get returns the same paragraph_idx and segment_in_paragraph."""
    item = _make_item("round-trip")
    set_resume_position(item.id, paragraph_idx=42, segment_in_paragraph=3)
    result = get_resume_position(item.id)
    assert result is not None
    assert result["paragraph_idx"] == 42
    assert result["segment_in_paragraph"] == 3


def test_set_default_segment_is_zero():
    """segment_in_paragraph defaults to 0 when not supplied."""
    item = _make_item("default-segment")
    set_resume_position(item.id, paragraph_idx=10)
    result = get_resume_position(item.id)
    assert result is not None
    assert result["segment_in_paragraph"] == 0


def test_set_overwrites_existing_position():
    """Calling set twice updates rather than duplicates the resume entry."""
    item = _make_item("overwrite")
    set_resume_position(item.id, paragraph_idx=1, segment_in_paragraph=0)
    set_resume_position(item.id, paragraph_idx=99, segment_in_paragraph=5)
    result = get_resume_position(item.id)
    assert result["paragraph_idx"] == 99
    assert result["segment_in_paragraph"] == 5


def test_set_preserves_existing_metadata_keys():
    """set_resume_position does not destroy other keys already in metadata."""
    import json

    item = _make_item("preserve-meta")
    item.metadata = json.dumps({"custom_key": "custom_value", "score": 7})
    item.save()

    set_resume_position(item.id, paragraph_idx=5)

    # Reload from DB to confirm persisted state
    fresh = Item.get_by_id(item.id)
    meta = json.loads(fresh.metadata)
    assert meta["custom_key"] == "custom_value"
    assert meta["score"] == 7
    assert "resume" in meta


def test_set_stored_metadata_includes_updated_timestamp():
    """The saved resume dict contains an 'updated' ISO 8601 UTC timestamp."""
    import json

    item = _make_item("timestamp")
    set_resume_position(item.id, paragraph_idx=0)
    fresh = Item.get_by_id(item.id)
    meta = json.loads(fresh.metadata)
    updated = meta["resume"]["updated"]
    # Must be parseable as UTC ISO 8601 (ends with Z)
    assert updated.endswith("Z")
    datetime.fromisoformat(updated.replace("Z", "+00:00"))  # raises if invalid


def test_clear_removes_resume():
    """clear_resume_position removes the resume key."""
    item = _make_item("clear-resume")
    set_resume_position(item.id, paragraph_idx=20)
    assert get_resume_position(item.id) is not None

    clear_resume_position(item.id)
    assert get_resume_position(item.id) is None


def test_clear_preserves_other_metadata():
    """clear_resume_position does not touch other metadata keys."""
    import json

    item = _make_item("clear-preserve")
    item.metadata = json.dumps({"other": "data"})
    item.save()

    set_resume_position(item.id, paragraph_idx=3)
    clear_resume_position(item.id)

    fresh = Item.get_by_id(item.id)
    meta = json.loads(fresh.metadata)
    assert "resume" not in meta
    assert meta["other"] == "data"


def test_clear_noop_when_no_resume():
    """clear_resume_position on an item with no resume is a no-op."""
    item = _make_item("clear-noop")
    # Should not raise
    clear_resume_position(item.id)
    assert get_resume_position(item.id) is None


def test_clear_noop_for_nonexistent_item():
    """clear_resume_position on a non-existent item ID does not raise."""
    clear_resume_position(999999)  # must not raise
