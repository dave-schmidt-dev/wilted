#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/Probes/SignedSpeechRuntimeProbe/signed-speech-runtime-probe.sh"
temp_dir="$(mktemp -d -t wilted-signed-runtime-tests.XXXXXX)"
trap 'rm -rf "$temp_dir"' EXIT

printf '%s\n' 'stage=signed-speech-runtime-tests.start' >&2
output="$temp_dir/output.json"
stderr="$temp_dir/stderr.log"
probe="$repo_root/Probes/SpeechIPCProbe/.build/arm64-apple-macosx/debug/speech-ipc-probe"
probe_args=()
if [[ -x "$probe" ]]; then
    probe_args=(--probe "$probe")
fi
if ! bash "$runner" "${probe_args[@]}" >"$output" 2>"$stderr"; then
    cat "$stderr" >&2
    cat "$output" >&2 || true
    printf '%s\n' 'signed runtime probe did not pass' >&2
    exit 1
fi
cat "$stderr" >&2

python3 - "$output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
assert result["ok"] is True
assert result["app_executed"] is True
assert result["signature_valid"] is True
assert result["hardened_runtime"] is True
assert result["app_sandbox"] is False
assert result["app_sandbox_entitlement"] is False
assert result["app_sandbox_status"] == "absent"
assert result["selftest_exact_echo"] is True
assert result["socket_harness"] == "fake-unix-socket"
assert result["socket_path_scope"] == "mktemp-only"
assert result["test_count"] > 0
assert "Developer ID identity" in result["human_gates"]
PY

missing_harness="$temp_dir/missing-harness.py"
failure_output="$temp_dir/failure.json"
if bash "$runner" "${probe_args[@]}" \
    --harness "$missing_harness" >"$failure_output" 2>"$temp_dir/failure.stderr"; then
    cat "$failure_output" >&2
    printf '%s\n' 'missing fake harness unexpectedly passed' >&2
    exit 1
fi
python3 - "$failure_output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
assert result["ok"] is False
assert result["test_count"] == 0
assert "error" in result
PY

missing_probe="$temp_dir/missing-probe"
unguarded_failure_output="$temp_dir/unguarded-failure.json"
# Invoke outside an if-condition so the wrapper's own -e/EXIT fail-closed path is exercised.
set +e
bash "$runner" --probe "$missing_probe" >"$unguarded_failure_output" 2>"$temp_dir/unguarded-failure.stderr"
unguarded_failure_rc=$?
set -e
if [[ "$unguarded_failure_rc" -eq 0 ]]; then
    cat "$unguarded_failure_output" >&2
    printf '%s\n' 'missing probe unexpectedly passed' >&2
    exit 1
fi
python3 - "$unguarded_failure_output" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    result = json.load(stream)
assert result["ok"] is False
assert result["app_executed"] is False
assert result["test_count"] == 0
assert result["error"] == "unexpected wrapper failure"
PY

printf '%s\n' 'stage=signed-speech-runtime-tests.complete count=5' >&2
