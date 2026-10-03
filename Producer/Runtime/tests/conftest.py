"""Shared test fixtures for wilted."""

import pytest

import wilted

_TEST_MARKERS = {
    "test_ads.py": ("unit",),
    "test_ads_cut_guard.py": ("unit",),
    "test_cache.py": ("integration",),
    "test_edge_cases.py": ("integration",),
    "test_execution_capability.py": ("integration",),
    "test_feed_refs.py": ("integration",),
    "test_llm.py": ("unit",),
    "test_llm_metal.py": ("integration",),
    "test_text.py": ("unit",),
    "test_transcribe.py": ("unit",),
}


@pytest.fixture(autouse=True)
def isolated_data(tmp_path, monkeypatch):
    """Redirect all data paths to a temp directory for every test."""
    data_dir = tmp_path / "data"
    audio_dir = data_dir / "audio"
    audio_dir.mkdir(parents=True)

    monkeypatch.setattr(wilted, "DATA_DIR", data_dir)
    monkeypatch.setattr(wilted, "AUDIO_DIR", audio_dir)
    yield


@pytest.fixture
def execution_capability():
    """Activate worker-equivalent ML authority for direct stage tests."""
    import wilted
    from wilted.execution_capability import execution_capability_scope

    with execution_capability_scope(owner_id="test", data_dir=wilted.DATA_DIR):
        yield


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Apply suite-tier markers centrally instead of scattering file edits."""
    for item in items:
        filename = item.path.name
        for marker in _TEST_MARKERS.get(filename, ()):
            item.add_marker(getattr(pytest.mark, marker))
