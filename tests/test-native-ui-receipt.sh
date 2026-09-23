#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/wilted-native-ui-receipt.XXXXXX")"
trap 'rm -rf "$temp_root"' EXIT
fixture="$temp_root/repo"
mkdir -p "$fixture/.githooks" "$fixture/scripts" "$fixture/WiltedMac" "$fixture/docs" "$temp_root/bin"
cp "$repo_root/.githooks/pre-push" "$fixture/.githooks/pre-push"
cp "$repo_root/scripts/native-ui-receipt.py" "$fixture/scripts/native-ui-receipt.py"
cp "$repo_root/scripts/mac-ui-surface.paths" "$fixture/scripts/mac-ui-surface.paths"

cat >"$fixture/scripts/test-gate.sh" <<'GATE'
#!/usr/bin/env bash
set -euo pipefail
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
chmod +x "$fixture/.githooks/pre-push" "$fixture/scripts/test-gate.sh" "$temp_root/bin/make"
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
run_push_check() {
  local new_oid="$1" old_oid="$2"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$new_oid" "$old_oid" |
    PATH="$temp_root/bin:$PATH" bash "$fixture/.githooks/pre-push" >"$output" 2>&1
}
assert_blocked() {
  local new_oid="$1" old_oid="$2"
  if run_push_check "$new_oid" "$old_oid"; then
    printf '%s\n' 'assertion failed: surface push passed without a current receipt' >&2
    exit 1
  fi
  grep -Fq 'make native-ui' "$output" || { cat "$output" >&2; exit 1; }
}

printf 'changed\n' >>"$fixture/WiltedMac/surface.txt"
git -C "$fixture" add WiltedMac/surface.txt
git -C "$fixture" commit --no-verify -q -m 'change Mac UI surface'
surface_commit="$(git -C "$fixture" rev-parse HEAD)"
assert_blocked "$surface_commit" "$base"
[[ ! -e "$fixture/.logs/native-ui-receipt.json" ]] || exit 1

printf 'docs only\n' >>"$fixture/docs/note.txt"
git -C "$fixture" add docs/note.txt
git -C "$fixture" commit --no-verify -q -m 'change docs only'
docs_commit="$(git -C "$fixture" rev-parse HEAD)"
run_push_check "$docs_commit" "$surface_commit" || { cat "$output" >&2; exit 1; }
grep -Fq 'surface-unchanged' "$output" || { cat "$output" >&2; exit 1; }

python3 "$fixture/scripts/native-ui-receipt.py" record >"$output" 2>&1 || {
  cat "$output" >&2
  exit 1
}
receipt="$fixture/.logs/native-ui-receipt.json"
python3 - "$receipt" "$docs_commit" <<'PY'
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

printf 'changed again\n' >>"$fixture/WiltedMac/surface.txt"
git -C "$fixture" add WiltedMac/surface.txt
git -C "$fixture" commit --no-verify -q -m 'change Mac UI after receipt'
stale_commit="$(git -C "$fixture" rev-parse HEAD)"
assert_blocked "$stale_commit" "$docs_commit"
grep -Fq 'stale-receipt' "$output" || { cat "$output" >&2; exit 1; }
if {
  printf 'refs/heads/main %s refs/heads/main %s\n' "$stale_commit" "$docs_commit"
  printf 'refs/tags/docs %s refs/tags/docs %s\n' "$docs_commit" "$surface_commit"
} | PATH="$temp_root/bin:$PATH" bash "$fixture/.githooks/pre-push" >"$output" 2>&1; then
  printf '%s\n' 'assertion failed: multi-ref push with one surface change passed' >&2
  exit 1
fi
grep -Fq 'block ref=refs/heads/main' "$output" || { cat "$output" >&2; exit 1; }
grep -Fq 'pass ref=refs/tags/docs' "$output" || { cat "$output" >&2; exit 1; }

printf 'dirty\n' >>"$fixture/docs/note.txt"
before_runs="$(wc -l <"$gate_log")"
before_receipt="$(shasum -a 256 "$receipt")"
if python3 "$fixture/scripts/native-ui-receipt.py" record >"$output" 2>&1; then
  printf '%s\n' 'assertion failed: dirty tree minted a receipt' >&2
  exit 1
fi
grep -Fq 'working tree is dirty' "$output" || { cat "$output" >&2; exit 1; }
[[ "$(wc -l <"$gate_log")" == "$before_runs" ]] || exit 1
[[ "$(shasum -a 256 "$receipt")" == "$before_receipt" ]] || exit 1

printf '%s\n' 'native UI receipt hook test passed'
