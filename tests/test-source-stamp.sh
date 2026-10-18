#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Tests source revision stamping and configuration wiring.
#
# Asserts wilted_source_stamp resolves the short commit SHA, marks dirty trees
# with a -dirty suffix, ignores untracked files, safely handles non-git trees
# with exit 0, and that WiltedSourceCommit is configured in project.yml and
# WiltedMac/Info.plist.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
library="$repo_root/scripts/lib/source-stamp.sh"
project="$repo_root/project.yml"
info_plist="$repo_root/WiltedMac/Info.plist"
failures=0

fail() {
    printf 'source-stamp.fail %s\n' "$*" >&2
    failures=$((failures + 1))
}

pass() { printf 'source-stamp.ok %s\n' "$*" >&2; }

[[ -f "$library" ]] || { fail "missing $library"; exit 1; }
# shellcheck source=../scripts/lib/source-stamp.sh
source "$library"

tmp_root="$(mktemp -d "${TMPDIR:?}/wilted-source-stamp.XXXXXX")"
cleanup() { [[ -d "$tmp_root" ]] && rm -rf "$tmp_root"; }
trap cleanup EXIT

# Prevent sandbox permission denials on user-level git configuration.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export XDG_CONFIG_HOME="$tmp_root"

throwaway="$tmp_root/repo"
git init -q "$throwaway"
printf 'initial\n' >"$throwaway/tracked.txt"
git -C "$throwaway" add tracked.txt
git -C "$throwaway" -c user.name='Stamp Tester' -c user.email='stamp-tester@example.com' commit -q -m 'initial commit'

# 1. Clean tree prints 10 hex characters.
clean_stamp="$(wilted_source_stamp "$throwaway")"
if [[ "$clean_stamp" =~ ^[0-9a-f]{10}$ ]]; then
    pass 'clean tree prints 10 hex chars'
else
    fail "clean tree expected 10 hex chars, got '$clean_stamp'"
fi

# 2. Modified tracked file prints <10 hex>-dirty.
printf 'modified\n' >>"$throwaway/tracked.txt"
modified_stamp="$(wilted_source_stamp "$throwaway")"
if [[ "$modified_stamp" == "${clean_stamp}-dirty" ]]; then
    pass 'modified tracked file prints <10 hex>-dirty'
else
    fail "modified tracked file expected '${clean_stamp}-dirty', got '$modified_stamp'"
fi

# 3. Untracked-only change stays clean.
git -C "$throwaway" checkout -q -- tracked.txt
printf 'untracked\n' >"$throwaway/untracked.txt"
untracked_stamp="$(wilted_source_stamp "$throwaway")"
if [[ "$untracked_stamp" == "$clean_stamp" ]]; then
    pass 'untracked-only change stays clean'
else
    fail "untracked-only change expected '$clean_stamp', got '$untracked_stamp'"
fi

# 4. Non-repo directory prints unknown with exit 0.
non_repo="$tmp_root/non-repo"
mkdir -p "$non_repo"
non_repo_status=0
non_repo_stamp="$(wilted_source_stamp "$non_repo")" || non_repo_status=$?
if [[ $non_repo_status -eq 0 && "$non_repo_stamp" == 'unknown' ]]; then
    pass 'non-repo directory prints unknown with exit 0'
else
    fail "non-repo expected 'unknown' with exit 0, got status $non_repo_status and '$non_repo_stamp'"
fi

# 5. project.yml and WiltedMac/Info.plist both name WiltedSourceCommit.
if grep -Fq 'WiltedSourceCommit' "$project"; then
    pass 'project.yml names WiltedSourceCommit'
else
    fail 'project.yml does not name WiltedSourceCommit'
fi

if grep -Fq 'WiltedSourceCommit' "$info_plist"; then
    pass 'WiltedMac/Info.plist names WiltedSourceCommit'
else
    fail 'WiltedMac/Info.plist does not name WiltedSourceCommit'
fi

if (( failures > 0 )); then
    printf 'source-stamp.failed count=%s\n' "$failures" >&2
    exit 1
fi
printf 'source-stamp.passed\n' >&2
