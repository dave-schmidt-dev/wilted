"""Edge case tests for wilted — project-root resolution and editable-install health."""

import importlib
import os
from unittest.mock import patch

import wilted

# ---------------------------------------------------------------------------
# TestProjectRootResolution
# ---------------------------------------------------------------------------


class TestProjectRootResolution:
    """Verify PROJECT_ROOT resolves correctly regardless of install type."""

    def test_project_root_contains_pyproject_toml(self):
        """PROJECT_ROOT should point to the directory containing pyproject.toml."""
        assert (wilted.PROJECT_ROOT / "pyproject.toml").exists(), (
            f"PROJECT_ROOT={wilted.PROJECT_ROOT} does not contain pyproject.toml"
        )

    def test_data_dir_default_is_under_project_root(self):
        """The default DATA_DIR (before fixture override) should be PROJECT_ROOT/data."""
        # The autouse isolated_data fixture patches DATA_DIR to a tmp path, so
        # we verify the source definition rather than the live patched value.
        from pathlib import Path

        init_path = Path(wilted.__file__)
        source = init_path.read_text()
        assert 'DATA_DIR = PROJECT_ROOT / "data"' in source

    def test_env_var_override(self, tmp_path):
        """WILTED_PROJECT_ROOT env var should override auto-detection."""
        original_root = wilted.PROJECT_ROOT
        try:
            with patch.dict("os.environ", {"WILTED_PROJECT_ROOT": str(tmp_path)}):
                importlib.reload(wilted)
                assert wilted.PROJECT_ROOT == tmp_path
        finally:
            with patch.dict("os.environ", {}, clear=False):
                os.environ.pop("WILTED_PROJECT_ROOT", None)
                importlib.reload(wilted)
            assert wilted.PROJECT_ROOT == original_root


# ---------------------------------------------------------------------------
# BUG-3 regression guard — editable install must resolve
# ---------------------------------------------------------------------------


class TestEditableInstallResolves:
    """Regression guard for BUG-3 (iCloud UF_HIDDEN flag breaking .pth files).

    The venv now lives at ~/.venvs/wilted (outside iCloud) so Python 3.13's
    site.py never encounters hidden .pth files.  These fast, in-process checks
    verify the package resolves correctly through the editable install path and
    that key public sub-modules are importable.  If the venv regresses (e.g.
    someone moves it back inside ~/Documents/), these tests catch it immediately
    without needing to run the real CLI entry point.
    """

    def test_wilted_package_importable(self):
        """``import wilted`` must succeed — basic editable-install health check."""
        import importlib

        mod = importlib.import_module("wilted")
        assert mod is not None

    def test_wilted_package_file_is_under_src(self):
        """__file__ for the installed package must point inside src/, not a wheel cache.

        If the UF_HIDDEN / venv relocation bug recurs and PYTHONPATH masking is
        removed, this test would catch a wrong resolution.
        """
        import pathlib

        pkg_file = pathlib.Path(wilted.__file__).resolve()
        assert "src" in pkg_file.parts, (
            f"wilted.__file__={pkg_file} is not under src/ — "
            "editable install may not be resolving correctly; check UV_PROJECT_ENVIRONMENT"
        )
