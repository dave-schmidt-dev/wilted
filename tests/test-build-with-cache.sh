#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/tests/test_build_with_cache.py"

# File Provider detritus: `run swiftpm` clears xattrs before the build and
# retries exactly once when codesign reports Finder information detritus.
finder_info=5445585454455854000000000000000000000000000000000000000000000000
tmp_root="$(~/.agent/bin/scratch-dir wilted-xattr-retry)"
xattr_key="test-xattr-retry-$$"
xattr_cache="$repo_root/.build/swiftpm/$xattr_key"
xattr_lock="$repo_root/.build/swiftpm/.locks/$xattr_key.lock"
cleanup_xattr_fixture() {
  rm -rf "$tmp_root" "$xattr_cache"
  rm -f "$xattr_lock"
}
trap cleanup_xattr_fixture EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$tmp_root/bin" "$xattr_cache/out/Products/Debug"
products_file="$xattr_cache/out/Products/Debug/Fixture.xctest"
: >"$products_file"
cat >"$tmp_root/bin/swift" <<'SWIFT'
#!/usr/bin/env bash
set -euo pipefail
printf 'invoked\n' >>"$XATTR_TEST_COUNT"
if xattr -p com.apple.FinderInfo "$XATTR_TEST_FILE" >/dev/null 2>&1; then
  printf 'tagged\n' >>"$XATTR_TEST_SEEN"
fi
case "$XATTR_TEST_MODE" in
  detritus-once)
    if [[ ! -e "$XATTR_TEST_STATE" ]]; then
      : >"$XATTR_TEST_STATE"
      xattr -wx com.apple.FinderInfo "$XATTR_TEST_FINDER_INFO" "$XATTR_TEST_FILE"
      printf '%s: resource fork, Finder information, or similar detritus not allowed\n' \
        "$XATTR_TEST_FILE" >&2
      exit 1
    fi
    printf 'build ok\n'
    ;;
  plain-failure)
    printf 'error: unrelated compile failure\n' >&2
    exit 3
    ;;
  sleep)
    printf '%s\n' "$$" >"$XATTR_TEST_STATE"
    sleep 30
    ;;
  *) printf 'build ok\n' ;;
esac
SWIFT
chmod +x "$tmp_root/bin/swift"

case_status=0
invocations=0
retries=0
run_case() {
  local mode="$1"
  rm -f "$tmp_root/count" "$tmp_root/seen" "$tmp_root/state"
  set +e
  env PATH="$tmp_root/bin:$PATH" XATTR_TEST_MODE="$mode" XATTR_TEST_FILE="$products_file" \
    XATTR_TEST_COUNT="$tmp_root/count" XATTR_TEST_SEEN="$tmp_root/seen" \
    XATTR_TEST_STATE="$tmp_root/state" XATTR_TEST_FINDER_INFO="$finder_info" \
    WILTED_TEST_TIMEOUT_SECONDS=60 \
    python3 "$repo_root/scripts/build-with-cache.py" run swiftpm "$xattr_key" -- swift build \
    >"$tmp_root/stdout" 2>"$tmp_root/stderr"
  case_status=$?
  set -e
  invocations="$(wc -l <"$tmp_root/count" | tr -d ' ')"
  retries="$(grep -c 'native.xattr.retry' "$tmp_root/stderr" || true)"
}

# 1. A nonzero FinderInfo in the products dir is cleared before the build runs.
xattr -wx com.apple.FinderInfo "$finder_info" "$products_file"
xattr -p com.apple.FinderInfo "$products_file" >/dev/null || fail "fixture FinderInfo was not set"
run_case pass
[[ "$case_status" == 0 ]] || fail "clean build exited $case_status"
[[ ! -e "$tmp_root/seen" ]] || fail "build saw FinderInfo that should have been cleared"
if xattr -p com.apple.FinderInfo "$products_file" >/dev/null 2>&1; then
  fail "FinderInfo survived the run"
fi
[[ "$invocations" == 1 && "$retries" == 0 ]] || fail "clean build: invocations=$invocations retries=$retries"
grep -q '^build ok$' "$tmp_root/stdout" || fail "child stdout was not relayed to stdout"

