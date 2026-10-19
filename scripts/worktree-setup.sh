#!/usr/bin/env bash
# Provisions a checkout for the gates (`make worktree-setup`). Idempotent.
#
# The main checkout sits beside its sibling projects, and two gate paths resolve
# through a sibling relative to the checkout: Producer/Runtime's lock pins the
# speech stack as the editable `../../../speech-stack`, and the release wrappers
# import `<checkout>/../apple_developer`. A linked worktree (.claude/worktrees/*,
# a Codex worktree) sits somewhere else, so this links each sibling beside it to
# the main checkout's sibling. The lock keeps its relative path, which the public
# repository needs, and the venv resolves the speech stack to its canonical
# source, so every checkout shares one GPU lock. It then syncs the runtime venv
# from the lock and proves where that lock resolves.
#
# An existing sibling entry is used only when it already resolves to the main
# checkout's sibling; anything else is reported, never replaced.
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
uv_bin="${WILTED_UV:-uv}"
siblings=(speech-stack apple_developer)

say() { printf 'worktree-setup: %s\n' "$*" >&2; }
fail() { say "error: $*"; exit 1; }

common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)" \
  || fail "not a git checkout: $repo_root"
main_root="$(cd -P "$common_dir/.." && pwd)" || fail "unreadable main checkout for $common_dir"
projects_root="$(cd -P "$main_root/.." && pwd)" || fail "unreadable projects root above $main_root"
checkout_parent="$(cd -P "$repo_root/.." && pwd)" || fail "unreadable parent of $repo_root"

for name in "${siblings[@]}"; do
  target="$projects_root/$name"
  [[ -d "$target" ]] || fail "missing sibling project $target (clone it beside the main checkout)"
  if [[ "$checkout_parent" == "$projects_root" ]]; then
    say "sibling $name: main checkout, resolves in place"
    continue
  fi
  link="$checkout_parent/$name"
  if [[ -e "$link" || -L "$link" ]]; then
    resolved="$(cd -P "$link" 2>/dev/null && pwd)" || fail "$link exists but does not resolve; move it aside and rerun"
    [[ "$resolved" == "$(cd -P "$target" && pwd)" ]] \
      || fail "$link resolves to $resolved, not $target; move it aside and rerun"
    say "sibling $name: $link already resolves to $target"
  else
    ln -s "$target" "$link"
    say "sibling $name: linked $link -> $target"
  fi
done

say "syncing Producer/Runtime/.venv from uv.lock (uv reports progress below)"
"$uv_bin" sync --locked --project "$repo_root/Producer/Runtime"

expected_state="$projects_root/speech-stack/.state"
say "checking that the speech stack's GPU lock resolves to $expected_state"
state_dir="$(env -u SPEECH_STACK_STATE_DIR "$repo_root/Producer/Runtime/.venv/bin/python" \
  -c 'from speech_stack import isolated; print(isolated.state_dir())')" \
  || fail 'the runtime venv cannot import speech_stack'
[[ "$state_dir" == "$expected_state" ]] \
  || fail "GPU lock resolves to $state_dir, not the shared $expected_state"
say "ready: $repo_root"
