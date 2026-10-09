#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
ROOT = Path(sys.argv[1])

class ParallelGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wilted-parallel-', dir=os.environ['TMPDIR'])
        self.root = Path(self.temp.name)
        self.script = self.root / 'fixture.sh'
        self.script.write_text('''#!/bin/bash
set -Eeuo pipefail
repo_root="$1"; tmp_root="$2"
source "$repo_root/scripts/lib/test-runner.sh"
source "$repo_root/scripts/lib/native-gate-parallel.sh"
source "$repo_root/scripts/lib/native-gate-legs.sh"
failed_legs=0; completed_legs=0; deferred_legs=0; deferred_leg_names=()
status() { printf '%s\\n' "$1" >&2; }
is_deferred_leg() { return 1; }
trap 'wilted_gate_stop_parallel' EXIT
trap 'exit 143' TERM
run_leg() {
  local name="$1"
  printf 'start %s\\n' "$name" >>"$tmp_root/events"
  : >"$tmp_root/$name.started"
  (exec sh -c 'echo "$PPID"') >"$tmp_root/$name.pid"
  # All selected independent workers rendezvous before any can finish. Host
  # scheduling jitter cannot make the overlap assertion depend on sleep margins.
  case "$name" in
    xcodegen-reproducible|package-one|package-two)
      local peer
      for peer in xcodegen-reproducible package-one package-two; do
        wilted_gate_leg_selected "$peer" || continue
        until [[ -f "$tmp_root/$peer.started" ]]; do sleep .05; done
      done ;;
  esac
  if [[ "$name" == xcodegen-reproducible && "${HOLD_XCODEGEN:-}" == supervised ]]; then
    wilted_start_supervisor python3 "$repo_root/scripts/run-bounded.py" --timeout-seconds 120 -- sleep 60
    wilted_wait_active_supervisor
  elif [[ "$name" == xcodegen-reproducible && "${HOLD_XCODEGEN:-}" == wait ]]; then
    while :; do sleep .05; done
  fi
  [[ "$name" != "${FAIL_LEG:-}" ]] || failed_legs=1
  completed_legs=1
  printf 'end %s\\n' "$name" >>"$tmp_root/events"
}
leg_names=(xcodegen-reproducible package-one package-two ios-unit-tests)
leg_fns=(unused unused unused unused); leg_reports=(none none none none)
wilted_gate_run_legs
printf '%s %s %s\\n' "$failed_legs" "$completed_legs" "$deferred_legs"
''')
    def tearDown(self): self.temp.cleanup()
    def execute(self, failure=None, extra=None):
        env = os.environ.copy()
        if failure: env['FAIL_LEG'] = failure
        env.update(extra or {})
        return subprocess.run(['bash', str(self.script), str(ROOT), str(self.root)], env=env,
                              text=True, capture_output=True, timeout=60)
    def test_independent_overlap_and_project_dependency(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '0 4 0')
        events = (self.root / 'events').read_text().splitlines()
        for name in ['package-one', 'package-two']:
            self.assertLess(events.index('start ' + name), events.index('end xcodegen-reproducible'))
        self.assertLess(events.index('start package-one'), events.index('end package-two'))
        self.assertLess(events.index('start package-two'), events.index('end package-one'))
        self.assertLess(events.index('end xcodegen-reproducible'), events.index('start ios-unit-tests'))
    def test_mixed_failure_aggregates_every_independent_leg(self):
        result = self.execute('package-one')
        self.assertEqual(result.stdout.strip(), '1 4 0', result.stderr)
        self.assertIn('end package-two', (self.root / 'events').read_text())
    def test_failed_dependency_refuses_app_but_completes_packages(self):
        result = self.execute('xcodegen-reproducible')
        self.assertEqual(result.stdout.strip(), '2 4 0', result.stderr)
        self.assertIn('reason=dependency-failed', result.stderr)
        self.assertNotIn('start ios-unit-tests', (self.root / 'events').read_text())
    def test_filtered_app_auto_selects_xcodegen(self):
        result=self.execute(extra={'WILTED_GATE_LEGS':'ios-unit-tests'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '0 2 0')
        events=(self.root / 'events').read_text().splitlines()
        self.assertEqual(events, ['start xcodegen-reproducible', 'end xcodegen-reproducible', 'start ios-unit-tests', 'end ios-unit-tests'])
    def test_receipt_published_between_missing_check_and_dead_pid_wins(self):
        fixture = self.root / 'receipt-race.sh'
        fixture.write_text('#!/bin/bash\nset -Eeuo pipefail\nrepo_root="$1"; tmp_root="$2"\nsource "$repo_root/scripts/lib/native-gate-parallel.sh"\nstatus() { printf \'%s\\n\' "$*" >&2; }\nwilted_stop_active_ui_lock() { :; }\nwilted_stop_active_supervisor() { :; }\nwilted_finish_logger() { :; }\nrun_leg() { printf \'app-ran\\n\'; completed_legs=1; }\n# Called only after the loop observed no receipt: publish a passing receipt\n# and model the worker having exited before the liveness check completes.\nkill() { printf \'0 1 0\\n\' >"$tmp_root/xcodegen.result"; return 1; }\nwilted_gate_parallel_worker app none unused xcodegen 12345\ncat "$tmp_root/app.result"\n')
        result = subprocess.run(['bash', str(fixture), str(ROOT), str(self.root)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['app-ran', '0 1 0'])
        self.assertNotIn('dependency-dead', result.stderr)

    def test_sigkill_dependency_without_receipt_fails_and_drains(self):
        process=subprocess.Popen(['bash', str(self.script), str(ROOT), str(self.root)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 env=dict(os.environ, HOLD_XCODEGEN='wait'))
        try:
            deadline=time.monotonic()+20
            while not (self.root / 'xcodegen-reproducible.pid').exists() and time.monotonic()<deadline: time.sleep(.02)
            pid=int((self.root / 'xcodegen-reproducible.pid').read_text())
            os.kill(pid, signal.SIGKILL)
            out,err=process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, err)
            self.assertEqual(out.strip(), '2 4 0')
            self.assertIn('native.worker.failed name=xcodegen-reproducible', err)
            self.assertRegex(err, r'reason=dependency-(dead|failed)')
            self.assertNotIn('start ios-unit-tests', (self.root / 'events').read_text())
        finally:
            if process.poll() is None: process.terminate(); process.communicate(timeout=60)

    def test_signal_waits_for_worker_cleanup(self):
        process = subprocess.Popen(['bash', str(self.script), str(ROOT), str(self.root)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   env=dict(os.environ, HOLD_XCODEGEN='supervised'))
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'events').exists() and time.monotonic() < deadline: time.sleep(.02)
            process.terminate()
            try:
                out, err = process.communicate(timeout=50)
            except subprocess.TimeoutExpired as error:
                print(error.stderr, file=sys.stderr)
                raise
            self.assertEqual(process.returncode, 143, err)
            for name in ['xcodegen-reproducible', 'ios-unit-tests']:
                self.assertTrue((self.root / (name + '.result')).exists())
        finally:
            if process.poll() is None: process.kill(); process.wait()

unittest.main(argv=['parallel-gate-tests'], verbosity=2)
PY
