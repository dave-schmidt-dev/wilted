#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wilted-file-size.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

checker_output=""
checker_status=0

init_repo() {
  local checkout
  checkout="$(mktemp -d "$tmp_dir/repo.XXXXXX")"
  mkdir -p "$checkout/scripts"
  cp "$repo_root/scripts/check_file_size.py" "$checkout/scripts/check_file_size.py"
  git -C "$checkout" init -q
  git -C "$checkout" config user.name 'Wilted file-size test'
  git -C "$checkout" config user.email 'wilted-file-size@example.invalid'
  printf '%s\n' "$checkout"
}

make_lines() {
  local count="$1" path="$2"
  mkdir -p "$(dirname "$path")"
  awk -v count="$count" 'BEGIN { for (line = 1; line <= count; line++) print "line" }' >"$path"
}

check() {
  local checkout="$1"
  shift
  set +e
  checker_output="$(cd "$checkout" && python3 scripts/check_file_size.py "$@" 2>&1)"
  checker_status=$?
  set -e
}

assert_status() {
  local expected="$1" label="$2"
  if [[ "$checker_status" -ne "$expected" ]]; then
    printf 'assertion failed: %s returned %s, expected %s\n%s\n' \
      "$label" "$checker_status" "$expected" "$checker_output" >&2
    exit 1
  fi
}

assert_contains() {
  local needle="$1" label="$2"
  if [[ "$checker_output" != *"$needle"* ]]; then
    printf 'assertion failed: %s missing %s\n%s\n' "$label" "$needle" "$checker_output" >&2
    exit 1
  fi
}

commit_fixture() {
  local checkout="$1"
  git -C "$checkout" add .
  git -C "$checkout" commit --no-verify -q -m fixture
}

setup_grandfathered_repo() {
  local checkout
  checkout="$(init_repo)"
  make_lines 600 "$checkout/large.py"
  printf '%s\n' 'large.py 600 grandfathered fixture; may shrink, not grow' >"$checkout/.file-size-exceptions"
  commit_fixture "$checkout"
  printf '%s\n' "$checkout"
}

file_repo="$(init_repo)"
make_lines 500 "$file_repo/Boundary.swift"
check "$file_repo" Boundary.swift
assert_status 0 '500-line Swift file'
make_lines 501 "$file_repo/TooBig.swift"
check "$file_repo" TooBig.swift
assert_status 1 '501-line Swift file'
assert_contains TooBig.swift '501-line Swift file'
make_lines 600 "$file_repo/large.json"
make_lines 600 "$file_repo/App.xcodeproj/x.swift"
check "$file_repo" large.json App.xcodeproj/x.swift missing.swift
assert_status 0 'ignored and missing FILE arguments'

caps_repo="$(init_repo)"
make_lines 600 "$caps_repo/large.py"
printf '%s\n' 'large.py 600 justified fixture' >"$caps_repo/.file-size-exceptions"
check "$caps_repo" large.py
assert_status 0 'matching exception cap'
printf '%s\n' 'large.py 599 justified fixture' >"$caps_repo/.file-size-exceptions"
check "$caps_repo" large.py
assert_status 1 'lower exception cap'
assert_contains large.py 'lower exception cap'
make_lines 10 "$caps_repo/small.py"
printf '%s\n' 'small.py 600 justified fixture' >"$caps_repo/.file-size-exceptions"
check "$caps_repo" small.py
assert_status 0 'removable exception'
assert_contains 'remove its exception' 'removable exception'

for invalid_entry in 'broken.py 600' 'broken.py 0 reason' 'broken.py abc reason'; do
  format_repo="$(init_repo)"
  printf '%s\n' "$invalid_entry" >"$format_repo/.file-size-exceptions"
  check "$format_repo" --all
  assert_status 1 "invalid exception: $invalid_entry"
