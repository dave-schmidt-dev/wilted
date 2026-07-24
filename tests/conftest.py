"""Shared test fixtures for wilted."""

import sys
import types
from configparser import ConfigParser
from contextlib import contextmanager
from unittest.mock import MagicMock, patch

import pytest

import wilted

_TEST_MARKERS = {
    "test_ads.py": ("unit",),
    "test_article_assembly.py": ("integration",),
    "test_background_work_contracts.py": ("unit",),
    "test_background_work_invariant.py": ("integration",),
    "test_briefing.py": ("unit",),
    "test_cache.py": ("integration",),
    "test_checkpoint_poller.py": ("unit",),
    "test_checkpoint_progress.py": ("integration",),
    "test_classify.py": ("unit",),
    "test_cli.py": ("integration",),
    "test_conftest_fixtures.py": ("unit",),
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
    "test_fetch_cascade.py": ("unit",),
    "test_ingest.py": ("unit",),
    "test_item_normalize.py": ("integration",),
    "test_legacy_cutover.py": ("integration",),
    "test_llm.py": ("unit",),
    "test_llm_metal.py": ("integration",),
    "test_media_store.py": ("integration",),
    "test_onboard.py": ("unit",),
    "test_playback_adapter.py": ("integration",),
    "test_playlists.py": ("integration",),
    "test_post_cutover_e2e.py": ("e2e",),
    "test_schema_cutover_queries.py": ("integration",),
    "test_scheduler_tick.py": ("integration",),
    "test_preferences.py": ("integration",),
    "test_prepare.py": ("integration",),
    "test_processing_jobs.py": ("integration",),
    "test_processing_job_claim.py": ("integration",),
    "test_processing_job_recovery.py": ("integration",),
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


@pytest.fixture(scope="session", autouse=True)
def _prewarm_tqdm_lock():
    """Create tqdm's multiprocessing lock once, on the main thread, before any
    test runs — mirroring production, where ``cli._launch_tui`` pre-warms it
    before mounting the TUI.

    Textual's headless ``run_test()`` driver makes ``sys.stderr.fileno()``
    return ``-1``. ``WiltedApp.on_mount`` inits tqdm's lock when handed a
    not-yet-ready :class:`RuntimeBootstrap` (the test path — ``_make_app`` builds
    a fresh one). If that mount were the FIRST caller to create the
    multiprocessing lock inside a pilot, ``multiprocessing.resource_tracker``
    would choke on the ``-1`` fd (``ValueError: bad value(s) in fds_to_keep``).
    Warming it here — outside any Textual context, where stderr's fd is valid —
    means every later ``get_lock()`` / ``init_tqdm_lock()`` returns the cached
    lock without re-spawning resource_tracker. Session-scoped + autouse so it
    holds under any marker subset (e.g. ``-m tui``), not only the full suite
    where ``test_pipeline_runner`` happens to warm it first by import order.
    """
    import tqdm

    tqdm.tqdm.get_lock()
    yield


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

    from wilted.db import Item, reset_db, run_migrations

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
def cutover_applied_db(isolated_data, tmp_path):
    """``isolated_data`` with the destructive legacy content-state cutover applied.

    Drops ``items.status`` / ``items.status_changed_at`` and the legacy
    ``selection_history`` table, matching the production post-cutover schema
    (see ``wilted.legacy_cutover.apply_legacy_cutover``). Depends on
    ``isolated_data`` so the real data tree is never touched, and reuses
    ``orthogonal_test_helpers.finalize_post_cutover_db`` — the same reconnect
    step ``test_legacy_cutover.py``'s post-cutover regressions rely on — to
    resync the ``Item`` model against the rebuilt table (no ``status`` field).

    Yields the cutover-applied ``wilted.db`` path.
    """
    from tests.orthogonal_test_helpers import finalize_post_cutover_db
    from wilted.legacy_cutover import apply_legacy_cutover

    db_path = wilted.DATA_DIR / "wilted.db"
    apply_legacy_cutover(db_path, dry_run=False, backup_dir=tmp_path / "backups")
    finalize_post_cutover_db(db_path)
    return db_path


@pytest.fixture
def execution_capability():
    """Activate PipelineRunner-equivalent ML authority for direct stage tests."""
    import wilted
    from wilted.execution_capability import execution_capability_scope

    with execution_capability_scope(owner_id="test", data_dir=wilted.DATA_DIR):
        yield


@pytest.fixture(scope="session")
def speech_daemon_available() -> bool:
    """Probe the speech daemon once per session.

    Wilted's CLI/TUI entrypoints hard-require a ready speech daemon
    (``require_daemon_ready`` — the M2 daemon-only cutover), so any test that
    runs the real ``wilted`` entrypoint as a subprocess needs a live daemon.
    When the daemon is unavailable — e.g. the tracked gpu-host wedge under
    concurrent load (see ``speech-stack/TASKS.md``) — those tests should skip,
    not hard-fail, since the failure is an external-dependency outage rather
    than a wilted regression. Probed at most once (session-scoped, cached) with
    a short timeout so a wedged daemon fails fast instead of stalling the suite.
    """
    try:
        from speech_stack.client import require_daemon_ready
    except Exception:
        return False
    try:
        require_daemon_ready(probe=True, timeout=8.0)
    except Exception:
        return False
    return True


@pytest.fixture
def requires_speech_daemon(speech_daemon_available: bool) -> None:
    """Skip a test that drives the real ``wilted`` entrypoint when the speech
    daemon is unavailable. See ``speech_daemon_available``."""
    if not speech_daemon_available:
        pytest.skip(
            "speech daemon unavailable (require_daemon_ready failed) — external "
            "dependency outage, not a wilted regression; tracked gpu-host wedge, "
            "see speech-stack/TASKS.md"
        )


@contextmanager
def _stub_audio_modules_scope():
    """Install fake sounddevice/mlx_audio ``sys.modules`` entries.

    Installs/removes only the three ``sys.modules`` keys this scope owns, via
    direct dict mutation rather than ``unittest.mock.patch.dict``.
    ``patch.dict``'s teardown (``_unpatch_dict``) unconditionally clears the
    ENTIRE ``sys.modules`` dict before restoring it from a snapshot, even
    though only these three keys were ever added. Textual pilot tests
    (test_tui.py) drive real background worker threads that may still be
    mid-import when this scope's teardown runs; a whole-dict clear during
    that window can race a concurrent ``import`` on another thread and
    corrupt the import system for whatever module it was loading — numpy
    detects this and raises "cannot load module more than once per process"
    (reproduced directly: widening the clear/restore gap with a background
    thread importing numpy concurrently reliably corrupts the import state).
    Mutating only our three keys removes the shared-state window entirely.
    See ``tests/test_conftest_fixtures.py`` for the regression coverage.
    """
    fake_sounddevice = types.ModuleType("sounddevice")
    fake_sounddevice.OutputStream = MagicMock()
    fake_sounddevice.PortAudioError = OSError

    fake_mlx_audio = _fake_package("mlx_audio")
    fake_audio_io = types.ModuleType("mlx_audio.audio_io")
    fake_audio_io.write = lambda *args, **kwargs: None
    fake_audio_io.read = MagicMock()

    fake_mlx_audio.audio_io = fake_audio_io

    fakes = {
        "sounddevice": fake_sounddevice,
        "mlx_audio": fake_mlx_audio,
        "mlx_audio.audio_io": fake_audio_io,
    }
    _missing = object()
    previous = {name: sys.modules.get(name, _missing) for name in fakes}
    sys.modules.update(fakes)
    try:
        yield
    finally:
        for name, value in previous.items():
            if value is _missing:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = value


@pytest.fixture
def stub_audio_modules():
    """Provide fake sounddevice/mlx_audio modules for tests that patch them.

    This keeps collection-time imports from poisoning unrelated tests while
    still allowing module-level patch targets such as ``sounddevice`` and
    ``mlx_audio.audio_io`` to resolve inside unit tests. See
    ``_stub_audio_modules_scope`` for why this avoids ``patch.dict``.
    """
    with _stub_audio_modules_scope():
        yield


@pytest.fixture
def stub_trafilatura_module():
    """Provide a fake trafilatura module (+ ``settings`` submodule) for tests.

    ``fetch_cascade._configure_once()`` calls
    ``trafilatura.settings.use_config()`` to get a real
    ``configparser.ConfigParser`` it can ``.set("DEFAULT", "DOWNLOAD_TIMEOUT",
    ...)`` on — matching trafilatura's actual return type (verified against
    the real 2.0.0 install) rather than a MagicMock that would silently
    accept any attribute access. Each call returns a fresh ConfigParser, same
    as the real ``use_config``, so tests can inspect what a given call
    produced without cross-call aliasing.
    """
    fake_trafilatura = types.ModuleType("trafilatura")
    fake_settings = types.ModuleType("trafilatura.settings")

    def _use_config() -> ConfigParser:
        cfg = ConfigParser()
        cfg.read_dict({"DEFAULT": {"DOWNLOAD_TIMEOUT": "30", "MAX_REDIRECTS": "2"}})
        return cfg

    fake_settings.use_config = _use_config
    fake_settings.DEFAULT_CONFIG = _use_config()
    fake_trafilatura.settings = fake_settings

    with patch.dict(sys.modules, {"trafilatura": fake_trafilatura, "trafilatura.settings": fake_settings}):
        yield


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Apply suite-tier markers centrally instead of scattering file edits."""
    for item in items:
        filename = item.path.name
        for marker in _TEST_MARKERS.get(filename, ()):
            item.add_marker(getattr(pytest.mark, marker))
