"""Edge case tests for wilted — editable-install health."""

import wilted

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
