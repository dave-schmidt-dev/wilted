"""Guard and equivalence tests for orthogonal production query cutover (Task 2.3)."""

from __future__ import annotations

import ast
from pathlib import Path

from wilted.background_work.contracts import (
    AnalysisState,
    FetchState,
    PreparationState,
)
from wilted.content_state import (
    backfill_orthogonal_from_legacy,
    items_for_playlist_all,
    items_for_prepare,
    items_for_report,
    items_pending_classification,
    items_playable_in_queue,
    items_playable_ready_only,
)
from wilted.db import Item, now_utc
from wilted.discover import _process_entry
from wilted.queue import load_queue, remove_article

_SRC_ROOT = Path(__file__).resolve().parent.parent / "src" / "wilted"
_ALLOWLIST = frozenset(
    {
        _SRC_ROOT / "db.py",
        _SRC_ROOT / "legacy_cutover.py",
        _SRC_ROOT / "content_state.py",
    }
)


def _make_parsed_entry(**kwargs):
    defaults = {
        "title": "Test Article",
        "id": "guid-123",
        "link": "https://example.com/article-1",
        "published_parsed": None,
        "author": "Test Author",
        "summary": "Article summary text for testing.",
        "enclosures": [],
        "links": [],
        "content": [],
    }
    defaults.update(kwargs)
    return defaults


def _seed_item(**kwargs) -> Item:
    defaults = dict(
        feed=None,
        guid=f"guid-{kwargs.get('title', 'test')}",
        title="Test Article",
        discovered_at=now_utc(),
        item_type="article",
        status="ready",
        status_changed_at=now_utc(),
    )
    defaults.update(kwargs)
    item = Item.create(**defaults)
    if item.fetch_state is None:
        backfill_orthogonal_from_legacy(item)
    return Item.get_by_id(item.id)


class TestNoItemStatusInProductionModules:
    def test_ast_scan_no_item_status_outside_allowlist(self):
        offenders: list[str] = []
        for path in sorted(_SRC_ROOT.rglob("*.py")):
            if path in _ALLOWLIST:
                continue
            source = path.read_text(encoding="utf-8")
            tree = ast.parse(source, filename=str(path))
            for node in ast.walk(tree):
                if not isinstance(node, ast.Attribute):
                    continue
                if isinstance(node.value, ast.Name) and node.value.id == "Item" and node.attr == "status":
                    offenders.append(f"{path.relative_to(_SRC_ROOT.parent.parent)}:{node.lineno}")

        assert offenders == [], "Item.status references outside allowlist:\n" + "\n".join(offenders)


class TestQueryEquivalence:
    def test_pending_classification_cohort(self):
        pending = _seed_item(status="fetched", title="Fetched")
        classified = _seed_item(status="classified", title="Classified")

        ids = {item.id for item in items_pending_classification()}
        assert pending.id in ids
        assert classified.id not in ids

    def test_report_candidate_cohort(self):
        classified = _seed_item(status="classified", title="Classified")
        selected = _seed_item(status="selected", title="Selected")

        ids = {item.id for item in items_for_report()}
        assert classified.id in ids
        assert selected.id not in ids

    def test_prepare_cohort(self):
        selected = _seed_item(status="selected", title="Selected")
        classified = _seed_item(status="classified", title="Classified")

        ids = {item.id for item in items_for_prepare()}
        assert selected.id in ids
        assert classified.id not in ids

    def test_playable_queue_cohort(self):
        ready = _seed_item(status="ready", title="Ready")
        selected_article = _seed_item(status="selected", title="Selected Article")
        completed = _seed_item(status="completed", title="Completed")

        ids = {item.id for item in items_playable_in_queue()}
        assert ready.id in ids
        assert selected_article.id in ids
        assert completed.id not in ids

    def test_playlist_all_matches_queue_active_cohort(self):
        ready = _seed_item(status="ready", title="Ready")
        selected = _seed_item(status="selected", title="Selected")

        playlist_ids = {item.id for item in items_for_playlist_all()}
        assert ready.id in playlist_ids
        assert selected.id in playlist_ids

    def test_ready_only_subset_of_playable_queue(self):
        ready = _seed_item(status="ready", title="Ready")
        selected = _seed_item(status="selected", title="Selected")

        ready_ids = {item.id for item in items_playable_ready_only()}
        assert ready.id in ready_ids
        assert selected.id not in ready_ids


class TestPodcastDiscoveryPendingCandidate:
    def test_new_podcast_episode_is_not_preparation_queued(self):
        from wilted.feeds import add_feed

        feed = add_feed("https://ex.com/podcast.xml", feed_type="podcast")
        entry = _make_parsed_entry(
            id="ep-pending",
            title="Episode Pending",
            enclosures=[{"href": "https://ex.com/ep.mp3", "type": "audio/mpeg"}],
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        item = Item.select().where(Item.guid == "ep-pending").get()
        assert item.preparation_state == PreparationState.NOT_QUEUED.value
        assert item.fetch_state == FetchState.METADATA.value
        assert item.analysis_state == AnalysisState.PENDING.value
        assert item.status == "discovered"


class TestQueueRemovalUsesDisplayOrdering:
    def test_remove_article_targets_displayed_position(self):
        earlier = "2000-01-01T00:00:00Z"
        selected = _seed_item(
            title="Selected Article",
            discovered_at=earlier,
            status="selected",
        )
        ready = _seed_item(title="Ready Article", status="ready")

        queue = load_queue()
        assert queue[0]["id"] == selected.id

        removed = remove_article(0)
        assert removed["id"] == selected.id
        remaining_ids = {entry["id"] for entry in load_queue()}
        assert selected.id not in remaining_ids
        assert ready.id in remaining_ids


class TestSafeInterruptionBandUnchanged:
    def test_normalize_band_1000_unchanged(self):
        from wilted.station_runtime import normalize

        assert normalize._SAFE_INTERRUPTION_BAND_MS == 1000
