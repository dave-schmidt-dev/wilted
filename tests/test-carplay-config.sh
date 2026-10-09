#!/usr/bin/env bash
# CarPlay configuration contract (docs/carplay-requirements.md): the Development build signs manually
# with the CarPlay audio profile and carries the entitlement; Production carries it only when CarPlay
# is ready for every user (its icon appears for everyone); the scene manifest declares the CarPlay scene.
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }

ios_block="$(awk '/^  WiltediOS:/{f=1; next} f && /^  [A-Za-z]/{f=0} f' project.yml)"
dev_block="$(printf '%s\n' "$ios_block" | awk '/^        Development:/{f=1; next} f && /^        [A-Za-z]/{f=0} f')"
[[ -n "$dev_block" ]] || fail 'could not read the WiltediOS Development block'
for line in 'CODE_SIGN_STYLE: Manual' 'PROVISIONING_PROFILE_SPECIFIER: Wilted iOS Development' \
  'CODE_SIGN_ENTITLEMENTS: WiltediOS/WiltediOS.entitlements'; do
  printf '%s\n' "$dev_block" | grep -Fq "$line" || fail "iOS Development config lacks: $line"
done
plutil -p WiltediOS/WiltediOS.entitlements | grep -Fq 'com.apple.developer.carplay-audio' \
  || fail 'iOS Development entitlements lack the CarPlay audio key'
if plutil -p WiltediOS/WiltediOSProduction.entitlements | grep -Fq 'carplay'; then
  fail 'iOS Production entitlements carry a CarPlay key before CarPlay is ready for all users'
fi
plutil -p WiltediOS/Info.plist | grep -Fq 'CPTemplateApplicationSceneSessionRoleApplication' \
  || fail 'iOS Info.plist lacks the CarPlay template scene role'
plutil -p WiltediOS/Info.plist | grep -Fq 'CarPlaySceneDelegate' \
  || fail 'iOS Info.plist does not name the CarPlay scene delegate'
# The Siri Intents extension (spoken play requests): embedded in the app, its own bundle ID, signed
# automatically, Siri entitlement in Development only, and it answers play requests for the app.
grep -Fq -- '- target: WiltediOSIntents' <<<"$ios_block" || fail 'WiltediOS does not embed WiltediOSIntents'
intents_block="$(awk '/^  WiltediOSIntents:/{f=1; next} f && /^  [A-Za-z]/{f=0} f' project.yml)"
for line in 'type: app-extension' 'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.ios.intents' 'CODE_SIGN_STYLE: Automatic' \
  'DEVELOPMENT_TEAM: 4CJ49V6QHW' 'CODE_SIGN_ENTITLEMENTS: WiltediOSIntents/WiltediOSIntents.entitlements' \
  'CODE_SIGN_ENTITLEMENTS: WiltediOSIntents/WiltediOSIntentsProduction.entitlements' 'CODE_SIGN_ENTITLEMENTS: ""'; do
  grep -Fq -- "$line" <<<"$intents_block" || fail "WiltediOSIntents lacks: $line"
done
for key in com.apple.intents-service INPlayMediaIntent INMediaCategoryPodcasts IntentHandler; do
  plutil -p WiltediOSIntents/Info.plist | grep -Fq "$key" || fail "extension Info.plist lacks $key"
done
plutil -p WiltediOSIntents/WiltediOSIntents.entitlements | grep -Fq 'com.apple.developer.siri' \
  || fail 'extension Development entitlements lack Siri'
if plutil -p WiltediOSIntents/WiltediOSIntentsProduction.entitlements | grep -Fq 'siri'; then
  fail 'extension Production entitlements carry Siri'
fi
grep -Fq 'WiltediOSIntents.appex' <<<"$ios_block" && grep -Fq '!= "Release"' <<<"$ios_block" \
  || fail 'Release must drop the Intents extension (Production has no Siri entitlement)'
python3 - "$repo_root" <<'PY_EMBED'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import signal

PROJECT = (Path(sys.argv[1]) / 'project.yml').read_text()
OWNED_TEMPS = []

def stop(signum, _frame):
    for temporary in OWNED_TEMPS:
        temporary.cleanup()
    os._exit(128 + signum)

for signum in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
    signal.signal(signum, stop)

def postscript(name):
    lines = PROJECT.splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == '- name: ' + name)
    start = next(i for i in range(start, len(lines)) if lines[i].strip() == 'script: |') + 1
    body = []
    for line in lines[start:]:
        if line and not line.startswith('          '):
            break
        body.append(line[10:] if line else '')
    return '\n'.join(body)

SCRIPTS = [postscript('Embed the Intents extension (not in Release)'),
           postscript('Embed the Watch app (not in Release)')]

class EmbedToolPathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wilted-embed-meta-', dir=os.environ['TMPDIR'])
        OWNED_TEMPS.append(self.temp)
        self.root = Path(self.temp.name).resolve()
        self.poison = self.root / 'poison'; self.poison.mkdir()
        self.log = self.root / 'poison.log'
        executable = self.poison / 'rsync'
        executable.write_text('#!/bin/sh\nprintf "poison-rsync %s\\n" "$*" >> "$POISON_LOG"\nexit 79\n')
        executable.chmod(0o755)
        self.products = self.root / 'products/Debug-iphonesimulator'
        self.products.mkdir(parents=True)
        self.target = self.root / 'target'
        self.env = dict(os.environ, PATH=str(self.poison) + ':/usr/bin:/bin:/usr/sbin:/sbin',
                        POISON_LOG=str(self.log), CONFIGURATION='Debug', PLATFORM_NAME='iphonesimulator',
                        BUILT_PRODUCTS_DIR=str(self.products), TARGET_BUILD_DIR=str(self.target),
                        PLUGINS_FOLDER_PATH='Phone.app/PlugIns', CONTENTS_FOLDER_PATH='Phone.app')

    def tearDown(self):
        root = self.root
        self.temp.cleanup()
        self.assertFalse(root.exists())

    def bundle(self, path):
        path.mkdir(parents=True)
        payload = path / 'payload'; payload.write_bytes(b'owned exact bundle payload\x00\xff')
        payload.chmod(0o751); os.utime(payload, (1700000000, 1700000000))
        path.chmod(0o750); os.utime(path, (1700000001, 1700000001))
        return payload

    def run_script(self, index, **updates):
        env = dict(self.env, **updates)
        result = subprocess.run(['/bin/bash', '-eu', '-c', SCRIPTS[index]], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(env['PATH'], self.env['PATH'])
        return result

    def test_debug_copies_both_deletes_stale_and_preserves_metadata(self):
        sources = [self.products / 'WiltediOSIntents.appex',
                   self.products.parent / 'Debug-watchsimulator/WiltedWatch.app']
        targets = [self.target / 'Phone.app/PlugIns/WiltediOSIntents.appex',
                   self.target / 'Phone.app/Watch/WiltedWatch.app']
        for index, (source, target) in enumerate(zip(sources, targets)):
            with self.subTest(bundle=source.name):
                original = self.bundle(source)
                target.mkdir(parents=True); (target / 'stale').write_text('obsolete')
                result = self.run_script(index)
                self.assertEqual(result.returncode, 0, result.stderr + (self.log.read_text() if self.log.exists() else ''))
                self.assertFalse(self.log.exists(), 'poisoned frontend or receiver invoked')
                copy = target / 'payload'
                self.assertEqual(copy.read_bytes(), original.read_bytes())
                self.assertEqual(copy.stat().st_mode & 0o777, 0o751)
                self.assertEqual(int(copy.stat().st_mtime), 1700000000)
                self.assertFalse((target / 'stale').exists())
                self.assertEqual(target.stat().st_mode & 0o777, 0o750)
                self.assertEqual(int(target.stat().st_mtime), 1700000001)

    def test_release_omits_both_without_invoking_rsync(self):
        self.bundle(self.products / 'WiltediOSIntents.appex')
        self.bundle(self.products.parent / 'Release-watchsimulator/WiltedWatch.app')
        for index in range(2):
            result = self.run_script(index, CONFIGURATION='Release')
            self.assertEqual(result.returncode, 0, result.stderr + (self.log.read_text() if self.log.exists() else ''))
        self.assertFalse(self.target.exists()); self.assertFalse(self.log.exists())

    def test_missing_watch_fails_before_copy(self):
        result = self.run_script(1)
        self.assertEqual(result.returncode, 1)
        self.assertIn('was not built', result.stderr)
        self.assertFalse(self.target.exists()); self.assertFalse(self.log.exists())

    def test_development_maps_phone_platform_to_watchos(self):
        source = self.products.parent / 'Development-watchos/WiltedWatch.app'
        original = self.bundle(source)
        result = self.run_script(1, CONFIGURATION='Development', PLATFORM_NAME='iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr + (self.log.read_text() if self.log.exists() else ''))
        self.assertFalse(self.log.exists(), 'poisoned frontend or receiver invoked')
        self.assertEqual((self.target / 'Phone.app/Watch/WiltedWatch.app/payload').read_bytes(), original.read_bytes())

unittest.main(argv=['embed-tool-path'], verbosity=2)
PY_EMBED

printf '%s\n' 'carplay config test passed'
