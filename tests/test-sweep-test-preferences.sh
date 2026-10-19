#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fixture_dir="$(mktemp -d "${TMPDIR:?}/sweep-prefs.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

python3 - "$repo_root" "$fixture_dir" <<'PY'
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys

repo_root = Path(sys.argv[1])
fixture_dir = Path(sys.argv[2])

spec = importlib.util.spec_from_file_location(
    "sweep_test_preferences", repo_root / "scripts/sweep-test-preferences.py"
)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

case1_dir = fixture_dir / "main_case"
case1_dir.mkdir()

proc = subprocess.Popen(["/usr/bin/true"])
proc.wait()
exited_pid = proc.pid

u1 = "11111111-1111-1111-1111-111111111111"
u2 = "22222222-2222-2222-2222-222222222222"
u_own = "33333333-3333-3333-3333-333333333333"
u_dir = "44444444-4444-4444-4444-444444444444"
u_sym = "55555555-5555-5555-5555-555555555555"

f_exited_tests = case1_dir / f"com.zerodelta.wilted.mac.tests.ephemeral.{exited_pid}.{u1}.plist"
f_exited_ui = case1_dir / f"com.zerodelta.wilted.mac.ui-fixture.{exited_pid}.{u2}.plist"
f_own = case1_dir / f"com.zerodelta.wilted.mac.tests.share-composer.{os.getpid()}.{u_own}.plist"
f_nonmatching1 = case1_dir / "com.zerodelta.wilted.mac.plist"
f_nonmatching2 = case1_dir / "com.zerodelta.wilted.mac.nowplaying-tests.x.plist"
d_matching = case1_dir / f"com.zerodelta.wilted.mac.tests.dir.{exited_pid}.{u_dir}.plist"
f_sym_target = case1_dir / "target.plist"
f_matching_symlink = case1_dir / f"com.zerodelta.wilted.mac.ui-fixture.{exited_pid}.{u_sym}.plist"

f_exited_tests.write_text("t")
f_exited_ui.write_text("u")
f_own.write_text("o")
f_nonmatching1.write_text("n1")
f_nonmatching2.write_text("n2")
d_matching.mkdir()
f_sym_target.write_text("target")
f_matching_symlink.symlink_to(f_sym_target)

cands = module.candidates(case1_dir)
assert {p.name for p, _ in cands} == {f_exited_tests.name, f_exited_ui.name, f_own.name}

# 5. --dry-run removes nothing and reports would-remove=
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    ret = module.main(["--directory", str(case1_dir), "--dry-run"])
assert ret == 0
assert "would-remove=2 kept-live=1 failed=0" in buf.getvalue()
assert f_exited_tests.exists()
assert f_exited_ui.exists()
assert f_own.exists()

# Run sweep without dry-run
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    ret = module.main(["--directory", str(case1_dir)])
assert ret == 0
assert "removed=2 kept-live=1 failed=0" in buf.getvalue()

# 1. mac.tests and ui-fixture with exited pid are removed
assert not f_exited_tests.exists()
assert not f_exited_ui.exists()

# 2. File named with test's own pid is kept
assert f_own.exists()

# 4. Non-matching names survive
assert f_nonmatching1.exists()
assert f_nonmatching2.exists()
assert d_matching.is_dir()
assert f_matching_symlink.is_symlink()

# 3. PID reuse
assert module.creator_is_live(os.getpid(), born=0.0) is False

d = fixture_dir / "pid_reuse_case"
d.mkdir()
f_pid1_stale = d / f"com.zerodelta.wilted.mac.tests.ephemeral.1.{u1}.plist"
f_pid1_live = d / f"com.zerodelta.wilted.mac.tests.ephemeral.1.{u2}.plist"
f_pid1_stale.write_text("stale")
f_pid1_live.write_text("live")

orig_birth_time = module.birth_time
try:
    module.birth_time = lambda p: 0.0 if p.name == f_pid1_stale.name else orig_birth_time(p)
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        ret = module.main(["--directory", d])
    assert ret == 0
    assert "removed=1 kept-live=1 failed=0" in buf.getvalue()
    assert not f_pid1_stale.exists()
    assert f_pid1_live.exists()
finally:
    module.birth_time = orig_birth_time

# 6. Missing directory returns 0
missing_dir = fixture_dir / "missing"
buf = io.StringIO()
with contextlib.redirect_stderr(buf):
    assert module.main(["--directory", str(missing_dir)]) == 0
assert "removed=0 kept-live=0 failed=0" in buf.getvalue()

print("sweep-test-preferences tests: OK")
PY
