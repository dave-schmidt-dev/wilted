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


# ---------------------------------------------------------------------------
# User settings (get_setting / set_setting)
# ---------------------------------------------------------------------------


def test_get_setting_returns_default_when_missing():
    """get_setting returns None (or custom default) for a key that does not exist."""
    from wilted.db import get_setting

    assert get_setting("nonexistent") is None
    assert get_setting("nonexistent", "fallback") == "fallback"


def test_set_and_get_setting_round_trip():
    """set_setting stores a value that get_setting retrieves."""
    from wilted.db import get_setting, set_setting

    set_setting("speed", "1.3")
    assert get_setting("speed") == "1.3"


def test_set_setting_overwrites():
    """set_setting replaces an existing value."""
    from wilted.db import get_setting, set_setting

    set_setting("speed", "1.0")
    set_setting("speed", "1.5")
    assert get_setting("speed") == "1.5"


def test_settings_do_not_collide_with_migration_meta():
    """User settings use 'setting:' prefix and do not collide with migration keys."""
    from wilted.db import _Meta, set_setting

    set_setting("speed", "1.3")
    # The raw key in _meta should be prefixed
    row = _Meta.get_by_id("setting:speed")
    assert row.value == "1.3"
    # A bare "speed" key should not exist
    with __import__("pytest").raises(_Meta.DoesNotExist):
        _Meta.get_by_id("speed")


# ---------------------------------------------------------------------------
# get_default_speed
# ---------------------------------------------------------------------------


def test_get_default_speed_from_db(monkeypatch):
    """get_default_speed returns DB-saved speed when available."""
    from wilted.db import set_setting

    set_setting("speed", "1.5")
    from wilted import get_default_speed

    assert get_default_speed() == 1.5


def test_get_default_speed_from_config(tmp_path, monkeypatch):
    """get_default_speed falls back to wilted.toml when DB has no saved speed."""
    import wilted

    config = tmp_path / "wilted.toml"
    config.write_text("[playback]\nspeed = 1.7\n")
    monkeypatch.setattr(wilted, "PROJECT_ROOT", tmp_path)
    assert wilted.get_default_speed() == 1.7


def test_get_default_speed_fallback(tmp_path, monkeypatch):
    """get_default_speed returns 1.0 when neither DB nor config has a value."""
    import wilted

    # Point PROJECT_ROOT at a dir with no wilted.toml
    monkeypatch.setattr(wilted, "PROJECT_ROOT", tmp_path)
    assert wilted.get_default_speed() == 1.0


def test_get_default_speed_clamps():
    """get_default_speed clamps to 0.5-2.0 range."""
    from wilted.db import set_setting

    set_setting("speed", "5.0")
    from wilted import get_default_speed

    assert get_default_speed() == 2.0

    set_setting("speed", "0.1")
    assert get_default_speed() == 0.5
