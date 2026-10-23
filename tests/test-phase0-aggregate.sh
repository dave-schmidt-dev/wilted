#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
phase0_script="$repo_root/scripts/test-phase0.sh"
# shellcheck source=../scripts/lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
# This meta-test mints its own wilted-phase0-agg.XXXXXX root on every run;
# sweep abandoned ones from a killed prior run before adding another.
wilted_sweep_stale_temp_dirs

legs_list="$repo_root/scripts/phase0-legs.list"
expected_legs=()
listed_scripts=()
while read -r leg_name leg_script; do
  [[ -z "$leg_name" || "$leg_name" == \#* ]] && continue
  expected_legs+=("$leg_name")
  listed_scripts+=("$leg_script")
done <"$legs_list"

expected_count="${#expected_legs[@]}"

run_phase0_self_test() {
  local output_file="$1"
  local force_leg="$2"
  local phase_parent="$tmp_dir/phase-parent"
  mkdir -p "$phase_parent"

  set +e
  if [[ -n "$force_leg" ]]; then
    TMPDIR="$phase_parent" PHASE0_SELF_TEST=1 PHASE0_FORCE_FAIL_LEG="$force_leg" bash "$phase0_script" >"$output_file" 2>&1
  else
    TMPDIR="$phase_parent" PHASE0_SELF_TEST=1 bash "$phase0_script" >"$output_file" 2>&1
  fi
  local status=$?
  set -e
  printf '%s\n' "$status"
}

# Prints a run's output only when its status is not the one the case expects:
# a forced failure is the point of its case, so its fixture output stays quiet.
run_and_capture() {
  local label="$1"
  local output_file="$2"
  local status="$3"
  local expect="${4:-pass}"
  printf '%s\n' "meta-test[$label] status=$status"
  if [[ "$expect" == "pass" && "$status" -ne 0 ]] || [[ "$expect" == "fail" && "$status" -eq 0 ]]; then
    cat "$output_file" >&2
  fi
}

assert_zero_exit() {
  local status="$1"
  local label="$2"
  if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "assertion failed: $label expected exit 0, got $status" >&2
    exit 1
  fi
}

assert_nonzero_exit() {
  local status="$1"
  local label="$2"
  if [[ "$status" -eq 0 ]]; then
    printf '%s\n' "assertion failed: $label expected nonzero exit" >&2
    exit 1
  fi
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  if ! grep -Fq "$pattern" "$file"; then
    printf '%s\n' "assertion failed: missing pattern '$pattern'" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_contains 'done <"$repo_root/scripts/phase0-legs.list"' "$phase0_script"
assert_contains 'assert-mac-first-docs test-mac-first-docs.sh' "$legs_list"
assert_contains 'test-bounded-entry test-bounded-entry.sh' "$legs_list"
assert_contains 'test-storage-retention test-storage-retention.sh' "$legs_list"
assert_contains 'test-temp-leaks test-temp-leaks.sh' "$legs_list"
assert_contains 'python3 "$bounded_runner" --timeout-seconds "$phase0_leg_timeout_seconds" --' "$phase0_script"
assert_contains 'trap '\''cleanup_phase0; exit 129'\'' HUP' "$phase0_script"
assert_contains 'test-simulator-cleanup test-simulator-cleanup.sh' "$legs_list"

# Every tests/test-*.sh runs in some gate: from the list, as this meta-test,
# or from the Makefile's validate-inner. A listed script that is
# missing fails here rather than silently dropping its leg.
run_elsewhere=(test-phase0-aggregate.sh test-native-gate.sh
  test-native-gate-watch.sh test-carplay-config.sh)
for listed in "${listed_scripts[@]}"; do
  [[ -f "$repo_root/tests/$listed" ]] || {
    printf 'assertion failed: scripts/phase0-legs.list names missing tests/%s\n' "$listed" >&2
    exit 1
  }
done
for elsewhere in "${run_elsewhere[@]:1}"; do
  assert_contains "bash tests/$elsewhere" "$repo_root/Makefile"
done
for script in "$repo_root"/tests/test-*.sh; do
  script_name="$(basename "$script")"
  found=0
  for known in "${listed_scripts[@]}" "${run_elsewhere[@]}"; do
    [[ "$script_name" == "$known" ]] && found=1
  done
  if [[ "$found" -eq 0 ]]; then
    printf 'assertion failed: tests/%s runs in no gate; add it to scripts/phase0-legs.list\n' "$script_name" >&2
    exit 1
  fi
done

source "$repo_root/scripts/lib/test-temp-state.sh"
tmp_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-phase0-agg.XXXXXX")"; wilted_temp_mark_owned "$tmp_dir"
phase_owned_pids=""
cleanup_phase0_fixture() {
  local pid
  for pid in $phase_owned_pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in $phase_owned_pids; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$tmp_dir"
}
trap cleanup_phase0_fixture EXIT INT TERM HUP

write_interrupt_fixture() {
  local fixture="$1"
  cat >"$fixture" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
proof_dir="${WILTED_INTERRUPT_PROOF_DIR:?}"
mkdir -p "$proof_dir"
(
  trap 'exit 0' INT TERM HUP
  while :; do sleep 1; done
) &
grandchild_pid=$!
printf '%s\n' "$$" >"$proof_dir/child.pid"
printf '%s\n' "$grandchild_pid" >"$proof_dir/grandchild.pid"
trap 'wait "$grandchild_pid" 2>/dev/null || true; exit 0' INT TERM HUP
wait "$grandchild_pid"
FIXTURE
  chmod +x "$fixture"
}

wait_for_file() {
  local file="$1"
  local attempt
  for attempt in $(seq 1 50); do
    [[ -s "$file" ]] && return 0
    sleep 0.1
  done
  printf 'assertion failed: timed out waiting for %s\n' "$file" >&2
  return 1
}

assert_stopped() {
  local pid="$1"
  local label="$2"
  local attempt
  for attempt in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  printf 'assertion failed: %s pid=%s survived inner-shell TERM\n' "$label" "$pid" >&2
  ps -p "$pid" -o pid=,ppid=,state=,command= >&2 || true
  return 1
}

assert_inner_interrupt_cleanup() {
  local mode="$1"
  local proof_dir="$tmp_dir/$mode-proof"
  local output="$tmp_dir/$mode-interrupt.log"
  local fixture="$tmp_dir/$mode-fixture.sh"
  local peer_pid phase_pid child_pid grandchild_pid result

  write_interrupt_fixture "$fixture"
  sleep 60 &
  peer_pid=$!
  phase_owned_pids="$peer_pid"
  env WILTED_BOUNDED_ENTRY=1 PHASE0_INTERRUPT_TEST_LEG="$fixture" \
    PHASE0_INTERRUPT_TEST_MODE="$mode" WILTED_INTERRUPT_PROOF_DIR="$proof_dir" \
    bash "$phase0_script" >"$output" 2>&1 &
  phase_pid=$!
  phase_owned_pids="$phase_owned_pids $phase_pid"
  wait_for_file "$proof_dir/grandchild.pid" || {
    cat "$output" >&2
    return 1
  }
  child_pid="$(<"$proof_dir/child.pid")"
  grandchild_pid="$(<"$proof_dir/grandchild.pid")"
  kill -TERM "$phase_pid"
  set +e
  wait "$phase_pid"
  result=$?
  set -e
  [[ "$result" -eq 143 ]] || {
    printf 'assertion failed: phase0 %s inner shell expected 143, got %s\n' "$mode" "$result" >&2
    cat "$output" >&2
    return 1
  }
  assert_stopped "$child_pid" "phase0-$mode child"
  assert_stopped "$grandchild_pid" "phase0-$mode descendant"
  kill -0 "$peer_pid" 2>/dev/null || {
    printf 'assertion failed: unrelated peer died during phase0 %s cleanup\n' "$mode" >&2
    return 1
  }
  kill -TERM "$peer_pid" 2>/dev/null || true
  wait "$peer_pid" 2>/dev/null || true
  phase_owned_pids=""
  printf 'phase0 inner interrupt fixture passed mode=%s child=%s descendant=%s\n' \
    "$mode" "$child_pid" "$grandchild_pid"
}

assert_inner_interrupt_cleanup async
assert_inner_interrupt_cleanup sync

leak_fixture="$tmp_dir/leak-fixture.sh"
cat >"$leak_fixture" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${TMPDIR:?}/wilted-fixture-leak"
FIXTURE
chmod +x "$leak_fixture"
leak_parent="$tmp_dir/leak-parent"
leak_output="$tmp_dir/leak.log"
mkdir -p "$leak_parent"
set +e
TMPDIR="$leak_parent" PHASE0_INTERRUPT_TEST_LEG="$leak_fixture" \
  PHASE0_INTERRUPT_TEST_MODE=sync bash "$phase0_script" >"$leak_output" 2>&1
leak_status=$?
set -e
assert_nonzero_exit "$leak_status" "contained phase0 child leak"
assert_contains 'temp.leak label=phase0-leg-interrupt-fixture entry=wilted-fixture-leak' "$leak_output"

base_output="$tmp_dir/selftest.log"
forced_output="$tmp_dir/forced.log"

status="$(run_phase0_self_test "$base_output" "")"
run_and_capture "self" "$base_output" "$status"
assert_zero_exit "$status" "phase0 self-test"
assert_contains "phase0.passed count=${expected_count}" "$base_output"
if grep -Fq "phase0.failed" "$base_output"; then
  printf '%s\n' "assertion failed: unexpected phase0.failed in self-test success mode" >&2
  cat "$base_output" >&2
  exit 1
fi

forced_leg="test-contract-fixtures"
forced_status="$(run_phase0_self_test "$forced_output" "$forced_leg")"
run_and_capture "forced" "$forced_output" "$forced_status" fail
assert_nonzero_exit "$forced_status" "forced phase0 self-test"
assert_contains "phase0.failed count=1" "$forced_output"
assert_contains "phase0.leg.complete name=$forced_leg status=1 reason=self-test-forced-failure" "$forced_output"
assert_contains "forced_self_test_failure" "$forced_output"

static_forced_output="$tmp_dir/static-forced.log"
static_forced_status="$(run_phase0_self_test "$static_forced_output" "test-runtime-static-admission")"
run_and_capture "static-forced" "$static_forced_output" "$static_forced_status" fail
assert_nonzero_exit "$static_forced_status" "forced static admission leg"
assert_contains "phase0.failed count=1" "$static_forced_output"
assert_contains "phase0.leg.complete name=test-runtime-static-admission status=1 reason=self-test-forced-failure" "$static_forced_output"


# validate-inner's synthetic tests must not inherit the caller's real native
# gate selection or output destination. Only its final native gate uses them.
# Fake executables record the actual Makefile recipe environment; no gate runs.
validate_fixture="$tmp_dir/validate-environment"
mkdir -p "$validate_fixture/bin" "$validate_fixture/scratch"
real_python="$(python3 -c 'import sys; print(sys.executable)')"
real_make="$(command -v make)"
"$real_python" - "$repo_root/Makefile" "$validate_fixture" "$real_make" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

makefile, root, make = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
records = root / "recipes.jsonl"
recorder = "#!" + sys.executable + "\n" + '''import json
import os
from pathlib import Path
import sys
entry = {"executable": Path(sys.argv[0]).name, "args": sys.argv[1:],
         "environment": {key: os.environ.get(key) for key in (
             "WILTED_GATE_LEGS", "WILTED_NATIVE_RESULTS_DIR", "WILTED_MAC_UI")}}
with open(os.environ["WILTED_VALIDATE_ENV_RECORDS"], "a", encoding="utf-8") as output:
    output.write(json.dumps(entry) + "\\n")
sys.exit(1 if os.environ.get("WILTED_VALIDATE_FAKE_FAIL") in sys.argv[1:] else 0)
'''
for name in ("bash", "python3"):
    executable = root / "bin" / name
    executable.write_text(recorder, encoding="utf-8")
    executable.chmod(0o755)
selection = "wiltedkit-tests,cloudsync-tests,playback-tests,wiltedproducer-tests,macos-unit-tests,ios-unit-tests"
destination = str(root / "native results")
environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                   TMPDIR=str(root / "scratch"), WILTED_GATE_LEGS=selection,
                   WILTED_NATIVE_RESULTS_DIR=destination, WILTED_MAC_UI="0",
                   WILTED_VALIDATE_ENV_RECORDS=str(records))
result = subprocess.run([make, "-f", str(makefile), "validate-inner"], cwd=makefile.parent,
                        env=environment, text=True, capture_output=True, timeout=30)
assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
entries = [json.loads(line) for line in records.read_text(encoding="utf-8").splitlines()]
print(json.dumps({"validate_inner_recipes": entries}, sort_keys=True), flush=True)
meta = ["tests/test-phase0-aggregate.sh", "scripts/test-phase0.sh", "tests/test-native-gate.sh",
        "tests/test-native-gate-watch.sh", "tests/test-carplay-config.sh"]
shell = [entry for entry in entries if entry["executable"] == "bash"]
assert [entry["args"] for entry in shell] == [[name] for name in meta] + [["scripts/verify-once-gate.sh", "headless"]], entries
assert len(entries) == 8, entries
assert entries[-1] == shell[-1], "the real native gate must remain the last recipe"
for entry in shell[:-1]:
    assert entry["environment"]["WILTED_GATE_LEGS"] is None, ("meta selection leaked", entry)
    assert entry["environment"]["WILTED_NATIVE_RESULTS_DIR"] is None, ("meta results leaked", entry)
assert shell[-1]["environment"]["WILTED_GATE_LEGS"] == selection, shell[-1]
assert shell[-1]["environment"]["WILTED_NATIVE_RESULTS_DIR"] == destination, shell[-1]
assert all(entry["environment"]["WILTED_MAC_UI"] == "0" for entry in entries), entries
print("validate-inner environment isolation passed: meta=5 native=1 recipes=8")

# A failing step never stops validate-inner: every later step still runs, and the
# run fails once at the end naming every failed step.
records.unlink()
failing = dict(environment, WILTED_VALIDATE_FAKE_FAIL="scripts/test-phase0.sh")
result = subprocess.run([make, "-f", str(makefile), "validate-inner"], cwd=makefile.parent,
                        env=failing, text=True, capture_output=True, timeout=30)
assert result.returncode != 0, (result.returncode, result.stdout, result.stderr)
entries = [json.loads(line) for line in records.read_text(encoding="utf-8").splitlines()]
assert len(entries) == 8 and entries[-1]["args"] == ["scripts/verify-once-gate.sh", "headless"], entries
assert "validate.failed count=1 steps=phase0" in result.stderr, result.stderr
assert not list((root / "scratch").glob("wilted-validate-failures.*")), "failure note leaked"
print("validate-inner runs every step after a failure: recipes=8 failed=phase0")
PY

# A gate copy cut off right after one of its EXIT traps and ending in a parse
# error must fail. Bash leaves $? at 0 for a parse error, so a trap that only
# returned $? let an edit made during a run turn a failed leg into a pass.
truncated_gate_status() {
  local source="$1" stop="$2" fixture="$3" helper copy
  mkdir -p "$fixture/scripts" "$fixture/scratch"
  ln -s "$repo_root/scripts/lib" "$fixture/scripts/lib"
  for helper in run-bounded.py check-temp-leaks.py build-with-cache.py; do
    ln -s "$repo_root/scripts/$helper" "$fixture/scripts/$helper"
  done
  copy="$fixture/scripts/$(basename "$source")"
  awk -v stop="$stop" '{ print } $0 == stop { exit }' "$source" >"$copy"
  grep -Fxq -- "$stop" "$copy" || { printf 'truncation line missing: %s\n' "$stop" >&2; exit 1; }
  printf '%s\n' 'echo "unterminated' >>"$copy"
  set +e
  env TMPDIR="$fixture/scratch" bash "$copy" >"$fixture/output.log" 2>&1
  local result=$?
  set -e
  printf '%s\n' "$result"
}

for truncation in "trap 'cleanup_phase0_initialization; exit 129' HUP|during initialization" "trap 'cleanup_phase0; exit 129' HUP|before its verdict"; do
  truncated_status="$(truncated_gate_status "$phase0_script" "${truncation%%|*}" "$tmp_dir/truncated-${truncation##*|}")"
  [[ "$truncated_status" -ne 0 ]] || { cat "$tmp_dir/truncated-${truncation##*|}/output.log" >&2; printf 'a truncated phase 0 passed\n' >&2; exit 1; }
  grep -Fq "phase0.error stopped ${truncation##*|}" "$tmp_dir/truncated-${truncation##*|}/output.log" || {
    cat "$tmp_dir/truncated-${truncation##*|}/output.log" >&2; exit 1; }
done

printf '%s\n' "phase0 aggregate meta-test passed (self-test count=${expected_count})"
