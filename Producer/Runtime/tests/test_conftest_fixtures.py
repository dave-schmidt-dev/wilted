"""Regression coverage for shared fixture internals in ``tests/conftest.py``.

``stub_audio_modules`` used to install its fake ``sounddevice``/``mlx_audio``
entries via ``unittest.mock.patch.dict(sys.modules, {...})``. ``patch.dict``'s
teardown unconditionally clears the ENTIRE ``sys.modules`` dict before
restoring it from a snapshot taken at setup time — even though only three
keys were ever added. A Textual pilot test (``tests/test_tui.py``) that still
has a background worker thread mid-import when this fixture tears down can
race that whole-dict clear against a concurrent ``import`` on the other
thread, corrupting the import system for whatever module it was loading
(reproducible directly: numpy raises "cannot load module more than once per
process" when a background thread imports it while another thread clears
``sys.modules``). This is intermittent and load-dependent, so it is not
practical to assert on directly; instead this test asserts the STRUCTURAL
property that actually prevents the race: teardown must touch only the
three keys the fixture owns, never the rest of ``sys.modules``.
"""

from __future__ import annotations

import sys
import types

from tests.conftest import _stub_audio_modules_scope

_OWNED_KEYS = ("sounddevice", "mlx_audio", "mlx_audio.audio_io")
_PROBE_KEY = "wilted_test_conftest_fixtures_probe_module"


class TestStubAudioModulesScope:
    def test_installs_and_removes_only_its_own_keys(self):
        """Keys absent before the scope are absent again after it exits.

        Establishes its own precondition (pops any pre-loaded owned keys, then
        restores them) so the assertion holds under full-suite ordering, where
        an earlier test may have left a fake ``sounddevice`` etc. in
        ``sys.modules``. Asserting global absence directly is itself an
        isolation bug — exactly the class this fixture change fixes.
        """
        _missing = object()
        saved = {key: sys.modules.pop(key, _missing) for key in _OWNED_KEYS}
        try:
            for key in _OWNED_KEYS:
                assert key not in sys.modules

            with _stub_audio_modules_scope():
                assert sys.modules["sounddevice"].__name__ == "sounddevice"
                assert sys.modules["mlx_audio"].__name__ == "mlx_audio"
                assert sys.modules["mlx_audio.audio_io"].__name__ == "mlx_audio.audio_io"

            for key in _OWNED_KEYS:
                assert key not in sys.modules
        finally:
            for key, value in saved.items():
                if value is not _missing:
                    sys.modules[key] = value

    def test_restores_preexisting_modules_by_identity(self):
        """A module already present under an owned key is restored, not dropped."""
        _missing = object()
        prior = sys.modules.pop("sounddevice", _missing)
        real_sounddevice = types.ModuleType("sounddevice")
        sys.modules["sounddevice"] = real_sounddevice
        try:
            with _stub_audio_modules_scope():
                assert sys.modules["sounddevice"] is not real_sounddevice
            assert sys.modules["sounddevice"] is real_sounddevice
        finally:
            if prior is _missing:
                sys.modules.pop("sounddevice", None)
            else:
                sys.modules["sounddevice"] = prior

    def test_teardown_never_touches_unrelated_sys_modules_keys(self):
        """The bug: ``patch.dict`` teardown clears/restores the WHOLE dict.

        A key added to ``sys.modules`` *during* the scope (after setup, before
        teardown) is not part of the setup-time snapshot. The old
        ``patch.dict``-based implementation wiped it on exit because its
        teardown does ``sys.modules.clear()`` then restores only the
        snapshot taken at entry. This reproduces that defect deterministically
        (no threading/timing needed) by asserting the probe key set mid-scope
        survives teardown untouched — proof the fixture only ever mutates its
        three owned keys.
        """
        assert _PROBE_KEY not in sys.modules
        probe_module = types.ModuleType(_PROBE_KEY)
        try:
            with _stub_audio_modules_scope():
                sys.modules[_PROBE_KEY] = probe_module
            assert sys.modules.get(_PROBE_KEY) is probe_module, (
                "stub_audio_modules teardown must not clear sys.modules keys "
                "it does not own — a full clear() here is exactly what races "
                "a concurrent background-thread import (see module docstring)"
            )
        finally:
            sys.modules.pop(_PROBE_KEY, None)
