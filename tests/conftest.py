"""Shared test fixtures for wilted."""

import sys
import types
from unittest.mock import MagicMock, patch

import pytest

import wilted

_TEST_MARKERS = {
    "test_ads.py": ("unit",),
    "test_article_assembly.py": ("integration",),
    "test_background_work_contracts.py": ("unit",),
    "test_briefing.py": ("unit",),
    "test_cache.py": ("integration",),
    "test_checkpoint_poller.py": ("unit",),
    "test_classify.py": ("unit",),
    "test_cli.py": ("integration",),
    "test_content_state.py": ("integration",),
    "test_controller_lease.py": ("integration",),
    "test_coordinator.py": ("unit",),
    "test_db.py": ("integration",),
    "test_discover.py": ("integration",),
    "test_download.py": ("integration",),
    "test_e2e.py": ("e2e",),
    "test_edge_cases.py": ("integration",),
    "test_engine.py": ("unit",),
    "test_execution_capability.py": ("integration",),
    "test_feeds.py": ("integration",),
    "test_fetch.py": ("unit",),
    "test_ingest.py": ("unit",),
    "test_item_normalize.py": ("integration",),
    "test_legacy_cutover.py": ("integration",),
    "test_llm.py": ("unit",),
    "test_llm_metal.py": ("integration",),
    "test_media_store.py": ("integration",),
    "test_onboard.py": ("unit",),
    "test_playback_adapter.py": ("integration",),
    "test_playlists.py": ("integration",),
    "test_schema_cutover_queries.py": ("integration",),
    "test_preferences.py": ("integration",),
    "test_prepare.py": ("integration",),
    "test_processing_jobs.py": ("integration",),
    "test_processing_job_claim.py": ("integration",),
    "test_pipeline_handlers.py": ("integration",),
    "test_pipeline_runner.py": ("integration",),
    "test_production_orchestration.py": ("integration",),
    "test_query_cohort_equivalence.py": ("integration",),
    "test_queue.py": ("integration",),
    "test_report.py": ("integration",),
    "test_resume.py": ("integration",),
    "test_route_monitor.py": ("unit",),
    "test_sequencer.py": ("unit",),
    "test_station_contracts.py": ("unit",),
    "test_station_controller.py": ("integration",),
    "test_station_store.py": ("unit",),
    "test_text.py": ("unit",),
    "test_timing_map.py": ("unit",),
    "test_transcribe.py": ("unit",),
    "test_tui.py": ("tui",),
    "test_tui_snapshots.py": ("tui",),
    "test_weather_monitor.py": ("integration",),
}


def _fake_package(name: str) -> types.ModuleType:
    """Return a minimal package-like module for sys.modules patching."""
    module = types.ModuleType(name)
    module.__path__ = []  # type: ignore[attr-defined]
    return module


@pytest.fixture(autouse=True)
def isolated_data(tmp_path, monkeypatch, request):
    """Redirect all data paths to a temp directory for every test."""
    data_dir = tmp_path / "data"
    articles_dir = data_dir / "articles"
    audio_dir = data_dir / "audio"
    articles_dir.mkdir(parents=True)
    audio_dir.mkdir(parents=True)

    monkeypatch.setattr(wilted, "DATA_DIR", data_dir)
    monkeypatch.setattr(wilted, "QUEUE_FILE", data_dir / "queue.json")
    monkeypatch.setattr(wilted, "ARTICLES_DIR", articles_dir)
    monkeypatch.setattr(wilted, "AUDIO_DIR", audio_dir)

    from wilted import cache as cache_mod
    from wilted.db import Item, reset_db, run_migrations

    monkeypatch.setattr(cache_mod, "AUDIO_DIR", audio_dir)

    # Give each test a fresh, isolated SQLite database.
    reset_db()
    run_migrations(data_dir / "wilted.db")

    module_name = getattr(request.module, "__name__", "")
    if not module_name.endswith("test_legacy_cutover"):
        from tests.orthogonal_test_helpers import ensure_test_orthogonal_state
        from wilted.content_state import backfill_orthogonal_from_legacy

        _original_item_create = Item.create

        @classmethod
        def _item_create_with_backfill(cls, **kwargs):
            skip = kwargs.pop("_skip_orthogonal_backfill", False)
            item = _original_item_create(**kwargs)
            if not skip and item.fetch_state is None and item.status:
                backfill_orthogonal_from_legacy(item)
                item = cls.get_by_id(item.id)
                if item.fetch_state is None and item.status:
                    ensure_test_orthogonal_state(item)
                    item = cls.get_by_id(item.id)
            return item

        monkeypatch.setattr(Item, "create", _item_create_with_backfill)

    yield

    reset_db()  # Close file handles so tmp_path cleanup succeeds on Windows


@pytest.fixture
def execution_capability():
    """Activate PipelineRunner-equivalent ML authority for direct stage tests."""
    import wilted
    from wilted.execution_capability import execution_capability_scope

    with execution_capability_scope(owner_id="test", data_dir=wilted.DATA_DIR):
        yield


@pytest.fixture
def stub_audio_modules():
    """Provide fake sounddevice/mlx_audio modules for tests that patch them.

    This keeps collection-time imports from poisoning unrelated tests while
    still allowing module-level patch targets such as ``sounddevice`` and
    ``mlx_audio.audio_io`` to resolve inside unit tests.
    """
    fake_sounddevice = types.ModuleType("sounddevice")
    fake_sounddevice.OutputStream = MagicMock()
    fake_sounddevice.PortAudioError = OSError

    fake_mlx_audio = _fake_package("mlx_audio")
    fake_audio_io = types.ModuleType("mlx_audio.audio_io")
    fake_audio_io.write = lambda *args, **kwargs: None
    fake_audio_io.read = MagicMock()

    fake_mlx_audio.audio_io = fake_audio_io

    with patch.dict(
        sys.modules,
        {
            "sounddevice": fake_sounddevice,
            "mlx_audio": fake_mlx_audio,
            "mlx_audio.audio_io": fake_audio_io,
        },
    ):
        yield


@pytest.fixture
def stub_trafilatura_module():
    """Provide a fake trafilatura module for ingest tests."""
    fake_trafilatura = types.ModuleType("trafilatura")
    with patch.dict(sys.modules, {"trafilatura": fake_trafilatura}):
        yield


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Apply suite-tier markers centrally instead of scattering file edits."""
    for item in items:
        filename = item.path.name
        for marker in _TEST_MARKERS.get(filename, ()):
            item.add_marker(getattr(pytest.mark, marker))
