#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Meta-tests for the WILTED_GATE_LEGS single-leg filter in scripts/test-gate.sh.
# They run the gate in its self-test mode, which stubs every leg, so no app,
# simulator or XCUITest is launched. (tests/test-native-gate.sh is at the file
# size ceiling, so the filter cases live here.)
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/test-gate.sh"
# shellcheck source=../scripts/lib/temp-sweep.sh
source "$repo_root/scripts/lib/temp-sweep.sh"
wilted_sweep_stale_temp_dirs
source "$repo_root/scripts/lib/test-temp-state.sh"
tmp_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-native-gate-legs.XXXXXX")"; wilted_temp_mark_owned "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

# Usage: run_case <label> <output file> [env assignments...]; echoes the exit status.
run_case() {
  local label="$1" output="$2" result
  shift 2
  mkdir -p "$tmp_dir/$label-parent"
  set +e
  env TMPDIR="$tmp_dir/$label-parent" NATIVE_SELF_TEST=1 WILTED_MAC_UI=0 \
    WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$tmp_dir/diagnostics/$label" \
    "$@" bash "$gate" >"$output" 2>&1
  result=$?
  set -e
  printf 'meta-test[%s] status=%s\n' "$label" "$result" >&2
  printf '%s\n' "$result"
}

assert_contains() {
  grep -Fq -- "$1" "$2" || { printf 'assertion failed: missing %s\n' "$1" >&2; cat "$2" >&2; exit 1; }
}

assert_absent() {
  if grep -Fq -- "$1" "$2"; then printf 'assertion failed: unexpected %s\n' "$1" >&2; cat "$2" >&2; exit 1; fi
}

# Unknown, empty and malformed names fail closed before any leg starts.
for case_spec in 'unknown|no-such-leg' 'mixed|wiltedkit-tests,no-such-leg' 'empty-value|' 'empty-name|wiltedkit-tests,,playback-tests'; do
  label="${case_spec%%|*}" value="${case_spec#*|}"
  log="$tmp_dir/$label.log"
  [[ "$(run_case "$label" "$log" "WILTED_GATE_LEGS=$value")" -ne 0 ]] || { cat "$log" >&2; exit 1; }
  assert_contains 'native.error' "$log"
  assert_absent 'native.leg.start' "$log"
  assert_absent 'native.simulator.sweep' "$log"
  assert_absent 'native.passed' "$log"
done
assert_contains 'unknown leg in WILTED_GATE_LEGS: "no-such-leg"' "$tmp_dir/unknown.log"
assert_contains 'WILTED_GATE_LEGS is set but empty' "$tmp_dir/empty-value.log"

