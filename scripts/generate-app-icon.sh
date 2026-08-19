#!/usr/bin/env bash
# Compiles and runs the icon generator against the shipping brand geometry.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/wilted-icon.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

swiftc -O -o "$build_dir/icongen" \
  "$repo_root/scripts/generate-app-icon.swift" \
  "$repo_root/Shared/WiltedMark.swift" \
  "$repo_root/Shared/WiltedTheme.swift"
"$build_dir/icongen" "$repo_root"
