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
