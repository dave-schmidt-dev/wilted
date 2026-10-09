#!/usr/bin/env bash
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
import re
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import unittest
ROOT = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('native_gate_xcode_fixture', ROOT / 'tests/native_gate_xcode_fixture.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
RUNTIME, TYPE, UDID = fixture.RUNTIME, fixture.TYPE, fixture.UDID

class XcodeLifecycleTests(fixture.XcodeFixture, unittest.TestCase):
    repository_root = ROOT
    def invoke(self, *args, env=None, timeout=60):
        return subprocess.run(args, env=env or self.env, text=True, capture_output=True, timeout=timeout)
    def select(self):
        result = self.invoke('bash', str(self.root / 'scripts/lib/native-gate-simulator.sh'), 'select', str(self.root), RUNTIME, TYPE)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()
    def session(self, env=None, key="native-ios-unit-tests"):
        return self.invoke('bash', str(self.root / 'scripts/lib/native-gate-simulator.sh'), 'run', str(self.root), UDID,
                           sys.executable, str(self.root / 'scripts/build-with-cache.py'), 'run', 'xcode', key,
                           '--', 'xcodebuild', 'test-without-building', env=env)
    def managed_root(self, host=None):
        parent=self.root / 'managed-work'; parent.mkdir(exist_ok=True)
        owner_started=subprocess.check_output(['/bin/ps','-o','lstart=','-p',str(os.getpid())],text=True).strip()
        (self.root / '.wilted-temp-owned').write_text(f'pid={os.getpid()}\nstarted={owner_started}\npath={self.root}\n')
        host=host or subprocess.Popen(['/bin/sleep','60'])
        started=subprocess.check_output(['/bin/ps','-o','lstart=','-p',str(host.pid)],text=True).strip()
        root=parent / 'wilted-mac-test-receipt'; root.mkdir()
        st=root.stat(); receipt=dict(path=str(root),device=st.st_dev,inode=st.st_ino,
            host_pid=host.pid,host_started=started,owner_path=str(self.root),owner_pid=os.getpid(),owner_started=owner_started)
        (root / '.wilted-managed-test-root').write_text(json.dumps(receipt))
        return root,host,receipt

    def cleanup_managed(self, root):
        return self.invoke('bash','-c','source "$1/scripts/lib/mac-test-parent.sh"; wilted_mac_test_cleanup_roots "$2"',
                           '_',str(self.root),str(root.parent))

    def package_leg_harness(self):
        # Execute canonical function bytes under the same conditional-call Bash semantics as run_leg.
        source = (ROOT / 'scripts/test-gate.sh').read_text()
        functions = []
        for name in ['leg_wiltedkit_tests', 'leg_wiltedproducer_tests']:
            match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(match); functions.append(match.group())
        for directory in ['WiltedKit/Tests/WiltedDomainTests/Fixtures', 'WiltedKit/Tests/WiltedSyncTests/Fixtures',
                          'Producer/Tests', 'contracts/fixtures', 'contracts/cloudkit/fixtures']:
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        for relative in ['contracts/fixtures/sample.json', 'WiltedKit/Tests/WiltedDomainTests/Fixtures/sample.json',
                         'contracts/cloudkit/fixtures/01-valid-publish-decode.json', 'WiltedKit/Tests/WiltedSyncTests/Fixtures/01-valid-publish-decode.json']:
            (self.root / relative).write_text('{}')
        harness = self.root / 'package-leg.sh'
        harness.write_text("""#!/bin/bash
set -Eeuo pipefail
repo_root="$FAKE_REPO"; tmp_root="$FAKE_REPO"
fail() { echo "$1" >&2; exit 91; }
assert_test_sources() { :; }; require_tool() { :; }
build_cache_path() { printf '%s\\n' "$FAKE_REPO/cache"; }
run_with_build_cache() { echo build >>"$FAKE_EVENTS"; return "$FAKE_BUILD_STATUS"; }
run_package_xctest_bundles() {
 echo cached >>"$FAKE_EVENTS"
 printf '%s\\n' 'authoritative publish fixture decodes all records and round trips exactly' 'fake delay emits visible status before completion' 'remote deletions apply incrementally, cascade items, and preserve protected work' >"$3"
 return "$FAKE_XCTEST_STATUS"
}
""" + '\n'.join(functions) + '\nresult=0; if "$1"; then result=0; else result=$?; fi; exit "$result"\n')
        return harness

    def ios_admission_leg(self, label, require_products=False, require_sdk_products=False):
        project = self.root / 'generated/Project.xcodeproj'
        schemes = project / 'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
        scheme = schemes / 'WiltediOS.xcscheme'
        if not scheme.exists():
            inherited = ''.join(f'<EnvironmentVariable key="{key}" value="stale" isEnabled="YES" />' for key in ['WILTED_TEST_TMPDIR', 'WILTED_TEST_OWNER_PID', 'WILTED_TEST_OWNER_STARTED', 'WILTED_TEST_OWNER_PATH'])
            scheme.write_text(f'<Scheme><LaunchAction><EnvironmentVariables>{inherited}</EnvironmentVariables></LaunchAction><TestAction shouldUseLaunchSchemeArgsEnv="YES"><EnvironmentVariables>{inherited}</EnvironmentVariables></TestAction></Scheme>')
            self.original_ios_scheme = scheme.read_bytes()
        capture = self.root / (label + '.json')
        (self.bin / 'xcodebuild').write_text('''#!/usr/bin/env python3
import json,os,sys,subprocess
from pathlib import Path
import xml.etree.ElementTree as ET
args=sys.argv[1:];project=Path(args[args.index('-project')+1]);root=ET.parse(project/'xcshareddata/xcschemes/WiltediOS.xcscheme').getroot()
record={'args':args,'project':str(project),'environment':[dict(x.attrib) for x in root.findall('.//EnvironmentVariable')]}
products=[arg.split('=',1)[1] for arg in args if arg.startswith('CONFIGURATION_BUILD_DIR=')]
def expanded(platform):return Path(products[0].replace('$(CONFIGURATION)','Debug').replace('$(EFFECTIVE_PLATFORM_NAME)',platform))
if os.environ.get('FAKE_REQUIRE_OWNED_PRODUCTS'):
 expected=os.environ['FAKE_EXPECTED_PRODUCTS']
 if products != [expected+'/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)']:
  print('owned-product-admission: missing or incorrect CONFIGURATION_BUILD_DIR',file=sys.stderr);raise SystemExit(69)
 actual=expanded('-iphonesimulator');actual.mkdir(parents=True,exist_ok=True)
 sentinel=actual/'WiltediOS.app'/'Frameworks'/'actual-command-product';sentinel.parent.mkdir(parents=True,exist_ok=True)
 sentinel.write_text('built by this xcodebuild invocation')
 if sentinel.read_text()!='built by this xcodebuild invocation':raise SystemExit(70)
 record['productSentinel']=str(sentinel)

if os.environ.get('FAKE_REQUIRE_SDK_PRODUCTS'):
 if len(products)!=1:raise SystemExit(71)
 phone=expanded('-iphonesimulator');watch=expanded('-watchsimulator')
 (phone/'WiltediOS.app').mkdir(parents=True,exist_ok=True)
 watch_app=watch/'WiltedWatch.app';watch_app.mkdir(parents=True,exist_ok=True)
 (watch_app/'compiled-watch').write_text('built watch SDK product')
 embed=subprocess.run(['/bin/bash','-c',os.environ['FAKE_WATCH_EMBED_SCRIPT']],env=dict(os.environ,
  CONFIGURATION='Debug',PLATFORM_NAME='iphonesimulator',BUILT_PRODUCTS_DIR=str(phone),
  TARGET_BUILD_DIR=str(phone),CONTENTS_FOLDER_PATH='WiltediOS.app'),capture_output=True,text=True)
 if embed.returncode:
  print(embed.stdout+embed.stderr,file=sys.stderr);raise SystemExit(embed.returncode)
 record['phoneProducts']=str(phone);record['watchProducts']=str(watch)
 record['embeddedWatch']=str(phone/'WiltediOS.app/Watch/WiltedWatch.app/compiled-watch')

Path(os.environ['FAKE_CAPTURE']).write_text(json.dumps(record))
''')
        script = self.root / 'ios-admission.sh'
        script.write_text('''#!/bin/bash
set -Eeuo pipefail
repo_root="$1";tmp_root="$1";WILTED_TEMP_LEG_WORK="$1/legs/$2/work";mkdir -p "$WILTED_TEMP_LEG_WORK";build_with_cache="$1/scripts/build-with-cache.py";xcode_test_timeout_seconds=10
source "$1/scripts/lib/test-runner.sh"
source "$1/scripts/lib/mac-test-parent.sh"
source "$1/scripts/lib/native-gate-simulator.sh"
source "$1/scripts/lib/native-gate-xcode.sh"
require_tool() { :; };assert_test_sources() { :; }
find_project() { printf '%s\\n' "$repo_root/generated/Project.xcodeproj"; }
build_cache_path() { python3 "$build_with_cache" path "$@"; }
xcode_test_leg "$2" "$repo_root" WiltediOS "platform=iOS Simulator,id=11111111-1111-1111-1111-111111111111" "$3"
''')
        source = (ROOT / 'project.yml').read_text()
        embed_block = source.split('      - name: Embed the Watch app (not in Release)\n', 1)[1].split('    settings:', 1)[0]
        embed = '\n'.join(line[10:] for line in embed_block.split('        script: |\n', 1)[1].splitlines())
        target = 'WiltediOSTests' if label == 'ios-unit-tests' else 'WiltediOSUITests/WiltediOSPixelSnapshotTests'
        result = self.invoke('bash', str(script), str(self.root), label, target, env=dict(self.env, FAKE_CAPTURE=str(capture),
            FAKE_REQUIRE_OWNED_PRODUCTS='1' if require_products else '',
            FAKE_REQUIRE_SDK_PRODUCTS='1' if require_sdk_products else '', FAKE_WATCH_EMBED_SCRIPT=embed,
            FAKE_EXPECTED_PRODUCTS=str(self.root / 'legs' / label / 'products')))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(scheme.read_bytes(), self.original_ios_scheme, 'unit project configuration must not mutate shared pixel scheme')
        return json.loads(capture.read_text())

    def test_ios_unit_has_owned_signed_embedded_framework_admission(self):
        self.select()
        record = self.ios_admission_leg('ios-unit-tests')
        self.assertEqual(record['project'], str(self.root / 'ios-unit-tests-project/Project.xcodeproj'))
        self.assertIn('CODE_SIGNING_ALLOWED=YES', record['args'])
        self.assertIn('CODE_SIGN_IDENTITY=-', record['args'])
        expected = str(self.root / 'legs/ios-unit-tests/products/Debug-iphonesimulator/WiltediOS.app/Frameworks')
        self.assertEqual(record['environment'], [dict(key='DYLD_FRAMEWORK_PATH', value=expected, isEnabled='YES')])
        self.assertIn('-only-testing:WiltediOSTests', record['args'])

    def test_ios_pixel_keeps_original_project_and_default_signing_after_unit(self):
        self.select()
        self.ios_admission_leg('ios-unit-tests')
        record = self.ios_admission_leg('ios-pixel-snapshot-tests')
        self.assertEqual(record['project'], str(self.root / 'generated/Project.xcodeproj'))
        self.assertFalse(any(arg.startswith('CODE_SIGN') for arg in record['args']))
        self.assertFalse(any(item['key'].startswith('DYLD_') for item in record['environment']))
        self.assertIn('-only-testing:WiltediOSUITests/WiltediOSPixelSnapshotTests', record['args'])

    def test_ios_actual_command_products_are_owned_and_cache_remains_reused(self):
        self.select()
        for label in ['ios-unit-tests', 'ios-pixel-snapshot-tests']:
            with self.subTest(label=label):
                record = self.ios_admission_leg(label, require_products=True)
                products = self.root / 'legs' / label / 'products'
                self.assertEqual([arg for arg in record['args'] if arg.startswith('CONFIGURATION_BUILD_DIR=')],
                                 ['CONFIGURATION_BUILD_DIR=' + str(products) + '/$(CONFIGURATION)$(EFFECTIVE_PLATFORM_NAME)'])
                args = record['args']
                self.assertEqual(args[args.index('-derivedDataPath') + 1], str(self.root / '.build/xcode' / ('native-' + label)))
                sentinel = Path(record['productSentinel'])
                self.assertTrue(sentinel.is_relative_to(products))
                self.assertEqual(sentinel, products / 'Debug-iphonesimulator/WiltediOS.app/Frameworks/actual-command-product')
                self.assertEqual(sentinel.read_text(), 'built by this xcodebuild invocation')
                self.assertEqual(list((self.root / 'legs' / label / 'work').iterdir()), [])
                self.assertEqual(args[args.index('-collect-test-diagnostics') + 1], 'never')
                self.assertIn('test', args)

    def test_phone_and_watch_same_configuration_keep_distinct_sdk_products_and_embed(self):
        self.select()
        record = self.ios_admission_leg('ios-pixel-snapshot-tests', require_sdk_products=True)
        base = self.root / 'legs/ios-pixel-snapshot-tests/products'
        self.assertEqual(Path(record['phoneProducts']), base / 'Debug-iphonesimulator')
        self.assertEqual(Path(record['watchProducts']), base / 'Debug-watchsimulator')
        self.assertNotEqual(record['phoneProducts'], record['watchProducts'])
        self.assertEqual(Path(record['embeddedWatch']).read_text(), 'built watch SDK product')
        self.assertEqual(list((self.root / 'legs/ios-pixel-snapshot-tests/work').iterdir()), [])

    def test_package_build_failure_never_executes_available_cached_tests(self):
        harness = self.package_leg_harness()
        for name in ['leg_wiltedkit_tests', 'leg_wiltedproducer_tests']:
            for build_status in [65, 17, 124]:
                with self.subTest(package=name, build_status=build_status):
                    self.events.write_text('')
                    result = self.invoke('bash', str(harness), name, env=dict(self.env, FAKE_REPO=str(self.root), FAKE_BUILD_STATUS=str(build_status), FAKE_XCTEST_STATUS='0'))
                    events = self.events.read_text().splitlines()
                    self.assertEqual(result.returncode, build_status, result.stderr + repr(events))
                    self.assertEqual(events, ['build'], 'cached discovery/execution must not follow a failed build')

    def test_package_successful_build_preserves_cached_test_status(self):
        harness = self.package_leg_harness()
        for name in ['leg_wiltedkit_tests', 'leg_wiltedproducer_tests']:
            for test_status in [0, 23]:
                with self.subTest(package=name, test_status=test_status):
                    self.events.write_text('')
                    result = self.invoke('bash', str(harness), name, env=dict(self.env, FAKE_REPO=str(self.root), FAKE_BUILD_STATUS='0', FAKE_XCTEST_STATUS=str(test_status)))
                    self.assertEqual(result.returncode, test_status, result.stderr)
                    self.assertEqual(self.events.read_text().splitlines(), ['build', 'cached'])

    def test_cleanup_selftest_preserves_a_live_checkout_shaped_host(self):
        protected=self.root / '.build/xcode/native-macos-unit-tests/WiltedMac.app/Contents/MacOS/WiltedMac'
        host=subprocess.Popen(['/bin/bash','-c','exec -a "$1" /bin/sleep 30','_',str(protected)])
        scratch=self.root / 'cleanup-proof';scratch.mkdir()
        try:
            result=self.invoke('bash','-c','source "$1/scripts/lib/mac-test-parent.sh"; wilted_mac_test_host_cleanup_selftest "$2" "$1"',
                               '_',str(self.root),str(scratch))
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertIn('foreign-peer-preserved=1',result.stdout)
            self.assertIsNone(host.poll(),'cleanup selftest must never target an actual checkout host')
        finally:
            if host.poll() is None:host.terminate()
            host.wait()

    def test_scheme_delivers_validated_owner_bundle_and_strips_inheritance(self):
        import xml.etree.ElementTree as ET
        parent=self.root / 'scheme-parent';parent.mkdir()
        start=subprocess.check_output(['/bin/ps','-o','lstart=','-p',str(os.getpid())],text=True).strip()
        marker=self.root / '.wilted-temp-owned'
        marker.write_text(f'pid={os.getpid()}\nstarted={start}\npath={self.root}\n')
        keys=['WILTED_TEST_TMPDIR','WILTED_TEST_OWNER_PID','WILTED_TEST_OWNER_STARTED','WILTED_TEST_OWNER_PATH']
        scheme=self.root / 'scheme.xcscheme'
        inherited=''.join(f'<EnvironmentVariable key="{key}" value="stale" isEnabled="YES" />' for key in keys)
        scheme.write_text(f'<Scheme><LaunchAction><EnvironmentVariables>{inherited}</EnvironmentVariables></LaunchAction><TestAction shouldUseLaunchSchemeArgsEnv="YES"><EnvironmentVariables>{inherited}</EnvironmentVariables></TestAction></Scheme>')
        command='source "$1/scripts/lib/mac-test-parent.sh"; wilted_mac_test_scheme_configure "$2" "$3" "${{@:4}}"'.replace('${{@:4}}','${@:4}')
        def configure(*args):
            return self.invoke('bash','-c',command,'_',str(self.root),str(scheme),str(parent),*args)
        result=configure('WILTED_TEST_TMPDIR='+str(parent));self.assertEqual(result.returncode,0,result.stderr)
        tree=ET.parse(scheme).getroot()
        delivered={x.get('key'):x.get('value') for x in tree.find('TestAction/EnvironmentVariables')}
        self.assertEqual({key:delivered[key] for key in keys},dict(WILTED_TEST_TMPDIR=str(parent),WILTED_TEST_OWNER_PID=str(os.getpid()),WILTED_TEST_OWNER_STARTED=start,WILTED_TEST_OWNER_PATH=str(self.root)))
        self.assertFalse(any(x.get('key') in keys for x in tree.findall('LaunchAction/EnvironmentVariables/EnvironmentVariable')))
        result=configure();self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(x.get('key') in keys for x in ET.parse(scheme).getroot().findall('.//EnvironmentVariable')))
        marker.unlink()
        result=configure('WILTED_TEST_TMPDIR='+str(parent));self.assertEqual(result.returncode,0,result.stderr)
        delivered={x.get('key'):x.get('value') for x in ET.parse(scheme).getroot().find('TestAction/EnvironmentVariables')}
        expected = dict(WILTED_TEST_TMPDIR=str(parent))
        enclosing = next((p for p in self.root.parents if (p / '.wilted-temp-owned').exists()), None)
        if enclosing is not None:
            owner = dict(line.split('=', 1) for line in (enclosing / '.wilted-temp-owned').read_text().splitlines())
            expected.update(WILTED_TEST_OWNER_PID=owner['pid'].strip(),
                            WILTED_TEST_OWNER_STARTED=owner['started'].strip(),
                            WILTED_TEST_OWNER_PATH=owner['path'].strip())
        self.assertEqual(delivered, expected)

    def test_nested_scheme_prefers_nearest_owner_and_rejects_stale_fallback(self):
        import xml.etree.ElementTree as ET
        outer = self.root / 'enclosing-owner'; inner = outer / 'nearest-owner'
        parent = inner / 'scheme-parent'; parent.mkdir(parents=True)
        started = subprocess.check_output(['/bin/ps', '-o', 'lstart=', '-p', str(os.getpid())], text=True).strip()
        for owner in [outer, inner]:
            (owner / '.wilted-temp-owned').write_text(f'pid={os.getpid()}\nstarted={started}\npath={owner}\n')
        scheme = self.root / 'nested.xcscheme'; scheme.write_text('<Scheme><TestAction /></Scheme>')
        def configure():
            return self.invoke('bash', '-c', 'source "$1/scripts/lib/mac-test-parent.sh"; wilted_mac_test_scheme_configure "$2" "$3" "WILTED_TEST_TMPDIR=$3"', '_', str(self.root), str(scheme), str(parent))
        def assert_owner(owner):
            result = configure(); self.assertEqual(result.returncode, 0, result.stderr)
            delivered = {x.get('key'): x.get('value') for x in ET.parse(scheme).getroot().find('TestAction/EnvironmentVariables')}
            self.assertEqual(delivered, dict(WILTED_TEST_TMPDIR=str(parent), WILTED_TEST_OWNER_PID=str(os.getpid()), WILTED_TEST_OWNER_STARTED=started, WILTED_TEST_OWNER_PATH=str(owner)))
        assert_owner(inner)
        (inner / '.wilted-temp-owned').unlink()
        assert_owner(outer)
        before = scheme.read_bytes()
        (outer / '.wilted-temp-owned').write_text(f'pid={os.getpid()}\nstarted=stale\npath={outer}\n')
        refused = configure(); self.assertNotEqual(refused.returncode, 0)
        self.assertIn('stale controlling owner', refused.stderr)
        self.assertEqual(scheme.read_bytes(), before)

    def test_scheme_refuses_foreign_stale_malformed_and_dangling_owner(self):
        parent=self.root / 'scheme-parent';parent.mkdir()
        scheme=self.root / 'scheme.xcscheme';scheme.write_text('<Scheme><TestAction /></Scheme>')
        marker=self.root / '.wilted-temp-owned'
        foreign=subprocess.Popen(['/bin/sleep','30'])
        try:
            for kind in ['foreign','stale','malformed','dangling','path']:
                with self.subTest(kind=kind):
                    if marker.exists() or marker.is_symlink():marker.unlink()
                    pid=foreign.pid if kind=='foreign' else os.getpid()
                    start=subprocess.check_output(['/bin/ps','-o','lstart=','-p',str(pid)],text=True).strip()
                    if kind=='dangling':marker.symlink_to(self.root / 'missing-owner')
                    elif kind=='malformed':marker.write_text('pid=1\npid=2\n')
                    else:marker.write_text(f"pid={pid}\nstarted={'stale' if kind=='stale' else start}\npath={self.root / 'foreign' if kind=='path' else self.root}\n")
                    before=scheme.read_bytes()
                    result=self.invoke('bash','-c','source "$1/scripts/lib/mac-test-parent.sh"; wilted_mac_test_scheme_configure "$2" "$3" "WILTED_TEST_TMPDIR=$3"','_',str(self.root),str(scheme),str(parent))
                    self.assertNotEqual(result.returncode,0,result.stderr);self.assertEqual(scheme.read_bytes(),before)
        finally:foreign.terminate();foreign.wait()

    def test_managed_root_cleanup_waits_for_success_or_failure_host_terminal(self):
        for status in [0,17]:
            with self.subTest(status=status):
                host=subprocess.Popen([sys.executable,'-c',f'import time; time.sleep(.2); raise SystemExit({status})'])
                root,host,_=self.managed_root(host); self.assertEqual(host.wait(),status)
                result=self.cleanup_managed(root)
                self.assertEqual(result.returncode,0,result.stderr); self.assertFalse(root.exists())

    def test_managed_root_refuses_live_owner_host(self):
        root,host,_=self.managed_root()
        try:
            result=self.cleanup_managed(root)
            self.assertNotEqual(result.returncode,0); self.assertTrue(root.exists())
        finally: host.terminate(); host.wait()

    def test_managed_root_refuses_symlink_replacement_malformed_and_foreign_owner(self):
        for kind in ['symlink','root-symlink','replacement','malformed','foreign']:
            with self.subTest(kind=kind):
                root,host,receipt=self.managed_root(); host.terminate();host.wait()
                marker=root / '.wilted-managed-test-root'
                if kind=='symlink':
                    target=self.root / 'foreign-receipt'; target.write_text(marker.read_text()); marker.unlink(); marker.symlink_to(target)
                elif kind in ['root-symlink','replacement']:
                    held=self.root / ('held-'+kind);root.rename(held)
                    if kind=='root-symlink':root.symlink_to(held)
                    else:root.mkdir();(root / marker.name).write_text(json.dumps(receipt))
                elif kind=='malformed': marker.write_text('{}')
                else:
                    foreign=subprocess.Popen(['/bin/sleep','60']);receipt['owner_pid']=foreign.pid
                    receipt['owner_started']=subprocess.check_output(['/bin/ps','-o','lstart=','-p',str(foreign.pid)],text=True).strip()
                    (self.root / '.wilted-temp-owned').write_text(f"pid={foreign.pid}\nstarted={receipt['owner_started']}\npath={self.root}\n")
                    marker.write_text(json.dumps(receipt))
                try:
                    result=self.cleanup_managed(root);self.assertNotEqual(result.returncode,0);self.assertTrue(root.exists())
                finally:
                    if kind=='foreign': foreign.terminate();foreign.wait()
                    if root.is_symlink(): root.unlink()
                    elif root.exists(): shutil.rmtree(root)

    def test_managed_cleanup_preserves_unknown_files_for_the_audit(self):
        root,host,_=self.managed_root();host.terminate();host.wait()
        checker=self.root / 'scripts/check-temp-leaks.py'
        before=self.root / 'audit-before.json';after=self.root / 'audit-after.json'
        snapshot=self.invoke(sys.executable,str(checker),'snapshot',str(root.parent),str(before))
        self.assertEqual(snapshot.returncode,0,snapshot.stderr)
        unknown=root.parent / 'wilted-unrelated-leak';unknown.write_text('unknown')
        result=self.cleanup_managed(root)
        self.assertEqual(result.returncode,0,result.stderr);self.assertFalse(root.exists());self.assertTrue(unknown.exists())
        snapshot=self.invoke(sys.executable,str(checker),'snapshot',str(root.parent),str(after))
        self.assertEqual(snapshot.returncode,0,snapshot.stderr)
        audit=self.invoke(sys.executable,str(checker),'compare',str(before),str(after),'--label','managed-unknown')
        self.assertEqual(audit.returncode,1,audit.stdout+audit.stderr)
        self.assertIn('wilted-unrelated-leak',audit.stdout+audit.stderr)

    def managed_mac_leg(self, delay='0', status='0', extra_env=None):
        parent=self.root / 'work';parent.mkdir(exist_ok=True)
        project=self.root / 'generated/Project.xcodeproj'
        (project / 'xcshareddata/xcschemes').mkdir(parents=True,exist_ok=True)
        (project / 'xcshareddata/xcschemes/WiltedMac.xcscheme').write_text('<Scheme><TestAction /></Scheme>')
        script=self.root / 'mac-leg.sh'
        script.write_text('''#!/bin/bash
set -Eeuo pipefail
repo_root="$1";tmp_root="$1";WILTED_TEMP_LEG_WORK="$1/work";build_with_cache="$1/scripts/build-with-cache.py"
source "$1/scripts/lib/test-runner.sh"
source "$1/scripts/lib/simctl_gate_lib.sh"
source "$1/scripts/lib/mac-test-parent.sh"
source "$1/scripts/lib/native-gate-xcode.sh"
printf 'pid=%s\\nstarted=%s\\npath=%s\\n' "$$" "$(ps -o lstart= -p "$$")" "$1" >"$1/.wilted-temp-owned"
trap '[[ ! -e "$repo_root/work/wilted-mac-test-from-host" ]] || exit 125; echo audit >>"$FAKE_EVENTS"; exit 143' TERM
require_tool() { :; };assert_test_sources() { :; }
find_project() { printf '%s\\n' "$repo_root/generated/Project.xcodeproj"; }
xcode_test_timeout_seconds=2
build_cache_path() { python3 "$build_with_cache" path "$@"; }
run_with_build_cache() { local kind="$1" key="$2";shift 2;WILTED_WORK_PHASE=build python3 "$build_with_cache" run "$kind" "$key" -- "$@"; }
result=0
xcode_test_leg macos-unit-tests "$repo_root" WiltedMac platform=macOS WiltedMacTests || result=$?
[[ ! -e "$1/work/wilted-mac-test-from-host" ]] || exit 125
echo audit >>"$FAKE_EVENTS"
exit "$result"
''')
        return subprocess.Popen(['bash',str(script),str(self.root)],env=dict(self.env,FAKE_MANAGED_PARENT=str(parent),FAKE_TEST_DELAY=delay,FAKE_TEST_STATUS=status,**(extra_env or {})),text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)

    def test_mac_unit_delivers_own_embedded_frameworks_with_owner_proof(self):
        expected=self.root / 'products/Debug/WiltedMac.app/Contents/Frameworks'
        process=self.managed_mac_leg(extra_env=dict(FAKE_REQUIRE_FRAMEWORK='1',FAKE_EXPECTED_FRAMEWORK=str(expected)))
        out,err=process.communicate(timeout=60)
        self.assertEqual(process.returncode,0,err)
        self.assertNotIn('DYLD_PRINT_', (self.root / 'macos-unit-tests-project/Project.xcodeproj/xcshareddata/xcschemes/WiltedMac.xcscheme').read_text())

    def test_headless_transactions_disable_optional_diagnostics_and_preserve_results(self):
        self.select()
        fake = self.bin / 'xcodebuild'
        original_fake = fake.read_text()
        ios = self.ios_admission_leg('ios-unit-tests')
        mac_capture = self.root / 'mac-diagnostics-args.json'
        source = original_fake.replace('args=sys.argv[1:];', "import json\nPath(os.environ['FAKE_CAPTURE']).write_text(json.dumps(sys.argv[1:]))\nargs=sys.argv[1:];", 1)
        fake.write_text(source)
        process = self.managed_mac_leg(status='65', extra_env=dict(FAKE_CAPTURE=str(mac_capture)))
        out, err = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 65, err)
        mac = json.loads(mac_capture.read_text())
        for label, args, target in [('ios-unit-tests', ios['args'], 'WiltediOSTests'),
                                    ('macos-unit-tests', mac, 'WiltedMacTests')]:
            with self.subTest(label=label):
                self.assertEqual(args.count('-collect-test-diagnostics'), 1)
                self.assertEqual(args[args.index('-collect-test-diagnostics') + 1], 'never')
                self.assertEqual(args.count('test'), 1)
                self.assertIn('-only-testing:' + target, args)
                self.assertEqual(args[args.index('-resultBundlePath') + 1], str(self.root / (label + '.xcresult')))
        self.assertIn('CODE_SIGNING_ALLOWED=YES', ios['args'])
        self.assertIn('CODE_SIGN_IDENTITY=-', ios['args'])
        self.assertEqual(self.events.read_text().splitlines()[-1], 'audit')
        self.assertFalse((self.root / 'work/wilted-mac-test-from-host').exists())

    def test_current_project_is_built_and_tested_under_one_product_lock(self):
        ready=self.root / 'lane-ready';release=self.root / 'lane-release';product=self.root / 'product'
        (self.bin / 'ui-lock').write_text('#!/bin/bash\nwhile [[ "$1" != -- ]]; do shift; done\nshift\ntouch "$FAKE_LANE_READY"\nwhile [[ ! -f "$FAKE_LANE_RELEASE" ]]; do sleep .05; done\nexec "$@"\n')
        process=self.managed_mac_leg(extra_env=dict(FAKE_LANE_READY=str(ready),FAKE_LANE_RELEASE=str(release),FAKE_PRODUCT_MARKER=str(product),FAKE_CANDIDATE='current'))
        try:
            deadline=time.monotonic()+20
            while not ready.exists() and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(ready.exists(),'test lane rendezvous missing')
            peer=self.invoke(sys.executable,str(self.root / 'scripts/build-with-cache.py'),'run','xcode','native-macos-unit-tests','--','xcodebuild','build-for-testing',env=dict(self.env,FAKE_PRODUCT_MARKER=str(product),FAKE_CANDIDATE='peer'))
            self.assertEqual(peer.returncode,0,peer.stderr);self.assertEqual(product.read_text(),'peer')
            release.touch();out,err=process.communicate(timeout=60)
            self.assertEqual(process.returncode,0,err);self.assertEqual(product.read_text(),'current')
        finally:
            release.touch()
            if process.poll() is None:process.terminate();process.communicate(timeout=60)

    def test_managed_root_cleanup_after_bounded_timeout(self):
        process=self.managed_mac_leg(delay='60')
        out,err=process.communicate(timeout=60)
        self.assertEqual(process.returncode,124,err)
        self.assertIn('terminal-owned-roots=1',out)
        self.assertEqual(self.events.read_text().splitlines()[-1],'audit')

    def test_managed_root_cleanup_after_term_keeps_live_descriptors_safe(self):
        process=self.managed_mac_leg(delay='60')
        try:
            deadline=time.monotonic()+20
            while (not self.events.exists() or 'root created' not in self.events.read_text()) and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue((self.root / 'work/wilted-mac-test-from-host').exists())
            process.terminate();out,err=process.communicate(timeout=60)
            self.assertEqual(process.returncode,143,err)
            self.assertIn('terminal-owned-roots=1',out)
            self.assertEqual(self.events.read_text().splitlines()[-1],'audit')
        finally:
            if process.poll() is None:process.terminate();process.communicate(timeout=60)

    def test_persistent_reuse_ready_wait_excluded_and_shutdown(self):
        self.assertEqual(self.select(), self.select())
        result = self.session(dict(self.env, FAKE_READY_DELAY='4', WILTED_TEST_TIMEOUT_SECONDS='3', FAKE_TEST_DELAY='.1'))
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.events.read_text()
        self.assertEqual(events.count('simctl create'), 1)
        self.assertIn('simctl shutdown', events)
        self.assertNotIn('simctl delete', events)
        self.assertEqual(json.loads(self.state.read_text())['devices'][RUNTIME][0]['state'], 'Shutdown')
    def test_unit_and_ui_destinations_serialize_only_test_sessions(self):
        self.select()
        first=subprocess.Popen(['bash', str(self.root / 'scripts/lib/native-gate-simulator.sh'), 'run', str(self.root), UDID,
                                sys.executable, str(self.root / 'scripts/build-with-cache.py'), 'run', 'xcode', 'native-ios-unit-tests',
                                '--', 'xcodebuild', 'test-without-building'],
                               env=dict(self.env, FAKE_TEST_DELAY='2'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline=time.monotonic()+20
            while 'test start' not in self.events.read_text() and time.monotonic()<deadline: time.sleep(.02)
            second=self.session(key='native-ios-pixel-snapshot-tests')
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn('native.simulator.wait', second.stderr)
            first.communicate(timeout=60); self.assertEqual(first.returncode, 0)
            events=[e for e in self.events.read_text().splitlines() if e.startswith('test ')]
            self.assertEqual(events, ['test start', 'test end', 'test start', 'test end'])
        finally:
            if first.poll() is None: first.terminate(); first.communicate(timeout=60)

    def test_exact_owned_selection_rejects_wrong_type_and_duplicate(self):
        wrong={'udid':'22222222-2222-2222-2222-222222222222', 'name':'wilted-persistent-iOS-26-0',
               'state':'Shutdown','deviceTypeIdentifier':'wrong-type','isAvailable':True}
        self.state.write_text(json.dumps({'devices': {RUNTIME:[wrong]}}))
        self.assertEqual(self.select(), UDID)
        devices=json.loads(self.state.read_text())['devices'][RUNTIME]
        self.assertEqual(devices[0], wrong)
        # A matching name with a foreign model is not an owned run destination.
        result=self.invoke('bash', str(self.root / 'scripts/lib/native-gate-simulator.sh'), 'run', str(self.root), wrong['udid'], 'true')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('unowned destination', result.stderr)
        # Exact duplicates are refused, rather than taking the first listed one.
        duplicate=dict(devices[1], udid='33333333-3333-3333-3333-333333333333')
        self.state.write_text(json.dumps({'devices': {RUNTIME:devices+[duplicate]}}))
        result=self.invoke('bash', str(self.root / 'scripts/lib/native-gate-simulator.sh'), 'select', str(self.root), RUNTIME, TYPE)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('ambiguous persistent ownership', result.stderr)
    def test_selector_and_python_tool_failures_keep_diagnostics(self):
        code='source "$1/scripts/lib/native-gate-simulator.sh"; select_ios_simulator_spec() { :; }; create_gate_simulator fixture'
        result=self.invoke('bash', '-c', code, '_', str(self.root))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('selector returned empty runtime/device type purpose=fixture', result.stderr)
        code='source "$1/scripts/lib/native-gate-simulator.sh"; repo_root="$1"; require_tool() { [[ "$1" != python3 ]] || { echo "native.error missing required tool: python3" >&2; return 1; }; }; select_ios_simulator_spec'
        result=self.invoke('bash', '-c', code, '_', str(self.root))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('missing required tool: python3', result.stderr)

    def test_initial_inventory_timeout_reports_phase_and_reaps_descendants(self):
        pids = self.root / 'inventory.pids'
        code = 'set -o pipefail; repo_root="$1"; xcode_build_timeout_seconds=3; require_tool() { command -v "$1" >/dev/null; }; source "$repo_root/scripts/lib/native-gate-simulator.sh"; create_gate_simulator fixture'
        self.select()
        state = json.loads(self.state.read_text())
        state['devices'][RUNTIME].append({'udid': '99999999-9999-9999-9999-999999999999',
                                         'name': 'iPhone 17 Pro', 'state': 'Shutdown',
                                         'deviceTypeIdentifier': TYPE, 'isAvailable': True})
        self.state.write_text(json.dumps(state))
        selected = self.invoke('bash', '-c', code, '_', str(self.root))
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(selected.stdout.strip(), UDID)
        result = self.invoke('bash', '-c', code, '_', str(self.root),
                             env=dict(self.env, FAKE_INVENTORY_HANG='1', FAKE_INVENTORY_PIDS=str(pids)))
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertIn('phase=simulator-selection', result.stderr)
        self.assertIn('timeout seconds=3', result.stderr)
        self.assertEqual(result.stdout, '')
        owned = [int(pid) for pid in pids.read_text().split()]
        self.assertEqual(len(owned), 2)
        for pid in owned:
            state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='],
                                   text=True, capture_output=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), f'owned inventory descendant survived: {pid}')

    def test_watch_selector_requires_supported_available_45mm_runtime(self):
        kind='com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm'
        runtime='com.apple.CoreSimulator.SimRuntime.watchOS-27-0'
        runtimes=self.root / 'runtimes.json'
        choices=[{'identifier':runtime,'version':'27.0','isAvailable':True,
                  'supportedDeviceTypes':[{'identifier':kind}]},
                 {'identifier':'com.apple.CoreSimulator.SimRuntime.watchOS-28-0','version':'28.0',
                  'isAvailable':True,'supportedDeviceTypes':[]}]
        runtimes.write_text(json.dumps({'runtimes':choices}))
        self.state.write_text(json.dumps({'devices': {runtime: []}}))
        code='repo_root="$1"; source "$1/scripts/lib/native-gate-simulator.sh"; require_tool() { :; }; create_watch_gate_simulator'
        result=self.invoke('bash','-c',code,'_',str(self.root),env=dict(self.env,FAKE_RUNTIMES=str(runtimes)))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('simctl create wilted-persistent-watchOS-27-0 '+kind+' '+runtime,self.events.read_text())
        choices[0]['isAvailable']=False; runtimes.write_text(json.dumps({'runtimes':choices})); self.events.write_text('')
        result=self.invoke('bash','-c',code,'_',str(self.root),env=dict(self.env,FAKE_RUNTIMES=str(runtimes)))
        self.assertNotEqual(result.returncode,0)
        self.assertIn('no available runtime supports the 45mm Watch',result.stderr)
        self.assertNotIn('simctl create',self.events.read_text())

    def test_watch_owned_lifecycle_preserves_boot_state_and_rejects_wrong_type(self):
        watch_runtime='com.apple.CoreSimulator.SimRuntime.watchOS-27-0'
        watch_type='com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-9-45mm'
        self.state.write_text(json.dumps({'devices': {watch_runtime: []}}))
        selected=self.invoke('bash', str(self.root / 'scripts/lib/native-gate-simulator.sh'),
                             'select', str(self.root), watch_runtime, watch_type)
        self.assertEqual(selected.returncode,0,selected.stderr)
        result=self.session()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('simctl shutdown '+UDID,self.events.read_text())
        state=json.loads(self.state.read_text()); device=state['devices'][watch_runtime][0]
        self.assertEqual(device['state'],'Shutdown')
        device['state']='Booted'; self.state.write_text(json.dumps(state)); self.events.write_text('')
        result=self.session()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('simctl shutdown',self.events.read_text())
        device['deviceTypeIdentifier']=TYPE; self.state.write_text(json.dumps(state)); self.events.write_text('')
        result=self.session()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('unowned destination',result.stderr)
        self.assertNotIn('simctl boot',self.events.read_text())

    def test_originally_booted_device_preserved(self):
        self.select(); state=json.loads(self.state.read_text()); state['devices'][RUNTIME][0]['state']='Booted'; self.state.write_text(json.dumps(state))
        result=self.session()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('simctl shutdown', self.events.read_text())
    def test_hung_test_diagnostics_and_cleanup(self):
        self.select()
        result=self.session(dict(self.env, WILTED_TEST_TIMEOUT_SECONDS='3', FAKE_TEST_DELAY='60'))
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertIn('phase=test', result.stderr)
        self.assertIn('owned-pid=', result.stderr)
        self.assertIn('executable=', result.stderr)
        self.assertNotIn('FAKE_TEST_DELAY', result.stderr)
        self.assertIn('simctl shutdown', self.events.read_text())
    def test_signal_during_readiness_cleans_up_owned_boot(self):
        self.select()
        process=subprocess.Popen(['bash', str(self.root / 'scripts/lib/native-gate-simulator.sh'), 'run', str(self.root), UDID, 'true'],
                                 env=dict(self.env, FAKE_READY_DELAY='60'), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+6
            while 'simctl bootstatus' not in self.events.read_text() and time.monotonic()<deadline: time.sleep(.02)
            process.terminate(); out,err=process.communicate(timeout=60)
            self.assertEqual(process.returncode, 143, err)
            self.assertIn('simctl shutdown', self.events.read_text())
        finally:
            if process.poll() is None: process.kill(); process.wait()
    def test_xcode_leg_ready_wait_excluded_from_combined_work_deadline(self):
        self.select()
        project=self.root / 'generated/Project.xcodeproj'; project.mkdir(parents=True)
        schemes=project / 'xcshareddata/xcschemes'; schemes.mkdir(parents=True)
        (schemes / 'WiltediOS.xcscheme').write_text('<Scheme><TestAction /></Scheme>')
        script=self.root / 'leg.sh'
        script.write_text('''#!/bin/bash
set -Eeuo pipefail
repo_root="$1"; tmp_root="$repo_root"; native_project="$repo_root/generated/Project.xcodeproj"
build_with_cache="$repo_root/scripts/build-with-cache.py"
xcode_test_timeout_seconds=3; WILTED_TEMP_LEG_WORK="$repo_root"; integration_root="$repo_root"
source "$repo_root/scripts/lib/test-runner.sh"
source "$repo_root/scripts/lib/mac-test-parent.sh"
source "$repo_root/scripts/lib/native-gate-simulator.sh"
source "$repo_root/scripts/lib/native-gate-xcode.sh"
require_tool() { :; }
assert_test_sources() { :; }
build_cache_path() { python3 "$build_with_cache" path "$@"; }
find_project() { printf '%s\\n' "$native_project"; }
status() { printf '%s\\n' "$1" >&2; }
run_with_build_cache() {
 local kind="$1" key="$2"; shift 2
 WILTED_TEST_TIMEOUT_SECONDS=10 WILTED_WORK_PHASE=build python3 "$build_with_cache" run "$kind" "$key" -- "$@"
}
xcode_test_leg ios-unit-tests "$repo_root" WiltediOS "platform=iOS Simulator,id=11111111-1111-1111-1111-111111111111" WiltediOSTests
''')
        result=self.invoke('bash', str(script), str(self.root), env=dict(self.env, FAKE_BUILD_DELAY='1', FAKE_TEST_DELAY='.1', FAKE_READY_DELAY='4'))
        self.assertEqual(result.returncode, 0, result.stderr)
        events=self.events.read_text().splitlines()
        ready=next(i for i,x in enumerate(events) if 'bootstatus' in x)
        self.assertLess(ready, events.index('build start'))
        self.assertLess(events.index('build end'), events.index('test start'))
        self.events.write_text('')
        timed=self.invoke('bash',str(script),str(self.root),env=dict(self.env,FAKE_BUILD_DELAY='60',FAKE_READY_DELAY='4'))
        self.assertEqual(timed.returncode,124,timed.stderr)
        self.assertIn('phase=build-and-test',timed.stderr)
        self.assertIn('simctl shutdown',self.events.read_text())

    def test_clone_reaper_removes_only_proven_project_clone(self):
        clone_set=self.root / 'clones'; clone_set.mkdir()
        for name in ['owned', 'foreign']: (clone_set / name / 'data').mkdir(parents=True)
        (self.bin / 'stat').write_text('#!/bin/sh\necho 1\n'); (self.bin / 'stat').chmod(0o755)
        (self.bin / 'xcrun').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >>"$FAKE_EVENTS"\nexit 0\n')
        (self.bin / 'xcrun').chmod(0o755)
        before=self.root / 'before'; before.write_text('')
        code = r'''source "$1/scripts/lib/simctl_gate_lib.sh"
_gate_lib_list_devices() {
 printf 'OWNED\tClone 1 of wilted-persistent-iOS-26-0\t%s/owned/data\tShutdown\n' "$2"
 printf 'FOREIGN\tClone 2 of peer-app\t%s/foreign/data\tShutdown\n' "$2"
}
_gate_lib_reap_new_clones "$2" "$3" 10
'''
        # Override has no positional args from the parser; bind the fixture set.
        code=code.replace('"$2"\n printf', '"$CLONE_SET"\n printf').replace('"$2"\n}', '"$CLONE_SET"\n}')
        result=self.invoke('bash', '-c', code, '_', str(self.root), str(clone_set), str(before),
                           env=dict(self.env, GATE_PROJECT_OWNED_CLONES_ONLY='1',
                                    GATE_OWNED_SIMULATOR_NAME='wilted-persistent-iOS-26-0', CLONE_SET=str(clone_set)))
        self.assertEqual(result.returncode, 0, result.stderr)
        events=self.events.read_text()
        self.assertIn('delete OWNED', events)
        self.assertNotIn('delete FOREIGN', events)

    def test_stranded_owned_clone_cleanup_preserves_peer(self):
        self.select()
        clone_set=self.root / 'clones'; clone_set.mkdir()
        clones=self.root / 'clones.json'
        clones.write_text(json.dumps({'devices': {RUNTIME: [
            {'udid':'OWNED', 'name':'Clone 1 of wilted-persistent-iOS-26-0', 'state':'Booted', 'dataPath':str(clone_set / 'owned/data')},
            {'udid':'PEER', 'name':'Clone 2 of peer-app', 'state':'Shutdown', 'dataPath':str(clone_set / 'peer/data')}]}}))
        result=self.session(dict(self.env, GATE_XCTEST_DEVICE_SET=str(clone_set), FAKE_CLONE_STATE=str(clones)))
        self.assertEqual(result.returncode, 0, result.stderr)
        remaining=json.loads(clones.read_text())['devices'][RUNTIME]
        self.assertEqual([d['udid'] for d in remaining], ['PEER'])
        self.assertIn('simctl shutdown '+UDID, self.events.read_text())

    def test_test_status_survives_clone_cleanup_failure(self):
        self.select()
        clone_set=self.root / 'clones'; clone_set.mkdir()
        clones=self.root / 'clones.json'
        def reset():
            clones.write_text(json.dumps({'devices': {RUNTIME:[{'udid':'OWNED',
                'name':'Clone 1 of wilted-persistent-iOS-26-0','state':'Shutdown','dataPath':str(clone_set / 'owned/data')}]}}))
        for test_status, test_delay, expected in [('17','0',17), ('0','60',124), ('0','0',125)]:
            with self.subTest(expected=expected):
                reset()
                result=self.session(dict(self.env, GATE_XCTEST_DEVICE_SET=str(clone_set), FAKE_CLONE_STATE=str(clones),
                    FAKE_CLONE_FAILURE='1', FAKE_TEST_STATUS=test_status, FAKE_TEST_DELAY=test_delay,
                    WILTED_TEST_TIMEOUT_SECONDS='3'))
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn('cleanup.failure phase=clones status=23', result.stderr)
                self.assertEqual(json.loads(self.state.read_text())['devices'][RUNTIME][0]['state'],'Shutdown')
    def test_repeated_signal_does_not_abort_semantic_cleanup(self):
        self.select()
        process=subprocess.Popen(['bash',str(self.root / 'scripts/lib/native-gate-simulator.sh'),'run',str(self.root),UDID,'true'],
                                 env=dict(self.env, FAKE_READY_DELAY='60', FAKE_SHUTDOWN_DELAY='2'),
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+20
            while 'simctl bootstatus' not in self.events.read_text() and time.monotonic()<deadline: time.sleep(.02)
            process.terminate()
            deadline=time.monotonic()+20
            while 'simctl shutdown' not in self.events.read_text() and time.monotonic()<deadline: time.sleep(.02)
            process.terminate()
            out,err=process.communicate(timeout=60)
            self.assertEqual(process.returncode,143,err)
            self.assertEqual(json.loads(self.state.read_text())['devices'][RUNTIME][0]['state'],'Shutdown')
        finally:
            if process.poll() is None: process.kill();process.communicate()

    def test_build_and_cache_wait_excluded_from_test_work(self):
        helper=str(self.root / 'scripts/build-with-cache.py')
        first=subprocess.Popen([sys.executable, helper, 'run', 'xcode', 'native-contended', '--', 'xcodebuild', 'build-for-testing'],
                               env=dict(self.env, FAKE_BUILD_DELAY='4', WILTED_TEST_TIMEOUT_SECONDS='10'), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline=time.monotonic()+5
            while 'build start' not in (self.events.read_text() if self.events.exists() else '') and time.monotonic()<deadline: time.sleep(.02)
            result=self.invoke(sys.executable, helper, 'run', 'xcode', 'native-contended', '--', 'xcodebuild', 'test-without-building',
                               env=dict(self.env, WILTED_TEST_TIMEOUT_SECONDS='3', FAKE_TEST_DELAY='.1'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('waiting kind=xcode', result.stderr)
            first.communicate(timeout=5); self.assertEqual(first.returncode, 0)
        finally:
            if first.poll() is None: first.terminate(); first.communicate(timeout=5)

unittest.main(argv=['xcode-lifecycle-tests'], verbosity=2)
PY
