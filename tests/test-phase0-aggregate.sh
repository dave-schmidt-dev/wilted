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

expected_legs=(
  "test-build-with-cache"
  "test-bounded-entry"
  "test-no-global-tmp"
  "assert-mac-first-docs"
  "test-contract-fixtures"
  "test-domain-contract"
  "test-cloudkit-contract"
  "test-article-extraction-probe"
  "test-speech-ipc-probe"
  "test-persistence-probe"
  "test-audio-contract-probe"
  "test-audit-walkthrough"
  "test-pipeline-worker"
  "test-preparation-runtime"
  "test-install-mac-app"
  "test-install-mac-contract"
  "test-temp-sweep"
  "test-storage-retention"
  "test-temp-leaks"
  "test-git-hooks"
  "test-simulator-cleanup"
  "test-native-ui-receipt"
  "test-release-wrappers"
  "test-file-size"
  "test-attended-library-sync"
  "test-core-reliability-prototype"
  "test-test-product-metadata"
)
if [[ -f "$repo_root/tests/test-audio-contract-ios-build.sh" ]]; then
  expected_legs+=("test-audio-contract-ios-build")
fi
if [[ -f "$repo_root/tests/test-audio-budget-evidence.sh" ]]; then
  expected_legs+=("test-audio-budget-evidence")
fi
expected_legs+=("test-signed-speech-runtime")

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

run_and_capture() {
  local label="$1"
  local output_file="$2"
  local status="$3"
  printf '%s\n' "meta-test[$label] status=$status"
  if [[ "$status" -ne 0 ]]; then
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

assert_contains 'run_leg_async "assert-mac-first-docs" "$repo_root/tests/test-mac-first-docs.sh"' "$phase0_script"
assert_contains 'run_leg_async "test-bounded-entry" "$repo_root/tests/test-bounded-entry.sh"' "$phase0_script"
assert_contains 'run_leg_async "test-storage-retention" "$repo_root/tests/test-storage-retention.sh"' "$phase0_script"
assert_contains 'run_leg_async "test-temp-leaks" "$repo_root/tests/test-temp-leaks.sh"' "$phase0_script"
assert_contains 'python3 "$bounded_runner" --timeout-seconds "$phase0_leg_timeout_seconds" --' "$phase0_script"
assert_contains 'trap '\''cleanup_phase0; exit 129'\'' HUP' "$phase0_script"
assert_contains 'run_leg_async "test-simulator-cleanup" "$repo_root/tests/test-simulator-cleanup.sh"' "$phase0_script"
assert_contains 'run_leg_async "test-core-reliability-prototype" "$repo_root/tests/test-core-reliability-prototype.sh"' "$phase0_script"

tmp_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-phase0-agg.XXXXXX")"
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
run_and_capture "forced" "$forced_output" "$forced_status"
assert_nonzero_exit "$forced_status" "forced phase0 self-test"
assert_contains "phase0.failed count=1" "$forced_output"
assert_contains "phase0.leg.complete name=$forced_leg status=1 reason=self-test-forced-failure" "$forced_output"
assert_contains "forced_self_test_failure" "$forced_output"

printf '%s\n' "phase0 aggregate meta-test passed (self-test count=${expected_count})"
