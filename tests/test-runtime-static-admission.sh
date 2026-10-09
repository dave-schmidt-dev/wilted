#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$repo_root" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])
ENVIRONMENT = Path.home() / '.venvs/wilted'

class StaticAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wilted-static-admission-test-', dir=os.environ['TMPDIR'])
        self.root = Path(self.temp.name)
        self.venv = self.root / 'venv'
        (self.venv / 'bin').mkdir(parents=True)
        interpreter = (ENVIRONMENT / 'bin/python').resolve(strict=True)
        (self.venv / 'bin/python').symlink_to(interpreter)
        self.site = Path(subprocess.check_output([str(interpreter), '-B', '-S', '-c',
            'import sys,sysconfig; print(sysconfig.get_path("purelib", vars={"base":sys.argv[1],"platbase":sys.argv[1]}))',
            str(self.venv)], text=True, timeout=15).strip())
        real_site = Path(subprocess.check_output([str(interpreter), '-B', '-S', '-c',
            'import sys,sysconfig; print(sysconfig.get_path("purelib", vars={"base":sys.argv[1],"platbase":sys.argv[1]}))',
            str(ENVIRONMENT)], text=True, timeout=15).strip())
        self.site.mkdir(parents=True)
        shutil.copytree(real_site / 'vulture', self.site / 'vulture', ignore=shutil.ignore_patterns('__pycache__'))
        (self.venv / 'pyvenv.cfg').write_text(f'home = {interpreter.parent}\ninclude-system-site-packages = false\n')
        self.hook = self.root / 'startup-hook-fired'
        (self.site / 'unrelated_editable.pth').write_text('import startup_probe\n')
        (self.site / 'startup_probe.py').write_text(f'from pathlib import Path\nPath({str(self.hook)!r}).write_text("loaded")\nraise SystemExit("unrelated editable startup must not run")\n')
        (self.venv / 'bin/ruff').symlink_to((ENVIRONMENT / 'bin/ruff').resolve(strict=True))
        self.project = self.root / 'project'; (self.project / 'src/nested').mkdir(parents=True)
        shutil.copyfile(ROOT / 'Producer/Runtime/Makefile', self.project / 'Makefile')
        (self.project / 'pyproject.toml').write_text('[tool.vulture]\npaths=["src","vulture_allowlist.py"]\nmin_confidence=60\n[tool.ruff]\n')
        (self.project / 'src/app.py').write_text('def exercised():\n    return 3\nprint(exercised())\ndef baseline_unused():\n    return 7\n')
        (self.project / 'src/nested/helper.py').write_text('def nested_live():\n    return 9\nprint(nested_live())\n')
        (self.project / 'vulture_allowlist.py').write_text('baseline_unused\n')
        self.bin = self.root / 'bin'; self.bin.mkdir()
        uv = self.bin / 'uv'
        # Old canonical uv launcher is represented by normal startup in this owned environment only.
        uv.write_text('#!/bin/bash\nexec "$UV_PROJECT_ENVIRONMENT/bin/python" -B -m vulture\n'); uv.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('PYTHONPATH', None)

    def tearDown(self):
        path = self.root
        self.temp.cleanup()
        self.assertFalse(path.exists(), 'owned fixture must be removed')

    def make(self, target):
        return subprocess.run(['make', target, 'UV_PROJECT_ENVIRONMENT=' + str(self.venv)], cwd=self.project,
                              env=self.env, text=True, capture_output=True, timeout=30)

    def test_normal_startup_control_reaches_unrelated_editable_hook(self):
        result = subprocess.run([str(self.venv / 'bin/python'), '-B', '-c', 'print("unexpected")'],
                                env=self.env, text=True, capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.hook.is_file())
        self.assertIn('unrelated editable startup must not run', result.stderr)

    def test_deadcode_reads_source_and_allowlist_without_startup_hook(self):
        result = self.make('deadcode')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.hook.exists())
        (self.project / 'vulture_allowlist.py').write_text('')
        result = self.make('deadcode')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unused function 'baseline_unused' (60% confidence)", result.stdout)
        self.assertFalse(self.hook.exists())

    def test_deadcode_recurses_and_rejects_new_unused_code(self):
        (self.project / 'src/nested/dead.py').write_text('def deliberately_unused_static_probe():\n    return 1\n')
        result = self.make('deadcode')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('src/nested/dead.py:1:', result.stdout)
        self.assertIn("unused function 'deliberately_unused_static_probe' (60% confidence)", result.stdout)
        self.assertFalse(self.hook.exists())

    def test_missing_checker_fails_loudly(self):
        (self.venv / 'bin/python').unlink()
        result = self.make('deadcode')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No such file or directory', result.stderr)

    def test_lint_keeps_real_ruff_failure_and_skips_editable_startup(self):
        result = self.make('lint')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('F821', result.stdout)
        self.assertFalse(self.hook.exists())
        (self.project / 'vulture_allowlist.py').write_text('')
        result = self.make('lint')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('All checks passed', result.stdout)

unittest.main(argv=['runtime-static-admission'], verbosity=2)
PY
