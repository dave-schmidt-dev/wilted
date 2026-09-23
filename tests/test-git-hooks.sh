#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wilted-git-hooks.XXXXXX")"
tmp_dir="$(cd "$tmp_dir" && pwd -P)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"
fake_make="$fake_bin/make"
make_log="$tmp_dir/make.log"

cat >"$fake_make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${WILTED_FAKE_MAKE_LOG:?}"
exit "${WILTED_FAKE_MAKE_STATUS:-0}"
EOF
chmod +x "$fake_make"

assert_contains() {
  local needle="$1" file="$2"
  grep -Fqx -- "$needle" "$file" || {
    printf '%s\n' "assertion failed: missing exact line: $needle" >&2
    cat "$file" >&2 || true
    exit 1
  }
}

common_config_for() {
  local checkout="$1" common_dir
  common_dir="$(git -C "$checkout" rev-parse --git-common-dir)"
  if [[ "$common_dir" != /* ]]; then
    common_dir="$checkout/$common_dir"
  fi
  common_dir="$(cd "$common_dir" && pwd -P)"
  printf '%s/config\n' "$common_dir"
}

run_hook() {
  local hook="$1" expected_target="$2" expected_status="$3"
  : >"$make_log"
  set +e
  PATH="$fake_bin:$PATH" \
    WILTED_FAKE_MAKE_LOG="$make_log" \
    WILTED_FAKE_MAKE_STATUS="$expected_status" \
    bash "$repo_root/.githooks/$hook"
  local status=$?
  set -e
  [[ "$status" -eq "$expected_status" ]] || {
    printf '%s\n' "assertion failed: $hook returned $status, expected $expected_status" >&2
    exit 1
  }
  assert_contains "-C $repo_root $expected_target" "$make_log"
}

copy_checkout_files() {
  local checkout="$1"
  mkdir -p "$checkout/.githooks" "$checkout/scripts"
  cp "$repo_root/.githooks/pre-commit" "$checkout/.githooks/pre-commit"
  cp "$repo_root/.githooks/pre-push" "$checkout/.githooks/pre-push"
  cp "$repo_root/scripts/install-git-hooks.sh" "$checkout/scripts/install-git-hooks.sh"
  cp "$repo_root/scripts/native-ui-receipt.py" "$checkout/scripts/native-ui-receipt.py"
  cp "$repo_root/scripts/mac-ui-surface.paths" "$checkout/scripts/mac-ui-surface.paths"
  chmod +x "$checkout/.githooks/pre-commit" "$checkout/.githooks/pre-push" \
    "$checkout/scripts/install-git-hooks.sh"
}

init_checkout() {
  local checkout="$1"
  mkdir -p "$checkout"
  copy_checkout_files "$checkout"
  git -C "$checkout" init -q
  git -C "$checkout" config user.name 'Wilted hook test'
  git -C "$checkout" config user.email 'wilted-hooks@example.invalid'
  git -C "$checkout" add .
  git -C "$checkout" commit --no-verify -q -m 'initial hook fixture'
  git -C "$checkout" branch -M main
}

assert_install_output_and_config() {
  local checkout="$1" install_output="$2"
  local expected_path="$checkout/.githooks"
  bash "$checkout/scripts/install-git-hooks.sh" >"$install_output"
  assert_contains "git-hooks.status hooks-path=$expected_path hooks=2 executable=true worktree=true" \
    "$install_output"
  [[ "$(git -C "$checkout" config --worktree --get core.hooksPath)" == "$expected_path" ]] || exit 1
  [[ "$(git -C "$checkout" rev-parse --git-path hooks)" == "$expected_path" ]] || exit 1
  [[ -x "$checkout/.githooks/pre-commit" && -x "$checkout/.githooks/pre-push" ]] || exit 1
}

[[ -x "$repo_root/.githooks/pre-commit" ]] || exit 1
[[ -x "$repo_root/.githooks/pre-push" ]] || exit 1
run_hook pre-commit check-fast 0
run_hook pre-commit check-fast 23
run_hook pre-push validate 0
run_hook pre-push validate 29

live_common_config="$(common_config_for "$repo_root")"
live_common_hooks_path="$(git config --file "$live_common_config" --get-all core.hooksPath 2>/dev/null || true)"
live_worktree_hooks_path="$(git -C "$repo_root" config --worktree --get core.hooksPath 2>/dev/null || true)"
live_worktree_extension="$(git config --file "$live_common_config" --get extensions.worktreeConfig 2>/dev/null || true)"

temp_repo="$tmp_dir/repo"
init_checkout "$temp_repo"

install_output="$tmp_dir/install.log"
assert_install_output_and_config "$temp_repo" "$install_output"
bash "$temp_repo/scripts/install-git-hooks.sh" >"$install_output"
assert_contains "git-hooks.status hooks-path=$temp_repo/.githooks hooks=2 executable=true worktree=true" "$install_output"

linked_checkout="$tmp_dir/linked"
git -C "$temp_repo" worktree add -q "$linked_checkout" -b linked
assert_install_output_and_config "$linked_checkout" "$install_output"
[[ "$(git -C "$temp_repo" config --worktree --get core.hooksPath)" == "$temp_repo/.githooks" ]] || exit 1
[[ "$(git -C "$linked_checkout" config --worktree --get core.hooksPath)" == "$linked_checkout/.githooks" ]] || exit 1
[[ "$(git -C "$temp_repo" rev-parse --git-path hooks)" != "$(git -C "$linked_checkout" rev-parse --git-path hooks)" ]] || exit 1

conflict_repo="$tmp_dir/conflict"
init_checkout "$conflict_repo"
conflict_config="$(common_config_for "$conflict_repo")"
git config --file "$conflict_config" core.hooksPath "$tmp_dir/conflicting-hooks"
set +e
bash "$conflict_repo/scripts/install-git-hooks.sh" >"$install_output" 2>&1
conflict_status=$?
set -e
[[ "$conflict_status" -ne 0 ]] || exit 1
[[ "$(git config --file "$conflict_config" --get core.hooksPath)" == "$tmp_dir/conflicting-hooks" ]] || exit 1
[[ "$(git config --file "$conflict_config" --get extensions.worktreeConfig 2>/dev/null || true)" != 'true' ]] || exit 1

legacy_single_repo="$tmp_dir/legacy-single"
init_checkout "$legacy_single_repo"
legacy_single_config="$(common_config_for "$legacy_single_repo")"
git config --file "$legacy_single_config" core.hooksPath .githooks
assert_install_output_and_config "$legacy_single_repo" "$install_output"
[[ -z "$(git config --file "$legacy_single_config" --get-all core.hooksPath 2>/dev/null || true)" ]] || exit 1

legacy_linked_repo="$tmp_dir/legacy-linked"
init_checkout "$legacy_linked_repo"
legacy_linked_checkout="$tmp_dir/legacy-linked-sibling"
git -C "$legacy_linked_repo" worktree add -q "$legacy_linked_checkout" -b legacy-linked
legacy_linked_config="$(common_config_for "$legacy_linked_repo")"
git config --file "$legacy_linked_config" core.hooksPath .githooks
set +e
bash "$legacy_linked_repo/scripts/install-git-hooks.sh" >"$install_output" 2>&1
legacy_linked_status=$?
set -e
[[ "$legacy_linked_status" -ne 0 ]] || exit 1
assert_contains 'git-hooks.error legacy shared .githooks cannot be migrated while linked worktrees exist; run the installer in each worktree after removing the shared setting deliberately' "$install_output"
[[ "$(git config --file "$legacy_linked_config" --get core.hooksPath)" == '.githooks' ]] || exit 1
[[ "$(git config --file "$legacy_linked_config" --get extensions.worktreeConfig 2>/dev/null || true)" != 'true' ]] || exit 1
[[ -z "$(git -C "$legacy_linked_repo" config --worktree --get core.hooksPath 2>/dev/null || true)" ]] || exit 1

# Exercise Git's own hook dispatch for both commit and push, including failure
# propagation. The fake make is the only command the hooks run.
git -C "$temp_repo" config --worktree core.hooksPath "$temp_repo/.githooks"
printf '%s\n' payload >>"$temp_repo/payload.txt"
git -C "$temp_repo" add payload.txt
set +e
PATH="$fake_bin:$PATH" WILTED_FAKE_MAKE_LOG="$make_log" WILTED_FAKE_MAKE_STATUS=23 \
  git -C "$temp_repo" commit -m 'blocked commit' >"$tmp_dir/commit-fail.log" 2>&1
commit_status=$?
set -e
[[ "$commit_status" -ne 0 ]] || exit 1
PATH="$fake_bin:$PATH" WILTED_FAKE_MAKE_LOG="$make_log" WILTED_FAKE_MAKE_STATUS=0 \
  git -C "$temp_repo" commit -m 'green commit' -q

remote="$tmp_dir/remote.git"
git init --bare -q "$remote"
git -C "$temp_repo" remote add origin "$remote"
set +e
PATH="$fake_bin:$PATH" WILTED_FAKE_MAKE_LOG="$make_log" WILTED_FAKE_MAKE_STATUS=29 \
  git -C "$temp_repo" push -u origin main >"$tmp_dir/push-fail.log" 2>&1
push_status=$?
set -e
[[ "$push_status" -ne 0 ]] || exit 1
PATH="$fake_bin:$PATH" WILTED_FAKE_MAKE_LOG="$make_log" WILTED_FAKE_MAKE_STATUS=0 \
  git -C "$temp_repo" push -u origin main -q

after_live_common_hooks_path="$(git config --file "$live_common_config" --get-all core.hooksPath 2>/dev/null || true)"
after_live_worktree_hooks_path="$(git -C "$repo_root" config --worktree --get core.hooksPath 2>/dev/null || true)"
after_live_worktree_extension="$(git config --file "$live_common_config" --get extensions.worktreeConfig 2>/dev/null || true)"
[[ "$after_live_common_hooks_path" == "$live_common_hooks_path" ]] || {
  printf '%s\n' 'assertion failed: test changed live common hook configuration' >&2
  exit 1
}
[[ "$after_live_worktree_hooks_path" == "$live_worktree_hooks_path" ]] || {
  printf '%s\n' 'assertion failed: test changed live worktree hook configuration' >&2
  exit 1
}
[[ "$after_live_worktree_extension" == "$live_worktree_extension" ]] || {
  printf '%s\n' 'assertion failed: test changed live worktree config extension' >&2
  exit 1
}

printf '%s\n' 'git hooks test passed'
