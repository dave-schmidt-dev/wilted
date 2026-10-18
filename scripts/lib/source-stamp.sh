#!/usr/bin/env bash
# Resolves the git source commit for build and package stamping.
#
# MARKETING_VERSION and CURRENT_PROJECT_VERSION rarely change, so the build
# number alone does not move per fix and cannot tell whether a given fix was
# present in a build. Stamping with the short git revision (and -dirty when
# tracked files differ) identifies the exact source tree.

wilted_source_stamp() {
  local repo_root="${1:-.}"
  local commit="" dirty=""
  if ! commit="$(git -C "$repo_root" rev-parse --short=10 HEAD 2>/dev/null)" || [[ -z "$commit" ]]; then
    printf 'unknown\n'
    return 0
  fi
  dirty="$(git -C "$repo_root" status --porcelain --untracked-files=no 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    commit="${commit}-dirty"
  fi
  printf '%s\n' "$commit"
  return 0
}
