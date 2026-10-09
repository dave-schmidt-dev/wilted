"""Owned fake Xcode/simctl setup shared by the existing lifecycle meta-suite."""
import json
import os
from pathlib import Path
import shutil
import tempfile

RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-0'
TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
UDID = '11111111-1111-1111-1111-111111111111'

class XcodeFixture:
    """Copy canonical helpers and provision fake tools inside an owned temp root."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wilted-xcode-meta-', dir=os.environ['TMPDIR'])
        self.root = Path(self.temp.name).resolve()
        scripts = self.root / 'scripts'; (scripts / 'lib').mkdir(parents=True)
        for path in ['run-bounded.py', 'build-with-cache.py', 'check-temp-leaks.py', 'lib/native-gate-simulator.sh', 'lib/simctl_gate_lib.sh', 'lib/native-gate-xcode.sh', 'lib/mac-test-parent.sh', 'lib/test-runner.sh', 'select-ios-simulator.py']:
            shutil.copy(self.repository_root / 'scripts' / path, scripts / path)
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.state = self.root / 'devices.json'; self.events = self.root / 'events'
        self.state.write_text(json.dumps({'devices': {RUNTIME: []}}))
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        TMPDIR=str(self.root), FAKE_STATE=str(self.state), FAKE_EVENTS=str(self.events),
                        APPLE_UI_TEST_LOCK=str(self.bin / 'ui-lock'), GATE_XCTEST_DEVICE_SET=str(self.root / 'no-clones'),
                        WILTED_BOUNDED_HEARTBEAT_SECONDS='.1')
        (self.bin / 'ui-lock').write_text('#!/bin/bash\nwhile [[ "$1" != -- ]]; do shift; done\nshift\nexec "$@"\n')
        (self.bin / 'xcrun').write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
p=Path(os.environ['FAKE_STATE']); state=json.loads(p.read_text()); args=sys.argv[1:]
with open(os.environ['FAKE_EVENTS'],'a') as f: f.write(' '.join(args)+'\\n')
devices=next(iter(state['devices'].values()))
if args[:2]==['simctl','--set']:
 clone_path=Path(os.environ['FAKE_CLONE_STATE']); clones=json.loads(clone_path.read_text()); clone_devices=next(iter(clones['devices'].values()))
 if args[3]=='list': print(json.dumps(clones))
 elif args[3]=='shutdown':
  next(d for d in clone_devices if d['udid']==args[4])['state']='Shutdown'; clone_path.write_text(json.dumps(clones))
 elif args[3]=='delete':
  if os.environ.get('FAKE_CLONE_FAILURE'): raise SystemExit(23)
  clone_devices[:]=[d for d in clone_devices if d['udid']!=args[4]]; clone_path.write_text(json.dumps(clones))
 else: raise SystemExit(2)
 raise SystemExit(0)
if args[:3]==['simctl','list','runtimes']:
 print(Path(os.environ['FAKE_RUNTIMES']).read_text()); raise SystemExit(0)
if args[:3]==['simctl','list','devices']:
 if os.environ.get('FAKE_INVENTORY_HANG'):
  child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
  Path(os.environ['FAKE_INVENTORY_PIDS']).write_text(str(os.getpid())+' '+str(child.pid))
  time.sleep(60)
 print(json.dumps(state))
elif args[1]=='create':
 devices.append({'udid':'11111111-1111-1111-1111-111111111111','name':args[2],
 'deviceTypeIdentifier':args[3],'state':'Shutdown','isAvailable':True}); p.write_text(json.dumps(state)); print(devices[-1]['udid'])
elif args[1]=='boot': devices[0]['state']='Booted'; p.write_text(json.dumps(state))
elif args[1]=='bootstatus': time.sleep(float(os.environ.get('FAKE_READY_DELAY','0')))
elif args[1]=='shutdown':
 time.sleep(float(os.environ.get('FAKE_SHUTDOWN_DELAY','0')))
 devices[0]['state']='Shutdown'; p.write_text(json.dumps(state))
else: raise SystemExit(2)
''')
        (self.bin / 'xcodebuild').write_text('''#!/usr/bin/env python3
import os, sys, time
from pathlib import Path
args=sys.argv[1:]; phase='build' if 'build-for-testing' in args else 'test'
if os.environ.get('FAKE_REQUIRE_FRAMEWORK'):
 import xml.etree.ElementTree as ET
 scheme=Path(args[args.index('-project')+1]) / 'xcshareddata/xcschemes/WiltedMac.xcscheme'
 values={x.get('key'):x.get('value') for x in ET.parse(scheme).getroot().findall('TestAction/EnvironmentVariables/EnvironmentVariable') if x.get('isEnabled')=='YES'}
 expected=str(Path(os.environ['FAKE_EXPECTED_FRAMEWORK']))
 if values.get('DYLD_FRAMEWORK_PATH')!=expected: raise SystemExit(41)
 if values.get('WILTED_TEST_TMPDIR')!=os.environ['FAKE_MANAGED_PARENT']: raise SystemExit(43)
 if not all(values.get(k) for k in ['WILTED_TEST_OWNER_PID','WILTED_TEST_OWNER_STARTED','WILTED_TEST_OWNER_PATH']): raise SystemExit(44)
if os.environ.get('FAKE_PRODUCT_MARKER'):
 marker=Path(os.environ['FAKE_PRODUCT_MARKER']); candidate=os.environ['FAKE_CANDIDATE']
 if phase=='build' or 'test' in args: marker.write_text(candidate)
 elif marker.read_text()!=candidate: raise SystemExit(42)
if 'test' in args:
 with open(os.environ['FAKE_EVENTS'],'a') as f:f.write('build start\\n')
 time.sleep(float(os.environ.get('FAKE_BUILD_DELAY','0')))
 with open(os.environ['FAKE_EVENTS'],'a') as f:f.write('build end\\n')
with open(os.environ['FAKE_EVENTS'],'a') as f: f.write(phase+' start\\n')
if phase=='test' and os.environ.get('FAKE_MANAGED_PARENT'):
 import json,subprocess
 parent=Path(os.environ['FAKE_MANAGED_PARENT']);root=parent / 'wilted-mac-test-from-host';root.mkdir()
 owner=dict(line.split('=',1) for line in (parent.parent / '.wilted-temp-owned').read_text().splitlines())
 st=root.stat();started=subprocess.check_output(['/bin/ps','-o','lstart=','-p',str(os.getpid())],text=True).strip()
 (root / '.wilted-managed-test-root').write_text(json.dumps(dict(path=str(root),device=st.st_dev,inode=st.st_ino,host_pid=os.getpid(),host_started=started,owner_path=str(parent.parent),owner_pid=int(owner['pid']),owner_started=owner['started'].strip())))
 with open(os.environ['FAKE_EVENTS'],'a') as f:f.write('root created\\n')
time.sleep(float(os.environ.get('FAKE_'+phase.upper()+'_DELAY','0')))
with open(os.environ['FAKE_EVENTS'],'a') as f: f.write(phase+' end\\n')
raise SystemExit(int(os.environ.get('FAKE_TEST_STATUS','0')) if phase=='test' else 0)
''')
        for p in self.bin.iterdir(): p.chmod(0o755)
    def tearDown(self): self.temp.cleanup()
