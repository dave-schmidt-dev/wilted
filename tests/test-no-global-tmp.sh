#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/scripts/check-no-global-tmp.py"
python3 - "$repo_root" <<'PY'
import importlib.util
import sys
from pathlib import Path
root = Path(sys.argv[1])
name = "no_global_tmp"
spec = importlib.util.spec_from_file_location(name, root / "scripts/check-no-global-tmp.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.violations(Path("sample.sh"), "echo /" + "tmp/old")
assert module.violations(Path("sample.md"), "See /private/" + "tmp/old")
assert not module.violations(Path("sample.sh"), "echo $TMPDIR/new")
assert module.selected(Path("scripts/build.sh"))
assert module.selected(Path("docs/README.md"))
assert not module.selected(Path("tests/test_fixture.py"))
print("no-global-tmp tests: OK")
PY
