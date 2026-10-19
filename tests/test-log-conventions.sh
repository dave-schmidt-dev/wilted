#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/scripts/check-log-conventions.py"
python3 - "$repo_root" <<'PY'
import importlib.util
import sys
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("log_conventions", root / "scripts/check-log-conventions.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
good = 'let log = Logger(subsystem: "com.zerodelta.wilted.mac", category: "WorkTicket")'
assert not module.violations(Path("A.swift"), good)
assert module.violations(Path("A.swift"), good.replace("com.zerodelta.wilted.mac", "com.example.other"))
assert module.violations(Path("A.swift"), good.replace("WorkTicket", "work-ticket"))
assert module.violations(Path("A.swift"), 'let log = Logger(subsystem: name, category: "WorkTicket")')
query = """/// `log show --predicate 'subsystem BEGINSWITH "com.zerodelta.wilted"'`"""
assert not module.violations(Path("A.swift"), query)
assert module.violations(Path("A.swift"), query.replace('BEGINSWITH "com.zerodelta.wilted"', '== "com.zerodelta.wilted.mac"'))
assert module.selected(Path("WiltedMac/Sync/WiltedMacHandoffController.swift"))
assert not module.selected(Path("WiltedMacTests/WiltedMacModelTests.swift"))
assert not module.selected(Path("CloudSync/Tests/WiltedCloudKitTests/CloudKitEngineDriverTests.swift"))
print("log-conventions tests: OK")
PY
