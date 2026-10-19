#!/usr/bin/env bash
# The persistent simulator lane: one lock for every worktree of the repository,
# and a boot another lane won first is never shut down by this one.
set -Eeuo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$repo_root" <<'PY'
import fcntl
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import unittest
ROOT = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('native_gate_xcode_fixture', ROOT / 'tests/native_gate_xcode_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
RUNTIME, UDID = fixture.RUNTIME, fixture.UDID

class SimulatorLaneTests(fixture.XcodeFixture, unittest.TestCase):
    repository_root = ROOT
    def test_boot_raced_by_another_lane_is_not_shut_down(self):
        self.select()
        result=self.session(dict(self.env, FAKE_BOOT_RACE='1'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('native.simulator.boot.raced', result.stderr)
        self.assertNotIn('simctl shutdown', self.events.read_text())
        self.assertEqual(json.loads(self.state.read_text())['devices'][RUNTIME][0]['state'], 'Booted')
    def test_ios_build_runs_outside_lane_and_host_ui_locks(self):
        self.select()
        script=self.write_ios_leg_script()
        (self.bin / 'ui-lock').write_text('#!/bin/bash\nwhile [[ "$1" != -- ]]; do shift; done\nshift\necho "ui-lock acquired" >>"$FAKE_EVENTS"\nexec "$@"\n')
        lock_dir=self.root / '.build/simulator-locks'; lock_dir.mkdir(parents=True, exist_ok=True)
        lock_file=(lock_dir / (hashlib.sha256(RUNTIME.encode()).hexdigest()[:16] + '.lock')).open('a+')
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        process=subprocess.Popen(['bash', str(script), str(self.root)],
                                 env=dict(self.env, FAKE_BUILD_DELAY='.2', FAKE_TEST_DELAY='.1'),
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        released=False
        try:
            deadline=time.monotonic()+20
            while 'build end' not in self.events.read_text() and time.monotonic()<deadline: time.sleep(.02)
            self.assertIn('build end', self.events.read_text())
            time.sleep(1)
            events=self.events.read_text()
            self.assertNotIn('test start', events)
            self.assertNotIn('ui-lock acquired', events)
            self.assertNotIn('simctl boot', events)
            fcntl.flock(lock_file, fcntl.LOCK_UN); released=True
            out,err=process.communicate(timeout=60)
            self.assertEqual(process.returncode, 0, err)
            events=self.events.read_text().splitlines()
            order=['build start', 'build end', 'ui-lock acquired', 'test start', 'test end']
            positions=[events.index(event) for event in order]
            self.assertEqual(positions, sorted(positions))
        finally:
            if process.poll() is None: process.terminate(); process.communicate(timeout=60)
            if not released: fcntl.flock(lock_file, fcntl.LOCK_UN)
            lock_file.close()
    def test_worktrees_of_one_repository_share_the_simulator_lane(self):
        self.select()
        env={k: v for k, v in self.env.items() if not k.startswith('GIT_')}
        git=['git', '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', '-C', str(self.root)]
        for args in (['init', '-q'], ['add', 'scripts'], ['commit', '-qm', 'fixture'], ['worktree', 'add', '-q', str(self.root / 'wt')]):
            subprocess.run(git + args, env=env, check=True, capture_output=True, timeout=60)
        command=lambda root: ['bash', str(root / 'scripts/lib/native-gate-simulator.sh'), 'run', str(root), UDID,
                              sys.executable, str(root / 'scripts/build-with-cache.py'), 'run', 'xcode', 'native-ios-unit-tests',
                              '--', 'xcodebuild', 'test-without-building']
        first=subprocess.Popen(command(self.root), env=dict(env, FAKE_TEST_DELAY='2'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline=time.monotonic()+20
            while 'test start' not in self.events.read_text() and time.monotonic()<deadline: time.sleep(.02)
            second=self.invoke(*command(self.root / 'wt'), env=env)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn('native.simulator.wait', second.stderr)
            first.communicate(timeout=60); self.assertEqual(first.returncode, 0)
            events=[e for e in self.events.read_text().splitlines() if e.startswith('test ')]
            self.assertEqual(events, ['test start', 'test end', 'test start', 'test end'])
            self.assertTrue(list((self.root / '.git/wilted-simulator-locks').glob('*.lock')))
            self.assertFalse((self.root / 'wt/.build/simulator-locks').exists())
        finally:
            if first.poll() is None: first.terminate(); first.communicate(timeout=60)

unittest.main(argv=['simulator-lane-tests'], verbosity=2)
PY
