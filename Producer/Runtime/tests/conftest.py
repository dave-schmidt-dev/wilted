"""Shared test fixtures for wilted."""

import pytest

_TEST_MARKERS = {
    "test_ads.py": ("unit",),
    "test_ads_cut_guard.py": ("unit",),
    "test_cache.py": ("integration",),
    "test_edge_cases.py": ("integration",),
    "test_execution_capability.py": ("integration",),
    "test_llm.py": ("unit",),
    "test_llm_metal.py": ("integration",),
    "test_transcribe.py": ("unit",),
}


@pytest.fixture(autouse=True)
def isolated_data(tmp_path):
    """Give every test its own temporary data directory."""
    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True)
    yield data_dir


@pytest.fixture
def execution_capability(isolated_data):
    """Activate worker-equivalent ML authority for direct stage tests."""
    from wilted.execution_capability import execution_capability_scope

    with execution_capability_scope(owner_id="test", data_dir=isolated_data):
        yield


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Apply suite-tier markers centrally instead of scattering file edits."""
    for item in items:
        filename = item.path.name
        for marker in _TEST_MARKERS.get(filename, ()):
            item.add_marker(getattr(pytest.mark, marker))