done

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
make_lines 501 "$staged_repo/staged.sh"
git -C "$staged_repo" add staged.sh
check "$staged_repo" --staged
assert_status 1 'staged oversized shell file'
assert_contains staged.sh 'staged oversized shell file'

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
make_lines 500 "$staged_repo/staged.sh"
git -C "$staged_repo" add staged.sh
make_lines 501 "$staged_repo/staged.sh"
check "$staged_repo" --staged
assert_status 0 'working-tree-only growth'

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
make_lines 501 "$staged_repo/untracked.sh"
check "$staged_repo" --staged
assert_status 0 'untracked oversized shell file'

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
printf '%s\n' 'broken.py 600' >"$staged_repo/.file-size-exceptions"
git -C "$staged_repo" add .file-size-exceptions
check "$staged_repo" --staged
assert_status 1 'staged malformed exceptions'

staged_repo="$(init_repo)"
make_lines 501 "$staged_repo/deleted.sh"
commit_fixture "$staged_repo"
git -C "$staged_repo" rm -q deleted.sh
check "$staged_repo" --staged
assert_status 0 'staged oversized deletion'

monotonic_repo="$(setup_grandfathered_repo)"
printf '%s\n' 'large.py 601 grandfathered fixture; may shrink, not grow' >"$monotonic_repo/.file-size-exceptions"
git -C "$monotonic_repo" add .file-size-exceptions
check "$monotonic_repo" --staged
assert_status 1 'raised grandfathered cap'
assert_contains large.py 'raised grandfathered cap'

monotonic_repo="$(setup_grandfathered_repo)"
make_lines 590 "$monotonic_repo/large.py"
printf '%s\n' 'large.py 590 grandfathered fixture; may shrink, not grow' >"$monotonic_repo/.file-size-exceptions"
git -C "$monotonic_repo" add large.py .file-size-exceptions
check "$monotonic_repo" --staged
assert_status 0 'shrunk grandfathered cap'

monotonic_repo="$(setup_grandfathered_repo)"
make_lines 600 "$monotonic_repo/other.py"
printf '%s\n' \
  'large.py 600 grandfathered fixture; may shrink, not grow' \
  'other.py 600 grandfathered fixture; may shrink, not grow' >"$monotonic_repo/.file-size-exceptions"
git -C "$monotonic_repo" add other.py .file-size-exceptions
check "$monotonic_repo" --staged
assert_status 1 'new grandfathered cap'
assert_contains other.py 'new grandfathered cap'

monotonic_repo="$(setup_grandfathered_repo)"
make_lines 600 "$monotonic_repo/other.py"
printf '%s\n' \
  'large.py 600 grandfathered fixture; may shrink, not grow' \
  'other.py 600 independently justified fixture' >"$monotonic_repo/.file-size-exceptions"
git -C "$monotonic_repo" add other.py .file-size-exceptions
check "$monotonic_repo" --staged
assert_status 0 'new non-grandfathered cap'

for exception_change in removed lowered deleted; do
  changed_repo="$(setup_grandfathered_repo)"
  case "$exception_change" in
    removed)
      printf '%s\n' '# no exceptions remain' >"$changed_repo/.file-size-exceptions"
      git -C "$changed_repo" add .file-size-exceptions
      ;;
    lowered)
      printf '%s\n' 'large.py 550 grandfathered fixture; may shrink, not grow' >"$changed_repo/.file-size-exceptions"
      git -C "$changed_repo" add .file-size-exceptions
      ;;
    deleted)
      git -C "$changed_repo" rm -q .file-size-exceptions
      ;;
  esac
  check "$changed_repo" --staged
  assert_status 1 "changed exceptions: $exception_change"
  assert_contains large.py "changed exceptions: $exception_change"
done

all_repo="$(init_repo)"
make_lines 501 "$all_repo/untracked.swift"
check "$all_repo" --all
assert_status 1 'untracked oversized all-mode file'
all_repo="$(init_repo)"
printf '%s\n' 'ignored.swift' >"$all_repo/.gitignore"
make_lines 501 "$all_repo/ignored.swift"
check "$all_repo" --all
assert_status 0 'ignored all-mode file'

usage_repo="$(init_repo)"
check "$usage_repo"
assert_status 2 'missing checker mode'

printf '%s\n' 'file-size checker test passed'
