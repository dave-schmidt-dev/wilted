#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
hooks_dir="$repo_root/.githooks"

repo_top="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" || {
  printf '%s\n' 'git-hooks.error repository is not a Git checkout' >&2
  exit 1
}
if [[ "$repo_top" != "$repo_root" ]]; then
  printf '%s\n' "git-hooks.error script checkout mismatch: $repo_top" >&2
  exit 1
fi

[[ -d "$hooks_dir" ]] || {
  printf '%s\n' "git-hooks.error missing hooks directory: $hooks_dir" >&2
  exit 1
}

hooks=(pre-commit pre-push)
for hook in "${hooks[@]}"; do
  hook_path="$hooks_dir/$hook"
  [[ -f "$hook_path" && -x "$hook_path" ]] || {
    printf '%s\n' "git-hooks.error hook is missing or not executable: $hook" >&2
    exit 1
  }
done

git_common_dir="$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null)" || {
  printf '%s\n' 'git-hooks.error unable to resolve the common Git directory' >&2
  exit 1
}
if [[ "$git_common_dir" != /* ]]; then
  git_common_dir="$repo_root/$git_common_dir"
fi
git_common_dir="$(cd "$git_common_dir" && pwd -P)"
common_config="$git_common_dir/config"

common_hooks_paths=()
if [[ -f "$common_config" ]]; then
  common_hooks_paths_raw="$(git config --file "$common_config" --get-all core.hooksPath 2>/dev/null || true)"
  if [[ -n "$common_hooks_paths_raw" ]]; then
    while IFS= read -r common_hooks_path; do
      common_hooks_paths+=("$common_hooks_path")
    done <<<"$common_hooks_paths_raw"
  fi
fi
legacy_common_path=false
if ((${#common_hooks_paths[@]} > 0)); then
  for common_hooks_path in "${common_hooks_paths[@]}"; do
    # `.githooks` is the path written by the previous installer. Migrate that
    # known value out of the shared config; refuse every other path rather than
    # silently taking ownership of a user's common hook configuration.
    [[ "$common_hooks_path" == '.githooks' ]] || {
      printf '%s\n' "git-hooks.error conflicting common core.hooksPath: $common_hooks_path" >&2
      exit 1
    }
  done
  worktree_count="$(git -C "$repo_root" worktree list --porcelain | awk '$1 == "worktree" { count += 1 } END { print count + 0 }')"
  ((worktree_count == 1)) || {
    printf '%s\n' \
      'git-hooks.error legacy shared .githooks cannot be migrated while linked worktrees exist; run the installer in each worktree after removing the shared setting deliberately' >&2
    exit 1
  }
  legacy_common_path=true
fi

# `--worktree` requires this extension and stores the path in the installing
# checkout's config.worktree, not in the shared config seen by sibling worktrees.
git -C "$repo_root" config --local extensions.worktreeConfig true
git -C "$repo_root" config --worktree core.hooksPath "$hooks_dir"
configured_path="$(git -C "$repo_root" config --worktree --get core.hooksPath 2>/dev/null || true)"
[[ "$configured_path" == "$hooks_dir" ]] || {
  printf '%s\n' "git-hooks.error core.hooksPath verification failed: $configured_path" >&2
  exit 1
}
if [[ "$legacy_common_path" == true ]]; then
  # Remove the shared legacy value only after the private replacement is
  # installed and verified, so a failed migration never leaves this checkout
  # without hooks.
  git config --file "$common_config" --unset-all core.hooksPath
fi

printf '%s\n' "git-hooks.status hooks-path=$configured_path hooks=${#hooks[@]} executable=true worktree=true"