# Cleanup must not follow a cache symlink and strip an external file's metadata.
outside_tagged="$tmp_root/outside-tagged-file"
: >"$outside_tagged"
xattr -wx com.apple.FinderInfo "$finder_info" "$outside_tagged"
ln -s "$outside_tagged" "$xattr_cache/linked-outside-file"
run_case pass
[[ "$case_status" == 0 ]] || fail "symlink-safety build exited $case_status"
xattr -p com.apple.FinderInfo "$outside_tagged" >/dev/null \
  || fail "cache cleanup stripped FinderInfo through an external symlink"

# 2. Detritus failure: cleared again, retried exactly once, then passes.
run_case detritus-once
[[ "$case_status" == 0 ]] || fail "detritus retry exited $case_status"
[[ "$invocations" == 2 && "$retries" == 1 ]] || fail "detritus: invocations=$invocations retries=$retries"
[[ ! -e "$tmp_root/seen" ]] || fail "retry saw FinderInfo that should have been cleared"
if xattr -p com.apple.FinderInfo "$products_file" >/dev/null 2>&1; then
  fail "FinderInfo survived the retry"
fi
grep -q 'similar detritus' "$tmp_root/stderr" || fail "first attempt stderr was not relayed"

# 3. Any other failure keeps its status and is not retried.
run_case plain-failure
[[ "$case_status" == 3 ]] || fail "plain failure exited $case_status, expected 3"
[[ "$invocations" == 1 && "$retries" == 0 ]] || fail "plain failure: invocations=$invocations retries=$retries"

# 4. TERM to the helper reaches the build and the helper dies by TERM.
rm -f "$tmp_root/count" "$tmp_root/state"
env PATH="$tmp_root/bin:$PATH" XATTR_TEST_MODE=sleep XATTR_TEST_FILE="$products_file" \
  XATTR_TEST_COUNT="$tmp_root/count" XATTR_TEST_SEEN="$tmp_root/seen" \
  XATTR_TEST_STATE="$tmp_root/state" WILTED_TEST_TIMEOUT_SECONDS=60 \
  python3 "$repo_root/scripts/build-with-cache.py" run swiftpm "$xattr_key" -- swift build \
  >"$tmp_root/stdout" 2>"$tmp_root/stderr" &
helper_pid=$!
for _ in $(seq 1 100); do [[ -s "$tmp_root/state" ]] && break; sleep 0.1; done
[[ -s "$tmp_root/state" ]] || fail "sleeping build never started"
build_pid="$(cat "$tmp_root/state")"
kill -TERM "$helper_pid"
set +e
wait "$helper_pid"
term_status=$?
set -e
[[ "$term_status" == 143 ]] || fail "TERM helper exited $term_status, expected 143"
for _ in $(seq 1 30); do kill -0 "$build_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$build_pid" 2>/dev/null; then
  kill -KILL "$build_pid" 2>/dev/null || true
  fail "build pid $build_pid survived TERM to the helper"
fi
python3 - "$repo_root" <<'PY'
import importlib.util
import signal
import sys
from pathlib import Path

