"""Tests for wilted.playlists — CRUD, queries, and expiry."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from wilted.db import Item, Playlist, PlaylistItem
from wilted.playlists import (
    add_to_playlist,
    create_playlist,
    delete_playlist,
    ensure_default_playlists,
    get_playlist_items,
    list_playlists,
    remove_from_playlist,
    run_expiry,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_item(
    title: str = "Test Item",
    status: str = "ready",
    item_type: str = "article",
    playlist_assigned: str | None = None,
    playlist_override: str | None = None,
    relevance_score: float | None = None,
    keep: bool = False,
    discovered_at: str | None = None,
) -> Item:
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return Item.create(
        guid=f"test-{title}-{now}",
        title=title,
        discovered_at=discovered_at or now,
        item_type=item_type,
        status=status,
        status_changed_at=now,
        playlist_assigned=playlist_assigned,
        playlist_override=playlist_override,
        relevance_score=relevance_score,
        keep=keep,
    )


# ---------------------------------------------------------------------------
# ensure_default_playlists
# ---------------------------------------------------------------------------


class TestEnsureDefaultPlaylists:
    def test_creates_four_playlists(self):
        ensure_default_playlists()
        names = {p.name for p in Playlist.select()}
        assert names == {"All", "Work", "Fun", "Education"}

    def test_all_has_no_expiry(self):
        ensure_default_playlists()
        p = Playlist.get(Playlist.name == "All")
        assert p.expiry_days is None

    def test_work_fun_education_have_expiry_7(self):
        ensure_default_playlists()
        for name in ("Work", "Fun", "Education"):
            p = Playlist.get(Playlist.name == name)
            assert p.expiry_days == 7, f"{name} should have expiry_days=7"

    def test_all_are_dynamic(self):
        ensure_default_playlists()
        for p in Playlist.select():
            assert p.playlist_type == "dynamic"

    def test_idempotent_second_call_does_not_duplicate(self):
        ensure_default_playlists()
        ensure_default_playlists()
        assert Playlist.select().count() == 4

    def test_idempotent_preserves_user_edit(self):
        ensure_default_playlists()
        Playlist.update(expiry_days=14).where(Playlist.name == "Work").execute()
        ensure_default_playlists()
        p = Playlist.get(Playlist.name == "Work")
        assert p.expiry_days == 14


# ---------------------------------------------------------------------------
# list_playlists
# ---------------------------------------------------------------------------


class TestListPlaylists:
    def test_empty_before_any_playlists(self):
        assert list_playlists() == []

    def test_returns_all_playlists(self):
        ensure_default_playlists()
        playlists = list_playlists()
        assert len(playlists) == 4

    def test_sorted_dynamic_before_static(self):
        ensure_default_playlists()
        create_playlist("MyStatic")
        playlists = list_playlists()
        types = [p.playlist_type for p in playlists]
        # All dynamic entries must come before any static
        last_dynamic = max((i for i, t in enumerate(types) if t == "dynamic"), default=-1)
        first_static = min((i for i, t in enumerate(types) if t == "static"), default=len(types))
        assert last_dynamic < first_static

    def test_sorted_alphabetically_within_type(self):
        ensure_default_playlists()
        create_playlist("Zebra")
        create_playlist("Alpha")
        playlists = list_playlists()
        static_names = [p.name for p in playlists if p.playlist_type == "static"]
        assert static_names == sorted(static_names)


# ---------------------------------------------------------------------------
# create_playlist
# ---------------------------------------------------------------------------


class TestCreatePlaylist:
    def test_creates_static_playlist(self):
        p = create_playlist("MySaved")
        assert p.name == "MySaved"
        assert p.playlist_type == "static"

    def test_playlist_persisted(self):
        create_playlist("MySaved")
        assert Playlist.select().where(Playlist.name == "MySaved").exists()

    def test_raises_if_name_taken(self):
        create_playlist("Dupe")
        with pytest.raises(ValueError, match="already exists"):
            create_playlist("Dupe")

    def test_raises_if_dynamic_name_taken(self):
        ensure_default_playlists()
        with pytest.raises(ValueError, match="already exists"):
            create_playlist("Work")

    def test_expiry_days_is_none_for_static(self):
        p = create_playlist("NoExpiry")
        assert p.expiry_days is None


# ---------------------------------------------------------------------------
# delete_playlist
# ---------------------------------------------------------------------------


class TestDeletePlaylist:
    def test_deletes_static_playlist(self):
        create_playlist("ToDelete")
        delete_playlist("ToDelete")
        assert not Playlist.select().where(Playlist.name == "ToDelete").exists()

    def test_raises_for_missing_playlist(self):
        with pytest.raises(ValueError, match="not found"):
            delete_playlist("Ghost")

    def test_raises_for_dynamic_playlist(self):
        ensure_default_playlists()
        with pytest.raises(ValueError, match="Cannot delete dynamic"):
            delete_playlist("Work")

    def test_raises_for_all_playlist(self):
        ensure_default_playlists()
        with pytest.raises(ValueError, match="Cannot delete dynamic"):
            delete_playlist("All")


# ---------------------------------------------------------------------------
# add_to_playlist / remove_from_playlist
# ---------------------------------------------------------------------------


class TestAddToPlaylist:
    def test_adds_item_to_static_playlist(self):
        create_playlist("Saves")
        item = _make_item("Article A")
        add_to_playlist("Saves", item.id)
        assert (
            PlaylistItem.select().where(PlaylistItem.playlist_id == Playlist.get(Playlist.name == "Saves").id).count()
            == 1
        )

    def test_auto_position_starts_at_one(self):
        create_playlist("P")
        item = _make_item()
        add_to_playlist("P", item.id)
        pi = PlaylistItem.get(PlaylistItem.item == item)
        assert pi.position == 1

    def test_auto_position_increments(self):
        create_playlist("P")
        item1 = _make_item("A")
        item2 = _make_item("B")
        add_to_playlist("P", item1.id)
        add_to_playlist("P", item2.id)
        pi2 = PlaylistItem.get(PlaylistItem.item == item2)
        assert pi2.position == 2

    def test_explicit_position_respected(self):
        create_playlist("P")
        item = _make_item()
        add_to_playlist("P", item.id, position=99)
        pi = PlaylistItem.get(PlaylistItem.item == item)
        assert pi.position == 99

    def test_raises_for_dynamic_playlist(self):
        ensure_default_playlists()
        item = _make_item()
        with pytest.raises(ValueError, match="Cannot manually add"):
            add_to_playlist("Work", item.id)

    def test_raises_for_missing_playlist(self):
        item = _make_item()
        with pytest.raises(ValueError, match="not found"):
            add_to_playlist("NoSuchPlaylist", item.id)


class TestRemoveFromPlaylist:
    def test_removes_item(self):
        create_playlist("P")
        item = _make_item()
        add_to_playlist("P", item.id)
        remove_from_playlist("P", item.id)
        assert PlaylistItem.select().count() == 0

    def test_no_error_if_item_not_in_playlist(self):
        create_playlist("P")
        item = _make_item()
        # Should not raise
        remove_from_playlist("P", item.id)

    def test_raises_for_missing_playlist(self):
        item = _make_item()
        with pytest.raises(ValueError, match="not found"):
            remove_from_playlist("NoSuchPlaylist", item.id)

    def test_only_removes_target_item(self):
        create_playlist("P")
        item1 = _make_item("A")
        item2 = _make_item("B")
        add_to_playlist("P", item1.id)
        add_to_playlist("P", item2.id)
        remove_from_playlist("P", item1.id)
        remaining = PlaylistItem.select().count()
        assert remaining == 1
        pi = PlaylistItem.get()
        assert pi.item_id == item2.id


# ---------------------------------------------------------------------------
# get_playlist_items
# ---------------------------------------------------------------------------


class TestGetPlaylistItemsAll:
    def test_returns_empty_when_no_items(self):
        ensure_default_playlists()
        assert get_playlist_items("All") == []

    def test_includes_ready_items(self):
        ensure_default_playlists()
        _make_item("R", status="ready")
        items = get_playlist_items("All")
        assert len(items) == 1

    def test_includes_selected_items(self):
        ensure_default_playlists()
        _make_item("S", status="selected")
        items = get_playlist_items("All")
        assert len(items) == 1

    def test_excludes_completed_items(self):
        ensure_default_playlists()
        _make_item("C", status="completed")
        assert get_playlist_items("All") == []

    def test_excludes_expired_items(self):
        ensure_default_playlists()
        _make_item("E", status="expired")
        assert get_playlist_items("All") == []

    def test_sorted_oldest_first(self):
        ensure_default_playlists()
        old = (datetime.now(UTC) - timedelta(days=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
        new = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        _make_item("New", discovered_at=new)
        _make_item("Old", discovered_at=old)
        items = get_playlist_items("All")
        assert items[0]["title"] == "Old"
        assert items[1]["title"] == "New"

    def test_raises_for_missing_playlist(self):
        with pytest.raises(ValueError, match="not found"):
            get_playlist_items("Ghost")

    def test_dict_has_expected_keys(self):
        ensure_default_playlists()
        _make_item("Check")
        items = get_playlist_items("All")
        expected_keys = {
            "id",
            "title",
            "words",
            "source_url",
            "canonical_url",
            "file",
            "added",
            "audio_file",
            "status",
            "playlist_assigned",
            "playlist_override",
            "relevance_score",
            "summary",
            "item_type",
            "keep",
        }
        assert expected_keys.issubset(set(items[0].keys()))


class TestGetPlaylistItemsDynamic:
    def test_returns_items_by_assigned(self):
        ensure_default_playlists()
        _make_item("W", playlist_assigned="Work")
        items = get_playlist_items("Work")
        assert len(items) == 1
        assert items[0]["title"] == "W"

    def test_override_takes_precedence_over_assigned(self):
        ensure_default_playlists()
        # assigned=Work but override=Fun → should appear in Fun, not Work
        _make_item("Overridden", playlist_assigned="Work", playlist_override="Fun")
        assert len(get_playlist_items("Work")) == 0
        assert len(get_playlist_items("Fun")) == 1

    def test_excludes_wrong_playlist(self):
        ensure_default_playlists()
        _make_item("E", playlist_assigned="Education")
        assert get_playlist_items("Work") == []
        assert get_playlist_items("Fun") == []

    def test_excludes_non_ready_items(self):
        ensure_default_playlists()
        _make_item("Done", status="completed", playlist_assigned="Work")
        assert get_playlist_items("Work") == []

    def test_sorted_by_relevance_desc(self):
        ensure_default_playlists()
        _make_item("LowRel", playlist_assigned="Work", relevance_score=1.0)
        _make_item("HighRel", playlist_assigned="Work", relevance_score=9.0)
        items = get_playlist_items("Work")
        assert items[0]["title"] == "HighRel"
        assert items[1]["title"] == "LowRel"

    def test_selected_status_included(self):
        ensure_default_playlists()
        _make_item("Sel", status="selected", playlist_assigned="Fun")
        assert len(get_playlist_items("Fun")) == 1


class TestGetPlaylistItemsStatic:
    def test_returns_items_in_position_order(self):
        create_playlist("P")
        item1 = _make_item("First")
        item2 = _make_item("Second")
        item3 = _make_item("Third")
        add_to_playlist("P", item3.id, position=3)
        add_to_playlist("P", item1.id, position=1)
        add_to_playlist("P", item2.id, position=2)
        items = get_playlist_items("P")
        assert [i["title"] for i in items] == ["First", "Second", "Third"]

    def test_returns_empty_for_empty_static_playlist(self):
        create_playlist("Empty")
        assert get_playlist_items("Empty") == []

    def test_only_returns_playlist_members(self):
        create_playlist("P1")
        create_playlist("P2")
        item1 = _make_item("In P1")
        item2 = _make_item("In P2")
        add_to_playlist("P1", item1.id)
        add_to_playlist("P2", item2.id)
        items = get_playlist_items("P1")
        assert len(items) == 1
        assert items[0]["title"] == "In P1"


# ---------------------------------------------------------------------------
# run_expiry
# ---------------------------------------------------------------------------


class TestRunExpiry:
    def _old_ts(self, days: int = 10) -> str:
        return (datetime.now(UTC) - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")

    def test_returns_zero_when_no_items(self):
        ensure_default_playlists()
        assert run_expiry() == 0

    def test_expires_old_item(self):
        ensure_default_playlists()
        item = _make_item("Old", playlist_assigned="Work", discovered_at=self._old_ts(10))
        count = run_expiry()
        assert count == 1
        item_fresh = Item.get_by_id(item.id)
        assert item_fresh.status == "expired"

    def test_does_not_expire_recent_item(self):
        ensure_default_playlists()
        _make_item("New", playlist_assigned="Work", discovered_at=self._old_ts(3))
        assert run_expiry() == 0

    def test_does_not_expire_kept_item(self):
        ensure_default_playlists()
        _make_item("Kept", playlist_assigned="Work", keep=True, discovered_at=self._old_ts(10))
        assert run_expiry() == 0

    def test_does_not_expire_all_playlist(self):
        """'All' has expiry_days=None and must never be processed."""
        ensure_default_playlists()
        # An item with no assigned playlist still appears in "All"
        _make_item("NoPlaylist", discovered_at=self._old_ts(100))
        assert run_expiry() == 0

    def test_expiry_only_affects_ready_and_selected(self):
        ensure_default_playlists()
        _make_item("Done", status="completed", playlist_assigned="Work", discovered_at=self._old_ts(10))
        assert run_expiry() == 0

    def test_returns_count_of_expired_items(self):
        ensure_default_playlists()
        for i in range(3):
            _make_item(f"Item{i}", playlist_assigned="Education", discovered_at=self._old_ts(10))
        count = run_expiry()
        assert count == 3

    def test_expiry_via_override_field(self):
        """Items whose playlist_override maps to a dynamic playlist are expired."""
        ensure_default_playlists()
        item = _make_item(
            "Override",
            playlist_assigned="Fun",
            playlist_override="Work",
            discovered_at=self._old_ts(10),
        )
        count = run_expiry()
        assert count == 1
        assert Item.get_by_id(item.id).status == "expired"