# One leg runs, the rest are named as skipped, and the pass line is qualified.
log="$tmp_dir/single.log"
[[ "$(run_case single "$log" WILTED_GATE_LEGS=wiltedkit-tests)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.start name=wiltedkit-tests' "$log"
[[ "$(grep -c '^native.leg.start' "$log")" -eq 1 ]] || { cat "$log" >&2; exit 1; }
[[ "$(grep -c '^native.leg.skipped' "$log")" -eq 8 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.skipped name=macos-ui-tests reason=not-in-WILTED_GATE_LEGS' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=1 deferred_legs=0' "$log"
assert_contains 'native.filtered selected=wiltedkit-tests skipped=xcodegen-reproducible cloudsync-tests' "$log"
assert_contains 'receipt=never' "$log"
assert_contains 'native.passed count=1 filtered=8' "$log"
if grep -Eq '^native\.passed count=[0-9]+$' "$log"; then
  printf '%s\n' 'assertion failed: a filtered run emitted the unqualified native.passed line' >&2
  exit 1
fi

# An app leg brings the XcodeGen leg that generates its project.
log="$tmp_dir/app-leg.log"
[[ "$(run_case app-leg "$log" WILTED_GATE_LEGS=macos-unit-tests)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.start name=xcodegen-reproducible' "$log"
assert_contains 'native.leg.start name=macos-unit-tests' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=2 deferred_legs=0' "$log"

# Selecting the screen-seizing leg without the opt-in still defers it, and says so.
log="$tmp_dir/deferred.log"
[[ "$(run_case deferred "$log" WILTED_GATE_LEGS=playback-tests,macos-ui-tests)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.leg.deferred name=macos-ui-tests' "$log"
assert_contains 'native.complete failed_legs=0 total_legs=1 deferred_legs=1' "$log"
assert_contains 'native.passed count=1 deferred=1 filtered=7' "$log"

# An unfiltered run is unchanged: nine stubbed legs, no filter lines.
log="$tmp_dir/full.log"
[[ "$(run_case full "$log" WILTED_MAC_UI=1)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.complete failed_legs=0 total_legs=9 deferred_legs=0' "$log"
assert_contains 'native.passed count=9' "$log"
assert_absent 'native.filtered' "$log"
assert_absent 'native.leg.skipped' "$log"

# A full validate's evidence option must not reserve its directory in Phase0 fake gates.
log="$tmp_dir/inherited-results.log"
inherited_results="$tmp_dir/not-an-evidence-root"
mkdir -p "$inherited_results"; printf foreign >"$inherited_results/keep"
[[ "$(run_case inherited-results "$log" "WILTED_NATIVE_RESULTS_DIR=$inherited_results")" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_absent 'native.results.prepare' "$log"
[[ "$(cat "$inherited_results/keep")" == foreign && "$(find "$inherited_results" -type f | wc -l | tr -d ' ')" == 1 ]] || exit 1

# A failing app leg that re-enables errexit before returning (xcode_test_leg does) must
# still retain its bundle and reach native.leg.complete instead of ending the aggregate.
# Exercise the real run_leg body with collaborators stubbed: every Mac/iOS/Watch app leg
# retains on failure and clears on success, while package legs do neither.
write_run_leg_harness() {
  local harness="$1" without_watch_retention="$2"
  {
    printf '%s\n' 'set -Eeuo pipefail' 'tmp_root="$1"; native_self_test=0; declare -i completed_legs=0 failed_legs=0'
    printf '%s\n' 'status() { printf "%s\n" "$*"; }' 'wilted_temp_prepare_leg() { WILTED_TEMP_LEG_WORK="$tmp_root"; }'
    printf '%s\n' 'is_deferred_leg() { return 1; }' 'is_forced_failure() { return 1; }' 'is_forced_zero() { return 1; }'
    printf '%s\n' 'wilted_start_logger() { exec 9>"$1"; }' 'wilted_finish_logger() { exec 9>&-; }'
    printf '%s\n' 'wilted_temp_audit_leg() { return 0; }' 'clear_ui_failure_bundle() { echo "cleared $1"; }'
    printf '%s\n' 'retain_ui_failure_bundle() { echo "retained $1"; }' 'errexit_leg() { set -e; return 3; }' 'passing_leg() { return 0; }'
    printf '%s\n' 'retain_native_success_bundle() { return 0; }'
    if [[ "$without_watch_retention" == 1 ]]; then
      sed 's/ || "$name" == watchos-\*//' < <(sed -n '/^run_leg() {/,/^}/p' "$gate")
    else
      sed -n '/^run_leg() {/,/^}/p' "$gate"
    fi
    printf '%s\n' \
      'run_leg macos-unit-tests none errexit_leg' \
      'run_leg ios-unit-tests none errexit_leg' \
      'run_leg watchos-unit-tests none errexit_leg' \
      'run_leg macos-unit-tests none passing_leg' \
      'run_leg ios-unit-tests none passing_leg' \
      'run_leg watchos-unit-tests none passing_leg' \
      'run_leg wiltedkit-tests none errexit_leg' \
      'run_leg wiltedkit-tests none passing_leg' \
      'echo "after failed_legs=$failed_legs"'
  } >"$harness"
}

harness="$tmp_dir/run-leg-harness.sh"
write_run_leg_harness "$harness" 0
mkdir -p "$tmp_dir/run-leg-root"
bash "$harness" "$tmp_dir/run-leg-root" >"$tmp_dir/run-leg.log" 2>&1 || { cat "$tmp_dir/run-leg.log" >&2; exit 1; }
for name in macos-unit-tests ios-unit-tests watchos-unit-tests; do
  assert_contains "retained $name" "$tmp_dir/run-leg.log"
  assert_contains "cleared $name" "$tmp_dir/run-leg.log"
done
assert_absent 'retained wiltedkit-tests' "$tmp_dir/run-leg.log"
assert_absent 'cleared wiltedkit-tests' "$tmp_dir/run-leg.log"
assert_contains 'native.leg.complete name=watchos-unit-tests status=3' "$tmp_dir/run-leg.log"
assert_contains 'after failed_legs=4' "$tmp_dir/run-leg.log"

# Negative control: a copied harness with Watch retention removed must not retain its
# failed Watch result. It only transforms the scratch copy; the source gate is untouched.
negative_harness="$tmp_dir/run-leg-no-watch-retention.sh"
write_run_leg_harness "$negative_harness" 1
bash "$negative_harness" "$tmp_dir/run-leg-root" >"$tmp_dir/run-leg-negative.log" 2>&1 || {
  cat "$tmp_dir/run-leg-negative.log" >&2; exit 1;
}
assert_absent 'retained watchos-unit-tests' "$tmp_dir/run-leg-negative.log"
assert_contains 'native.leg.complete name=watchos-unit-tests status=3' "$tmp_dir/run-leg-negative.log"

# Exercise terminal retention through the real run_leg and real copy helper.
python3 - "$repo_root" "$tmp_dir" <<'PYRETENTION'
import subprocess
import sys
import unittest
from pathlib import Path
ROOT, WORK = map(Path, sys.argv[1:])

class TerminalRetentionTests(unittest.TestCase):
    def execute(self, case, action='success', leg='ios-unit-tests', destination=True, negative=False):
        base = (WORK / ('retention-' + case)).resolve(); base.mkdir()
        repo = base / 'repo'; (repo / '.logs').mkdir(parents=True)
        scratch = base / 'scratch'; scratch.mkdir()
        evidence = repo / '.logs' / 'results'
        prelude = f'''set -Eeuo pipefail
repo_root={str(repo)!r}; tmp_root={str(scratch)!r}
bounded_runner={str(ROOT / 'scripts/run-bounded.py')!r}; native_leg_timeout_seconds=30
native_results_dir={str(evidence) if destination else ''!r}
native_self_test=0; declare -i completed_legs=0 failed_legs=0 deferred_legs=0; deferred_leg_names=()
status() {{ printf '%s\\n' "$*"; }}
source {str(ROOT / 'scripts/lib/native-gate-validation.sh')!r}
wilted_temp_prepare_leg() {{ WILTED_TEMP_LEG_WORK="$tmp_root"; }}
is_deferred_leg() {{ [[ {action!r} == deferred ]]; }}
is_forced_failure() {{ return 1; }}; is_forced_zero() {{ return 1; }}
wilted_start_logger() {{ exec 9>"$1"; }}; wilted_finish_logger() {{ exec 9>&-; touch "$tmp_root/logger-finished"; }}
wilted_temp_audit_leg() {{ return 0; }}
assert_result_bundle_tests() {{ [[ -f "$tmp_root/logger-finished" && {action!r} != zero ]]; }}
clear_ui_failure_bundle() {{ :; }}; retain_ui_failure_bundle() {{ return 7; }}
producer() {{
 [[ {action!r} == publishfail || ! -e "$native_results_dir/$1.xcresult" ]] || return 9
 [[ {action!r} == missing ]] && return 0
 mkdir -p "$tmp_root/$1.xcresult/Data"
 printf complete >"$tmp_root/$1.xcresult/Info.plist"
 printf actual >"$tmp_root/$1.xcresult/Data/terminal"
 [[ {action!r} == copyfail ]] && ln -s /nonexistent-retention-fixture "$tmp_root/$1.xcresult/Data/broken"
 [[ {action!r} == childfail ]] && return 3
 return 0
}}
trap 'rm -rf "$tmp_root"' EXIT
prepare_native_results_dir || exit $?
'''
        gate_source = (ROOT / 'scripts/test-gate.sh').read_text()
        for name in ['prepare_native_results_dir', 'retain_native_success_bundle']:
            function = name + '() {' + gate_source.split(name + '() {',1)[1].split('\n}\n',1)[0] + '\n}\n'
            prelude = prelude.replace('prepare_native_results_dir || exit $?\n', function + 'prepare_native_results_dir || exit $?\n')
        body = (ROOT / 'scripts/test-gate.sh').read_text().split('run_leg() {',1)[1].split('\n}\n',1)[0]
        if negative:
            body = body.replace('retain_native_success_bundle "$name" "$result_bundle"', ':')
        script = prelude + 'run_leg() {' + body + '\n}\n'
        if action == 'publishfail':
            script += f'mkdir -p {str(evidence / (leg + ".xcresult"))!r}\nprintf foreign >{str(evidence / (leg + ".xcresult") / "foreign")!r}\n'
        script += f'run_leg {leg!r} count producer {leg!r}\necho "final failed=$failed_legs completed=$completed_legs"\n'
        run = subprocess.run(['bash','-c',script],text=True,capture_output=True,timeout=90)
        self.assertEqual(run.returncode,0,run.stdout+run.stderr)
        self.assertFalse(scratch.exists(),run.stdout+run.stderr)
        return evidence, run.stdout+run.stderr

    def test_three_complete_trees_survive_terminal_cleanup(self):
        for leg in ['macos-unit-tests','ios-unit-tests','ios-pixel-snapshot-tests']:
            with self.subTest(leg=leg):
                evidence,log=self.execute(leg,leg=leg)
                self.assertEqual((evidence/(leg+'.xcresult')/'Data/terminal').read_text(),'actual')
                self.assertIn('final failed=0',log)
                self.assertLess(log.index('native.results.complete'),log.index('native.leg.complete'))

    def test_unset_deferred_package_do_not_publish(self):
        for case,action,leg,dest in [('unset','success','ios-unit-tests',False),('deferred','deferred','macos-ui-tests',True),('package','success','wiltedkit-tests',True)]:
            with self.subTest(case=case):
                evidence,_=self.execute(case,action,leg,dest)
                self.assertFalse((evidence/(leg+'.xcresult')).exists())

    def test_failures_still_finish_and_clean(self):
        for action in ['missing','zero','childfail','copyfail','publishfail']:
            with self.subTest(action=action):
                evidence,log=self.execute(action,action)
                self.assertIn('final failed=1 completed=1',log)
                if action=='childfail': self.assertIn('status=3',log)
                if action=='publishfail': self.assertEqual((evidence/'ios-unit-tests.xcresult/foreign').read_text(),'foreign')
                else: self.assertFalse((evidence/'ios-unit-tests.xcresult').exists())
                self.assertFalse(list(evidence.glob('.*.staging*')))

    def test_negative_control_omits_retention(self):
        evidence,_=self.execute('negative',negative=True)
        self.assertFalse((evidence/'ios-unit-tests.xcresult').exists())

    def test_destination_refusals_preserve_foreign_bytes(self):
        for case in ['existing','symlink','escape']:
            with self.subTest(case=case):
                repo=(WORK/('refusal-'+case)).resolve(); (repo/'.logs').mkdir(parents=True)
                foreign=repo/'foreign';foreign.mkdir();(foreign/'keep').write_text('foreign')
                dest=repo/'.logs/results'
                if case=='existing': dest.mkdir();(dest/'keep').write_text('foreign')
                if case=='symlink': dest.symlink_to(foreign,target_is_directory=True)
                if case=='escape': dest=repo/'.logs/../escaped'
                source = (ROOT/'scripts/test-gate.sh').read_text()
                function = 'prepare_native_results_dir() {' + source.split('prepare_native_results_dir() {',1)[1].split('\n}\n',1)[0] + '\n}\n'
                script=f'repo_root={str(repo)!r}; native_results_dir={str(dest)!r}\n' + function + 'prepare_native_results_dir'
                run=subprocess.run(['bash','-c',script],capture_output=True,text=True,timeout=15)
                self.assertNotEqual(run.returncode,0,run.stdout+run.stderr)
                self.assertEqual((foreign/'keep').read_text(),'foreign')
                if case=='existing': self.assertEqual((dest/'keep').read_text(),'foreign')
                if case=='symlink': self.assertTrue(dest.is_symlink())

unittest.main(argv=[sys.argv[0]],verbosity=2)
PYRETENTION

# Unit selectors and iteration counts are diagnostics: the gate accepts a
# valid selection through its normal validation path before any leg starts.
for spec in \
  'unit-mac-class|macos-unit-tests|WILTED_MAC_UNIT_SELECTORS=WiltedMacFooTests' \
  'unit-mac-selectors|macos-unit-tests|WILTED_MAC_UNIT_SELECTORS=WiltedMacFooTests/testBar,WiltedMacBazTests' \
  'unit-ios-class|ios-unit-tests|WILTED_IOS_UNIT_SELECTORS=WiltediOSFooTests' \
  'unit-ios-selectors|ios-unit-tests|WILTED_IOS_UNIT_SELECTORS=WiltediOSFooTests/testBar,WiltediOSBazTests' \
  'unit-mac-iterations|macos-unit-tests|WILTED_MAC_UNIT_ITERATIONS=3' \
  'unit-ios-iterations|ios-unit-tests|WILTED_IOS_UNIT_ITERATIONS=3'; do
  label="${spec%%|*}"; spec="${spec#*|}"; leg="${spec%%|*}"; assignment="${spec#*|}"
  log="$tmp_dir/$label.log"
  [[ "$(run_case "$label" "$log" "WILTED_GATE_LEGS=$leg" "$assignment")" -eq 0 ]] || { cat "$log" >&2; exit 1; }
done

# Every malformed selector and iteration count fails closed before a leg starts.
reject_selector_values=('' 'A,,B' 'A,' ',A' 'A B' 'A/testB/testC' 'A/b' 'A;true' 'A$(true)' '-only-testing:X' '../A')
reject_iteration_values=('' '0' '101' '3x' '-1')
reject_index=0
for family in mac ios; do
  if [[ "$family" == mac ]]; then
    leg=macos-unit-tests; selectors_var=WILTED_MAC_UNIT_SELECTORS; iterations_var=WILTED_MAC_UNIT_ITERATIONS
  else
    leg=ios-unit-tests; selectors_var=WILTED_IOS_UNIT_SELECTORS; iterations_var=WILTED_IOS_UNIT_ITERATIONS
  fi
  for value in "${reject_selector_values[@]}"; do
    reject_index=$((reject_index + 1))
    label="reject-$family-selector-$reject_index"
    log="$tmp_dir/$label.log"
    [[ "$(run_case "$label" "$log" "WILTED_GATE_LEGS=$leg" "$selectors_var=$value")" -ne 0 ]] || { cat "$log" >&2; exit 1; }
    assert_contains 'native.error' "$log"
    assert_absent 'native.leg.start' "$log"
    assert_absent 'native.passed' "$log"
  done
  for value in "${reject_iteration_values[@]}"; do
    reject_index=$((reject_index + 1))
    label="reject-$family-iterations-$reject_index"
    log="$tmp_dir/$label.log"
    [[ "$(run_case "$label" "$log" "WILTED_GATE_LEGS=$leg" "$iterations_var=$value")" -ne 0 ]] || { cat "$log" >&2; exit 1; }
    assert_contains 'native.error' "$log"
    assert_absent 'native.leg.start' "$log"
    assert_absent 'native.passed' "$log"
  done
done

# A selected Mac unit test lowers the floor to one, so a misspelled class fails
# as native.zero-tests instead of passing an empty run.
(
  unset WILTED_MAC_UNIT_SELECTORS WILTED_MAC_UNIT_ITERATIONS WILTED_IOS_UNIT_SELECTORS WILTED_IOS_UNIT_ITERATIONS
  repo_root="$repo_root"
  native_self_test=0
  fail() { printf 'native.error %s\n' "$1" >&2; exit 1; }
  source "$repo_root/scripts/lib/native-gate-validation.sh"
  [[ "$(expected_test_count_floor macos-unit-tests)" == 30 ]]
  WILTED_MAC_UNIT_SELECTORS='Foo/testBar'
  [[ "$(expected_test_count_floor macos-unit-tests)" == 1 ]]
) || { printf '%s\n' 'assertion failed: unit selector floor' >&2; exit 1; }

# The selector summary names the filter, and the pass line is qualified even
# when no leg filter (WILTED_GATE_LEGS) is set.
log="$tmp_dir/unit-filtered-summary.log"
[[ "$(run_case unit-filtered-summary "$log" WILTED_GATE_LEGS=macos-unit-tests \
  WILTED_MAC_UNIT_SELECTORS=WiltedMacFooTests/testBar WILTED_MAC_UNIT_ITERATIONS=2)" -eq 0 ]] ||
  { cat "$log" >&2; exit 1; }
assert_contains 'native.filtered.tests leg=macos-unit-tests selectors=WiltedMacFooTests/testBar iterations=2 receipt=never' "$log"
assert_contains 'native.passed count=2 filtered=7' "$log"

log="$tmp_dir/unit-unfiltered-legs-summary.log"
[[ "$(run_case unit-unfiltered-legs-summary "$log" WILTED_MAC_UI=1 \
  WILTED_MAC_UNIT_SELECTORS=WiltedMacFooTests/testBar)" -eq 0 ]] ||
  { cat "$log" >&2; exit 1; }
assert_contains 'native.passed count=9 filtered=0' "$log"
if grep -Eq '^native\.passed count=[0-9]+$' "$log"; then
  printf '%s\n' 'assertion failed: a unit-filtered run emitted the unqualified native.passed line' >&2
  cat "$log" >&2
  exit 1
fi

# The selected -only-testing arguments and -test-iterations reach xcodebuild
# through the real xcode_test_leg, and an unselected run keeps today's argv.
write_xcode_harness() {
  local harness="$1"
  cat >"$harness" <<'HARNESS'
set -Eeuo pipefail
repo_root="$1"; tmp_root="$2"; label="$3"; scheme="$4"; destination="$5"; target="$6"
WILTED_TEMP_LEG_WORK="$tmp_root/work"
build_with_cache="$tmp_root/fake-build-with-cache"
xcode_test_timeout_seconds=1
xcode_build_and_test_timeout_seconds=1
record_argv="$tmp_root/argv-$label.txt"
mkdir -p "$tmp_root/fake/Fake.xcodeproj" "$WILTED_TEMP_LEG_WORK"
require_tool() { return 0; }
assert_test_sources() { return 0; }
find_project() { printf '%s\n' "$tmp_root/fake/Fake.xcodeproj"; }
wilted_mac_test_scheme_configure() { return 0; }
wilted_mac_test_cleanup_roots() { return 0; }
wilted_stop_active_ui_lock() { return 0; }
wilted_stop_active_supervisor() { return 0; }
wilted_wait_active_supervisor() { wait "$WILTED_ACTIVE_SUPERVISOR_PID"; }
gate_ui_test_lock() { printf '%s\n' "$@" >"$record_argv"; }
wilted_gate_simulator_session() { printf '%s\n' "$@" >"$record_argv"; }
# shellcheck source=/dev/null
source "$repo_root/scripts/lib/native-gate-xcode.sh"
wilted_testmanagerd_preflight() { :; }
xcode_test_leg "$label" "$tmp_root/sources" "$scheme" "$destination" "$target"
HARNESS
}

run_xcode_harness() {
  local leg="$1" scheme="$2" destination="$3" target="$4" mode="$5"
  shift 5
  local root="$tmp_dir/xcode-$leg-$mode" log="$tmp_dir/xcode-$leg-$mode.log"
  mkdir -p "$root"
  if [[ "$mode" == filtered ]]; then
    env "$@" bash "$xcode_harness" "$repo_root" "$root" "$leg" "$scheme" "$destination" "$target"
  else
    env -u WILTED_MAC_UNIT_SELECTORS -u WILTED_MAC_UNIT_ITERATIONS \
      -u WILTED_IOS_UNIT_SELECTORS -u WILTED_IOS_UNIT_ITERATIONS \
      bash "$xcode_harness" "$repo_root" "$root" "$leg" "$scheme" "$destination" "$target"
  fi >"$log" 2>&1 || { cat "$log" >&2; exit 1; }
  printf '%s\n' "$root/argv-$leg.txt"
}

assert_unit_argv() {
  local argv="$1" prefix="$2"
  assert_contains "-only-testing:$prefix/Foo/testBar" "$argv"
  assert_contains "-only-testing:$prefix/Baz" "$argv"
  awk -v first='-test-iterations' -v second='3' \
    'previous == first && $0 == second { found = 1 } { previous = $0 } END { exit !found }' "$argv" || {
    printf 'assertion failed: %s has no -test-iterations 3 pair\n' "$argv" >&2
    cat "$argv" >&2
    exit 1
  }
  if grep -Fxq -- "-only-testing:$prefix" "$argv"; then
    printf 'assertion failed: %s kept the bare -only-testing:%s\n' "$argv" "$prefix" >&2
    cat "$argv" >&2
    exit 1
  fi
}

xcode_harness="$tmp_dir/xcode-leg-harness.sh"
write_xcode_harness "$xcode_harness"
mac_argv="$(run_xcode_harness macos-unit-tests WiltedMac platform=macOS WiltedMacTests filtered \
  'WILTED_MAC_UNIT_SELECTORS=Foo/testBar,Baz' 'WILTED_MAC_UNIT_ITERATIONS=3')"
assert_unit_argv "$mac_argv" WiltedMacTests
ios_argv="$(run_xcode_harness ios-unit-tests WiltediOS 'platform=iOS Simulator,id=FAKE' WiltediOSTests filtered \
  'WILTED_IOS_UNIT_SELECTORS=Foo/testBar,Baz' 'WILTED_IOS_UNIT_ITERATIONS=3')"
assert_unit_argv "$ios_argv" WiltediOSTests
mac_unfiltered_argv="$(run_xcode_harness macos-unit-tests WiltedMac platform=macOS WiltedMacTests unfiltered)"
assert_contains '-only-testing:WiltedMacTests' "$mac_unfiltered_argv"
assert_absent '-test-iterations' "$mac_unfiltered_argv"
ios_unfiltered_argv="$(run_xcode_harness ios-unit-tests WiltediOS 'platform=iOS Simulator,id=FAKE' WiltediOSTests unfiltered)"
assert_contains '-only-testing:WiltediOSTests' "$ios_unfiltered_argv"
assert_absent '-test-iterations' "$ios_unfiltered_argv"

# The Make targets hand TEST and ITERATIONS to the gate through the
# environment, so a quote in TEST reaches validation instead of the shell.
run_make_case() {
  local label="$1" output="$2" result
  shift 2
  mkdir -p "$tmp_dir/$label-parent"
  set +e
  env -u WILTED_GATE_LEGS -u TEST -u ITERATIONS TMPDIR="$tmp_dir/$label-parent" NATIVE_SELF_TEST=1 WILTED_MAC_UI=0 \
    WILTED_MAC_UI_FAILURE_DIAGNOSTICS_DIR="$tmp_dir/diagnostics/$label" \
    make -s -C "$repo_root" "$@" >"$output" 2>&1
  result=$?
  set -e
  printf 'meta-test[%s] status=%s\n' "$label" "$result" >&2
  printf '%s\n' "$result"
}

log="$tmp_dir/make-mac-unit.log"
[[ "$(run_make_case make-mac-unit "$log" native-mac-unit TEST=WiltedMacFooTests/testBar ITERATIONS=2)" -eq 0 ]] ||
  { cat "$log" >&2; exit 1; }
assert_contains 'native.filtered.tests leg=macos-unit-tests selectors=WiltedMacFooTests/testBar iterations=2 receipt=never' "$log"
log="$tmp_dir/make-ios-unit.log"
[[ "$(run_make_case make-ios-unit "$log" native-ios-unit TEST=WiltediOSFooTests)" -eq 0 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'native.filtered.tests leg=ios-unit-tests selectors=WiltediOSFooTests iterations=1 receipt=never' "$log"
log="$tmp_dir/make-mac-unit-usage.log"
[[ "$(run_make_case make-mac-unit-usage "$log" native-mac-unit)" -eq 2 ]] || { cat "$log" >&2; exit 1; }
assert_contains 'usage: make native-mac-unit TEST=' "$log"
assert_absent 'native.leg.start' "$log"
make_marker="$tmp_dir/make-injection-marker"
log="$tmp_dir/make-mac-unit-quote.log"
[[ "$(run_make_case make-mac-unit-quote "$log" native-mac-unit "TEST=A';touch $make_marker;'")" -ne 0 ]] ||
  { cat "$log" >&2; exit 1; }
assert_contains 'native.error' "$log"
assert_absent 'native.leg.start' "$log"
[[ ! -e "$make_marker" ]] || { printf '%s\n' 'assertion failed: a quote in TEST ran a shell command' >&2; exit 1; }

printf '%s\n' 'native gate leg filter test passed'