root = Path(sys.argv[1])
helper = root / "scripts/build-with-cache.py"
spec = importlib.util.spec_from_file_location("build_with_cache_budget_test", helper)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Clock:
    now = 0.0

    def monotonic(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds

clock = Clock()
real_monotonic = module.time.monotonic
real_clear = module.clear_xattrs
real_relay = module.relay_attempt
real_kill = module.os.kill
original_handlers = {
    signum: signal.getsignal(signum)
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
}
lock = open("/dev/null", "rb")
try:
    module.time.monotonic = clock.monotonic
    build_budgets = []

    def consume_preclear(_cache, _reason, *_args):
        clock.advance(3)
        return 0

    def record_build(argv, *_args):
        build_budgets.append(float(argv[argv.index("--timeout-seconds") + 1]))
        return 0, False

    module.clear_xattrs = consume_preclear
    module.relay_attempt = record_build
    status = module.run_swiftpm_with_retry(
        root / "scripts/run-bounded.py", ["swift", "build"], root,
        10, lock.fileno(),
    )
    assert status == 0, status
    assert build_budgets == [7], f"pre-build cleanup must reduce the first build budget: {build_budgets}"

    clock.now = 0.0
    build_budgets.clear()

    def consume_retry_clear(_cache, reason, *_args):
        if reason == "detritus":
            clock.advance(8)
            return 124
        return 0

    def exhaust_retry(argv, *_args):
        if "/usr/bin/xattr" not in argv:
            budget = float(argv[argv.index("--timeout-seconds") + 1])
            build_budgets.append(budget)
            if len(build_budgets) == 1:
                clock.advance(2)
                return 1, True
        return 0, False

    module.clear_xattrs = consume_retry_clear
    module.relay_attempt = exhaust_retry
    status = module.run_swiftpm_with_retry(
        root / "scripts/run-bounded.py", ["swift", "build"], root,
        10, lock.fileno(),
    )
    assert status == 124, f"retry cleanup exhausted the build budget but returned {status}"
    assert len(build_budgets) == 1, f"retry build launched after cleanup exhausted its budget: {build_budgets}"

    clock.now = 0.0
    build_budgets.clear()
    module.clear_xattrs = lambda *_args: 125
    module.relay_attempt = record_build
    status = module.run_swiftpm_with_retry(
        root / "scripts/run-bounded.py", ["swift", "build"], root,
        10, lock.fileno(),
    )
    assert status == 125, f"cleanup supervisor failure was ignored: {status}"
    assert not build_budgets, f"build launched after cleanup supervisor failure: {build_budgets}"

    clock.now = 0.0
    module.clear_xattrs = lambda *_args: 7
    build_budgets.clear()
    status = module.run_swiftpm_with_retry(
        root / "scripts/run-bounded.py", ["swift", "build"], root,
        10, lock.fileno(),
    )
    assert status == 0, f"ordinary xattr failure should remain a warning: {status}"
    assert len(build_budgets) == 1, f"ordinary xattr failure prevented the build: {build_budgets}"

    for signum, handler in original_handlers.items():
        signal.signal(signum, handler)
    clock.now = 20.0
    module.clear_xattrs = real_clear
    cleanup_launches = []

    def inspect_cleanup(argv, _lock, _pending, _current):
        cleanup_launches.append((argv, module.os.environ.get("WILTED_WORK_PHASE"),
                                 module.os.environ.get("WILTED_BOUNDED_HEARTBEAT_SECONDS")))
        return 0, False

    module.relay_attempt = inspect_cleanup
    cleanup_deadline = clock.now + 5
    status = module.clear_xattrs(
        root, "progress-probe", root / "scripts/run-bounded.py", cleanup_deadline,
        lock.fileno(), [], [],
    )
    argv, phase, heartbeat = cleanup_launches[0]
    assert status == 0, status
    assert argv[argv.index("--timeout-seconds") + 1] == "5"
    assert argv[argv.index("--") + 1:argv.index("--") + 4] == ["/usr/bin/xattr", "-crs", str(root)]
    assert phase == "native-xattr-cleanup", phase
    assert 0 < float(heartbeat) <= 15, heartbeat
    assert module.os.environ.get("WILTED_WORK_PHASE") != "native-xattr-cleanup"

    forwarded = []
    parent_signals = []
    module.time.monotonic = clock.monotonic

    class FakeCleanupProcess:
        def send_signal(self, signum):
            forwarded.append(signum)

    def cancel_during_cleanup(argv, _lock, _pending, current):
        assert "/usr/bin/xattr" in argv
        current[:] = [FakeCleanupProcess()]
        signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        current.clear()
        return -signal.SIGTERM, False

    module.relay_attempt = cancel_during_cleanup
    module.os.kill = lambda _pid, signum: parent_signals.append(signum)
    status = module.run_swiftpm_with_retry(
        root / "scripts/run-bounded.py", ["swift", "build"], root,
        10, lock.fileno(),
    )
    assert status == -signal.SIGTERM, status
    assert forwarded == [signal.SIGTERM], forwarded
    assert parent_signals == [signal.SIGTERM], parent_signals
finally:
    module.time.monotonic = real_monotonic
    module.clear_xattrs = real_clear
    module.relay_attempt = real_relay
    module.os.kill = real_kill
    for signum, handler in original_handlers.items():
        signal.signal(signum, handler)
    lock.close()
print("build-with-cache budget, progress, and cleanup cancellation regressions passed")
PY

printf 'build-with-cache xattr retry checks passed\n'
