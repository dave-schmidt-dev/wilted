#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wilted-file-size.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

checker_output=""
checker_stdout=""
checker_stderr=""
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
  checker_stdout="$(cd "$checkout" && python3 scripts/check_file_size.py "$@" 2>"$tmp_dir/checker.stderr")"
  checker_status=$?
  set -e
  checker_stderr="$(<"$tmp_dir/checker.stderr")"
  checker_output="${checker_stdout}${checker_stderr:+$'\n'}${checker_stderr}"
}

check_with_index() {
  local checkout="$1" index_path="$2"
  shift 2
  set +e
  checker_stdout="$(cd "$checkout" && GIT_INDEX_FILE="$index_path" python3 scripts/check_file_size.py "$@" 2>"$tmp_dir/checker.stderr")"
  checker_status=$?
  set -e
  checker_stderr="$(<"$tmp_dir/checker.stderr")"
  checker_output="${checker_stdout}${checker_stderr:+$'\n'}${checker_stderr}"
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

assert_empty() {
  local label="$1"
  if [[ -n "$checker_output" ]]; then
    printf 'assertion failed: %s unexpectedly output:\n%s\n' "$label" "$checker_output" >&2
    exit 1
  fi
}

assert_stdout_contains() {
  local needle="$1" label="$2"
  if [[ "$checker_stdout" != *"$needle"* ]]; then
    printf 'assertion failed: %s missing stdout %s\n%s\n' "$label" "$needle" "$checker_stdout" >&2
    exit 1
  fi
}

assert_stdout_not_contains() {
  local needle="$1" label="$2"
  if [[ "$checker_stdout" == *"$needle"* ]]; then
    printf 'assertion failed: %s unexpectedly found stdout %s\n%s\n' "$label" "$needle" "$checker_stdout" >&2
    exit 1
  fi
}

commit_fixture() {
  local checkout="$1"
  git -C "$checkout" add .
  git -C "$checkout" commit --no-verify -q -m fixture
}

file_repo="$(init_repo)"
make_lines 500 "$file_repo/Boundary.swift"
check "$file_repo" Boundary.swift
assert_status 0 '500-line file'
assert_empty '500-line file'
make_lines 501 "$file_repo/Warning.swift"
check "$file_repo" Warning.swift
assert_status 0 '501-line file'
assert_contains 'file-size: Warning.swift has 501 lines (target 500)' '501-line warning'
make_lines 800 "$file_repo/Ceiling.swift"
check "$file_repo" Ceiling.swift
assert_status 0 '800-line file'
assert_contains 'file-size: Ceiling.swift has 800 lines (target 500)' '800-line warning'
make_lines 801 "$file_repo/TooBig.swift"
check "$file_repo" TooBig.swift
assert_status 1 '801-line file'
assert_contains 'TooBig.swift has 801 lines' '801-line error'
printf '%s\n' 'TooBig.swift required single-file fixture' >"$file_repo/.file-size-exceptions"
check "$file_repo" TooBig.swift
assert_status 0 'listed 801-line file'
printf '%s\n' 'TooBig.swift legacy oversized fixture' >"$file_repo/.file-size-exceptions"
check "$file_repo" TooBig.swift
assert_status 0 'legacy FILE-mode file'
assert_stdout_contains \
  'file-size: TooBig.swift is a legacy exception (801 lines); extract a clean seam from it in this piece of work' \
  'legacy FILE-mode notice'
make_lines 10 "$file_repo/Small.swift"
printf '%s\n' 'Small.swift required single-file fixture' >"$file_repo/.file-size-exceptions"
check "$file_repo" Small.swift
assert_status 0 'listed 10-line file'
assert_contains 'remove its exception' 'listed 10-line removal note'
make_lines 900 "$file_repo/ignored.json"
make_lines 900 "$file_repo/App.xcodeproj/ignored.swift"
check "$file_repo" ignored.json App.xcodeproj/ignored.swift missing.swift
assert_status 0 'ignored and missing FILE arguments'

format_repo="$(init_repo)"
printf '%s\n' 'reasonless.py' >"$format_repo/.file-size-exceptions"
check "$format_repo" --all
assert_status 1 'reason-less exception'
assert_contains 'needs a reason' 'reason-less exception'
format_repo="$(init_repo)"
printf '%s\n' 'legacy.py 801 old cap format' >"$format_repo/.file-size-exceptions"
check "$format_repo" --all
assert_status 1 'cap-format exception'
assert_contains 'line caps are no longer supported; remove the cap' 'cap-format exception'
format_repo="$(init_repo)"
printf '%s\n' 'duplicate.py first reason' 'duplicate.py second reason' >"$format_repo/.file-size-exceptions"
check "$format_repo" --all
assert_status 1 'duplicate exception'
assert_contains 'duplicate exception path duplicate.py' 'duplicate exception'

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
make_lines 801 "$staged_repo/staged.sh"
git -C "$staged_repo" add staged.sh
check "$staged_repo" --staged
assert_status 1 'staged 801-line file'
assert_contains 'staged.sh has 801 lines' 'staged 801-line error'

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
make_lines 801 "$staged_repo/legacy.sh"
printf '%s\n' 'legacy.sh legacy oversized fixture' >"$staged_repo/.file-size-exceptions"
git -C "$staged_repo" add legacy.sh .file-size-exceptions
check "$staged_repo" --staged
assert_status 0 'staged legacy file'
assert_stdout_contains \
  'file-size: legacy.sh is a legacy exception (801 lines); extract a clean seam from it in this piece of work' \
  'staged legacy notice'

file_repo="$(init_repo)"
make_lines 801 "$file_repo/nonlegacy.py"
printf '%s\n' 'nonlegacy.py required oversized fixture' >"$file_repo/.file-size-exceptions"
check "$file_repo" nonlegacy.py
assert_status 0 'non-legacy file'
assert_stdout_not_contains 'is a legacy exception' 'non-legacy reason'

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
make_lines 800 "$staged_repo/staged.sh"
git -C "$staged_repo" add staged.sh
make_lines 801 "$staged_repo/staged.sh"
check "$staged_repo" --staged
assert_status 0 'working-tree-only growth'
assert_contains 'staged.sh has 800 lines (target 500)' 'staged 800-line warning'

staged_repo="$(init_repo)"
commit_fixture "$staged_repo"
make_lines 801 "$staged_repo/untracked.sh"
check "$staged_repo" --staged
assert_status 0 'untracked 801-line file'

index_repo="$(init_repo)"
commit_fixture "$index_repo"
make_lines 801 "$index_repo/alternate.py"
alternate_index="$tmp_dir/alternate.index"
cp "$index_repo/.git/index" "$alternate_index"
GIT_INDEX_FILE="$alternate_index" git -C "$index_repo" add alternate.py
check_with_index "$index_repo" "$alternate_index" --staged
assert_status 1 'alternate index staged 801-line file'
assert_contains 'alternate.py has 801 lines' 'alternate index error'

exceptions_repo="$(init_repo)"
make_lines 801 "$exceptions_repo/committed.py"
printf '%s\n' 'committed.py legacy oversized fixture' >"$exceptions_repo/.file-size-exceptions"
commit_fixture "$exceptions_repo"
printf '%s\n' '# staged exceptions-only change' >>"$exceptions_repo/.file-size-exceptions"
git -C "$exceptions_repo" add .file-size-exceptions
make_lines 802 "$exceptions_repo/committed.py"
check "$exceptions_repo" --staged
assert_status 0 'exceptions-only staged legacy file'
assert_stdout_not_contains 'is a legacy exception' 'exceptions-only staged legacy notice'

exceptions_repo="$(init_repo)"
make_lines 801 "$exceptions_repo/committed.py"
printf '%s\n' 'committed.py required legacy fixture' >"$exceptions_repo/.file-size-exceptions"
commit_fixture "$exceptions_repo"
printf '%s\n' '# entry intentionally removed' >"$exceptions_repo/.file-size-exceptions"
git -C "$exceptions_repo" add .file-size-exceptions
check "$exceptions_repo" --staged
assert_status 1 'staged exceptions removal'
assert_contains 'committed.py has 801 lines' 'staged exceptions removal error'

exceptions_repo="$(init_repo)"
make_lines 801 "$exceptions_repo/committed.py"
printf '%s\n' 'committed.py required legacy fixture' >"$exceptions_repo/.file-size-exceptions"
commit_fixture "$exceptions_repo"
git -C "$exceptions_repo" rm -q .file-size-exceptions
check "$exceptions_repo" --staged
assert_status 1 'staged exceptions deletion'
assert_contains 'committed.py has 801 lines' 'staged exceptions deletion error'

all_repo="$(init_repo)"
make_lines 801 "$all_repo/untracked.swift"
check "$all_repo" --all
assert_status 1 'untracked 801-line all-mode file'
all_repo="$(init_repo)"
make_lines 801 "$all_repo/legacy.swift"
printf '%s\n' 'legacy.swift legacy oversized fixture' >"$all_repo/.file-size-exceptions"
check "$all_repo" --all
assert_status 0 'legacy all-mode file'
assert_stdout_not_contains 'is a legacy exception' 'legacy all-mode notice'
all_repo="$(init_repo)"
printf '%s\n' 'ignored.swift' >"$all_repo/.gitignore"
make_lines 801 "$all_repo/ignored.swift"
check "$all_repo" --all
assert_status 0 'ignored 801-line all-mode file'

usage_repo="$(init_repo)"
check "$usage_repo"
assert_status 2 'missing checker mode'

check "$repo_root" --all
assert_status 0 'repository audit'

printf '%s\n' 'file-size checker test passed'
