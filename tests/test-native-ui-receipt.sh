#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temp_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-native-ui-receipt.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT
fixture="$temp_root/repo"
mkdir -p "$fixture/scripts/lib" "$fixture/WiltedMac" "$fixture/docs" "$temp_root/bin"
cp "$repo_root/scripts/native-ui-receipt.py" "$fixture/scripts/native-ui-receipt.py"
cp "$repo_root/scripts/mac-ui-surface.paths" "$fixture/scripts/mac-ui-surface.paths"
cp "$repo_root/scripts/run-bounded.py" "$fixture/scripts/run-bounded.py"
cp "$repo_root/scripts/lib/test-runner.sh" "$fixture/scripts/lib/test-runner.sh"

cat >"$fixture/scripts/test-gate.sh" <<'GATE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
printf 'run\n' >>"${WILTED_FAKE_GATE_LOG:?}"
for leg in xcodegen-reproducible wiltedkit-tests cloudsync-tests listener-tests wiltedproducer-tests macos-unit-tests ios-unit-tests macos-ui-tests ios-pixel-snapshot-tests; do
  printf 'native.leg.start name=%s\n' "$leg"
  if [[ "$leg" != xcodegen-reproducible ]]; then
    printf 'native.tests label=%s reported=2\n' "$leg"
  fi
  printf 'native.leg.complete name=%s status=0\n' "$leg"
done
printf '%s\n' 'native.complete failed_legs=0 total_legs=9 deferred_legs=0' 'native.passed count=9'
GATE
cat >"$temp_root/bin/make" <<'MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf 'fake.make %s\n' "$*" >&2
MAKE
chmod +x "$fixture/scripts/test-gate.sh" "$temp_root/bin/make"
printf '.logs/\n' >"$fixture/.gitignore"
printf 'initial\n' >"$fixture/WiltedMac/surface.txt"
printf 'initial\n' >"$fixture/docs/note.txt"
git -C "$fixture" init -q
git -C "$fixture" config user.name 'Wilted receipt test'
git -C "$fixture" config user.email 'wilted-receipt@example.invalid'
git -C "$fixture" add .
git -C "$fixture" commit --no-verify -q -m 'fixture base'
base="$(git -C "$fixture" rev-parse HEAD)"

gate_log="$temp_root/gate-runs.log"
export WILTED_FAKE_GATE_LOG="$gate_log"
output="$temp_root/output.log"
receipt="$fixture/.logs/native-ui-receipt.json"
receipt_py="$fixture/scripts/native-ui-receipt.py"
check_head() { env -u WILTED_SKIP_UI_RECEIPT python3 "$receipt_py" check-head >"$output" 2>&1; }
assert_blocked() {
  if check_head; then
    printf '%s\n' "assertion failed: install check passed: $1" >&2
    cat "$output" >&2
    exit 1
  fi
  grep -Fq 'make native-ui' "$output" || { cat "$output" >&2; exit 1; }
  grep -Fq -- "$1" "$output" || { cat "$output" >&2; exit 1; }
}
assert_passes() {
  check_head || { cat "$output" >&2; exit 1; }
  grep -Fq "$1" "$output" || { cat "$output" >&2; exit 1; }
}
commit_change() {
  printf '%s\n' "$2" >>"$fixture/$1"
  git -C "$fixture" add "$1"
  git -C "$fixture" commit --no-verify -q -m "$3"
}

# No receipt: the install check refuses, and the override names "none".
assert_blocked 'missing-receipt'
env WILTED_SKIP_UI_RECEIPT=1 python3 "$receipt_py" check-head >"$output" 2>&1 || { cat "$output" >&2; exit 1; }
grep -Fq 'WARNING skipped=true' "$output" && grep -Fq 'receipt=none' "$output" || { cat "$output" >&2; exit 1; }
# The override is exactly "1": any other value does not skip.
if env WILTED_SKIP_UI_RECEIPT=0 python3 "$receipt_py" check-head >"$output" 2>&1; then exit 1; fi

# A filtered gate never mints a receipt, and the gate is not even started.
if env WILTED_GATE_LEGS=macos-unit-tests python3 "$receipt_py" record >"$output" 2>&1; then
  printf '%s\n' 'assertion failed: a filtered run minted a receipt' >&2
  exit 1
fi
grep -Fq 'reason=filtered-gate' "$output" || { cat "$output" >&2; exit 1; }
[[ ! -e "$receipt" && ! -e "$gate_log" ]] || exit 1

commit_change WiltedMac/surface.txt changed 'change Mac UI surface'
python3 "$receipt_py" record >"$output" 2>&1 || { cat "$output" >&2; exit 1; }
head_commit="$(git -C "$fixture" rev-parse HEAD)"
python3 - "$receipt" "$head_commit" <<'PY'
import datetime as dt
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
assert receipt["commit"] == sys.argv[2]
assert receipt["describe"]
assert dt.datetime.fromisoformat(receipt["createdAt"].replace("Z", "+00:00"))
assert len(receipt["testCounts"]) == 9
assert receipt["testCounts"]["xcodegen-reproducible"] == 0
assert receipt["testCounts"]["macos-ui-tests"] == 2
PY
assert_passes 'reason=surface-unchanged'

# A docs-only commit after the receipt still installs.
commit_change docs/note.txt 'docs only' 'change docs only'
assert_passes "receipt=$head_commit"

# New surface commits, staged edits, unstaged edits and untracked files all block.
commit_change WiltedMac/surface.txt again 'change Mac UI after receipt'
assert_blocked 'stale-receipt'
git -C "$fixture" reset -q --hard "$head_commit"
printf 'unstaged\n' >>"$fixture/WiltedMac/surface.txt"
assert_blocked 'changed=WiltedMac/surface.txt'
git -C "$fixture" checkout -q -- WiltedMac/surface.txt
printf 'new\n' >"$fixture/WiltedMac/new-view.txt"
assert_blocked 'changed=WiltedMac/new-view.txt'
rm "$fixture/WiltedMac/new-view.txt"
assert_passes 'reason=surface-unchanged'

# The override proceeds on a stale tree and names the receipt it ignores.
commit_change WiltedMac/surface.txt stale 'stale again'
env WILTED_SKIP_UI_RECEIPT=1 python3 "$receipt_py" check-head >"$output" 2>&1 || { cat "$output" >&2; exit 1; }
grep -Fq "receipt=$head_commit" "$output" && grep -Fq 'WARNING skipped=true' "$output" || { cat "$output" >&2; exit 1; }

# A dirty tree still cannot mint a receipt.
printf 'dirty\n' >>"$fixture/docs/note.txt"
before_runs="$(wc -l <"$gate_log")"
before_receipt="$(shasum -a 256 "$receipt")"
if python3 "$receipt_py" record >"$output" 2>&1; then
  printf '%s\n' 'assertion failed: dirty tree minted a receipt' >&2
  exit 1
fi
grep -Fq 'working tree is dirty' "$output" || { cat "$output" >&2; exit 1; }
[[ "$(wc -l <"$gate_log")" == "$before_runs" ]] || exit 1
[[ "$(shasum -a 256 "$receipt")" == "$before_receipt" ]] || exit 1

printf '%s\n' 'native UI receipt install-check test passed'
