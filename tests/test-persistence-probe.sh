#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package="$repo_root/Probes/PersistenceProbe"
source "$repo_root/scripts/lib/test-temp-state.sh"
work_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-persistence-probe-tests.XXXXXX")"; wilted_temp_mark_owned "$work_dir"
trap 'rm -rf "$work_dir"' EXIT
# The probe and its XCTest suite keep their fixed-name store root under TMPDIR, so nest it in
# this marked root: a sibling gate's audit then attributes it to this live run.
export TMPDIR="$work_dir"
output_file="$work_dir/output.log"
status_file="$work_dir/status.log"

printf '%s\n' 'stage=persistence-probe-tests.start' >&2
python3 "$repo_root/scripts/build-with-cache.py" run swiftpm persistence-probe -- swift test --package-path "$package" 2>&1 | tee "$output_file"
test_count="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$output_file" | tail -1)"
if [[ -z "$test_count" || "$test_count" -eq 0 ]]; then
  printf '%s\n' 'persistence probe runner found zero XCTest cases' >&2
  exit 1
fi

python3 "$repo_root/scripts/build-with-cache.py" run swiftpm persistence-probe -- swift build --package-path "$package" >/dev/null
probe_bin="$(python3 "$repo_root/scripts/build-with-cache.py" run swiftpm persistence-probe -- swift build --package-path "$package" --show-bin-path)/persistence-probe"
[[ -x "$probe_bin" ]] || { printf '%s\n' 'persistence probe executable was not built' >&2; exit 1; }

result="$("$probe_bin" 2> >(tee "$status_file" >&2))"
printf '%s\n' "$result"
if ! printf '%s\n' "$result" | grep -q '"passed":true'; then
  printf '%s\n' 'persistence probe did not pass' >&2
  exit 1
fi
for stage in store.open.ready concurrent-callbacks.complete probe.complete; do
  grep -q "stage=$stage" "$status_file" || { printf 'missing status: %s\n' "$stage" >&2; exit 1; }
done

crash_dir="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-persistence-crash.XXXXXX")"; wilted_temp_mark_owned "$crash_dir"
crash_store="$crash_dir/store.sqlite"
set +e
"$probe_bin" --durable-child "$crash_store" >"$output_file" 2>"$status_file"
child_status=$?
set -e
if [[ "$child_status" -ne 0 ]]; then
  printf 'durable child failed with status %s\n' "$child_status" >&2
  cat "$status_file" >&2
  exit 1
fi
reopened="$("$probe_bin" --inspect "$crash_store" 2> >(tee "$status_file" >&2))"
printf '%s\n' "$reopened"
for category in articles revisions playback journal syncState tombstones; do
  printf '%s\n' "$reopened" | grep -q "\"$category\":1" || { printf 'durable-before-exit store missing category: %s\n' "$category" >&2; exit 1; }
done
printf 'stage=persistence-probe-tests.complete count=%s\n' "$test_count" >&2
