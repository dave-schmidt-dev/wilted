#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Proves the --library-sync mode of scripts/attended-cloudkit-run.sh parses its
# arguments, prints help, and fails fast, without building or touching a device.
#
# Hermetic on purpose: fake xcodebuild/xcrun/open/osascript/devicectl shims sit
# first on PATH and record any invocation; every case asserts the marker file
# stayed empty, so a regression that builds or installs fails the test.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/attended-cloudkit-run.sh"
failures=0

fail() { printf 'attended-library-sync.fail %s\n' "$*" >&2; failures=$((failures + 1)); }
pass() { printf 'attended-library-sync.ok %s\n' "$*" >&2; }

tmp_root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-attended-sync.XXXXXX")"
cleanup() { [[ -d "$tmp_root" ]] && rm -rf "$tmp_root"; }
trap cleanup EXIT

shims="$tmp_root/bin"
marker="$tmp_root/shim-calls"
mkdir -p "$shims"
: >"$marker"
for tool in xcodebuild xcrun open osascript devicectl xcodegen; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\nexit 0\n' "$tool" "$marker" >"$shims/$tool"
  chmod +x "$shims/$tool"
done

out="$tmp_root/out"
err="$tmp_root/err"

# run_script <expected-status> <label> <env...> -- <args...>
run_script() {
  local want="$1" label="$2"; shift 2
  local envs=()
  while [[ "${1:-}" != '--' ]]; do envs+=("$1"); shift; done
  shift
  local status=0
  env -u WILTED_DEVICE_ID PATH="$shims:$PATH" ${envs[@]+"${envs[@]}"} \
    bash "$script" "$@" >"$out" 2>"$err" </dev/null || status=$?
  if [[ "$want" == 'zero' && "$status" -ne 0 ]] || [[ "$want" == 'nonzero' && "$status" -eq 0 ]]; then
    fail "$label: exit status $status, expected $want"
    return 1
  fi
  if [[ -s "$marker" ]]; then
    fail "$label: build/device tools were invoked: $(cat "$marker")"
    return 1
  fi
  return 0
}

expect_in() { # <file> <needle> <label>
  grep -qF -- "$2" "$1" && pass "$3" || fail "$3: '$2' not found in $(basename "$1")"
}

# 1. Syntax.
bash -n "$script" && pass 'bash -n' || fail 'bash -n'

# 2. --help / -h / help print usage, exit 0, never build.
for flag in --help -h help; do
  if run_script zero "help $flag" -- "$flag"; then
    expect_in "$out" '--library-sync' "help $flag documents --library-sync"
    expect_in "$out" 'WILTED_DEVICE_ID' "help $flag documents WILTED_DEVICE_ID"
    expect_in "$out" 'WILTED_LIBRARY_SYNC=1' "help $flag documents the sync env"
    expect_in "$out" 'make install' "help $flag documents the restore command"
  fi
done

# 3. Unknown step is rejected and names the accepted modes.
if run_script nonzero 'unknown step' -- bogus; then
  expect_in "$err" 'unknown step: bogus' 'unknown step message'
  expect_in "$err" '--library-sync' 'unknown step lists --library-sync'
fi

# 4. --library-sync takes no further arguments.
if run_script nonzero 'extra argument' -- --library-sync extra; then
  expect_in "$err" 'takes no further arguments' 'extra argument rejected'
fi

# 5. --library-sync requires WILTED_DEVICE_ID before any build starts.
if run_script nonzero 'missing device' -- --library-sync; then
  expect_in "$err" 'WILTED_DEVICE_ID' 'missing device id named'
fi
if run_script nonzero 'empty device' WILTED_DEVICE_ID= -- --library-sync; then
  expect_in "$err" 'WILTED_DEVICE_ID' 'empty device id named'
fi

# 6. Static contract: one install path, explicit --env launch, no /Applications
#    writes, restore command printed.
grep -qF 'open -n --env WILTED_LIBRARY_SYNC=1 "$mac_app_path"' "$script" \
  && pass 'launches with explicit open --env' || fail 'explicit open --env launch missing'
[[ "$(grep -c 'devicectl device install' "$script")" == 1 ]] \
  && pass 'single device install path' || fail 'expected exactly one devicectl install'
grep -q 'cmd_install' <(sed -n '/^cmd_library_sync()/,/^}/p' "$script") \
  && pass 'library-sync reuses cmd_install' || fail 'library-sync does not reuse cmd_install'
if sed -n '/^cmd_library_sync()/,/^}/p' "$script" | grep -qE '(cp|ditto|rm|mv) .*/Applications|/Applications/'; then
  fail 'library-sync touches /Applications'
else
  pass 'library-sync leaves /Applications alone'
fi

if (( failures > 0 )); then
  printf 'attended-library-sync.fail %d failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'attended-library-sync.ok all checks passed\n' >&2
