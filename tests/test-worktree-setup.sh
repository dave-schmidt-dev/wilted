#!/usr/bin/env bash
# Hermetic tests for scripts/worktree-setup.sh (`make worktree-setup`): a fake main
# checkout beside fake sibling projects, a linked worktree under .claude/worktrees,
# and a uv stub whose venv reports a chosen GPU lock location.
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-temp-state.sh"
fixture="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-worktree-setup.XXXXXX")"; wilted_temp_mark_owned "$fixture"
trap 'rm -rf "$fixture"' EXIT
fixture="$(cd -P "$fixture" && pwd)"
fail() { printf 'assertion failed: %s\n' "$1" >&2; exit 1; }

projects="$fixture/projects"
main="$projects/wilted"
worktree="$main/.claude/worktrees/wt"
mkdir -p "$projects/speech-stack" "$projects/apple_developer" "$main/scripts" "$main/Producer/Runtime"
cp "$repo_root/scripts/worktree-setup.sh" "$main/scripts/worktree-setup.sh"
touch "$main/Producer/Runtime/pyproject.toml"
git -C "$main" init -q
git -C "$main" add -A
git -C "$main" -c user.name=test -c user.email=test@example.invalid commit --no-verify -qm fixture
git -C "$main" worktree add -q "$worktree" >/dev/null 2>&1

# The stub records its arguments and builds a venv whose python prints FAKE_STATE_DIR.
uv_stub="$fixture/uv"
cat >"$uv_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$UV_LOG"
printf 'env=%s\n' "${UV_PROJECT_ENVIRONMENT:-unset}" >>"$UV_LOG"
project="${*: -1}"
venv="${UV_PROJECT_ENVIRONMENT:-$project/.venv}"
mkdir -p "$venv/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$FAKE_STATE_DIR"\n' >"$venv/bin/python"
chmod +x "$venv/bin/python"
STUB
chmod +x "$uv_stub"
export WILTED_UV="$uv_stub" UV_LOG="$fixture/uv.log" FAKE_STATE_DIR="$projects/speech-stack/.state"
export UV_PROJECT_ENVIRONMENT="$fixture/elsewhere-venv"

run_setup() {
  local checkout="$1" log="$2"
  bash "$checkout/scripts/worktree-setup.sh" >"$log" 2>&1
}

printf '%s\n' 'test.stage=fresh-worktree' >&2
run_setup "$worktree" "$fixture/fresh.log" || { cat "$fixture/fresh.log" >&2; fail 'fresh worktree setup failed'; }
for name in speech-stack apple_developer; do
  [[ -L "$main/.claude/worktrees/$name" ]] || fail "$name was not linked beside the worktree"
  [[ "$(readlink "$main/.claude/worktrees/$name")" == "$projects/$name" ]] || fail "$name links somewhere else"
done
grep -qx "sync --locked --project $worktree/Producer/Runtime" "$UV_LOG" || fail "uv was not asked for a locked sync: $(cat "$UV_LOG")"
[[ -x "$worktree/Producer/Runtime/.venv/bin/python" ]] || fail 'fresh worktree did not get its own venv interpreter'
[[ ! -e "$fixture/elsewhere-venv" ]] || fail 'setup synced the inherited UV_PROJECT_ENVIRONMENT'
grep -qx "env=$worktree/Producer/Runtime/.venv" "$UV_LOG" || fail "uv did not see the checkout venv: $(cat "$UV_LOG")"
grep -q 'ready:' "$fixture/fresh.log" || fail 'fresh setup did not report ready'

printf '%s\n' 'test.stage=idempotent-rerun' >&2
run_setup "$worktree" "$fixture/rerun.log" || { cat "$fixture/rerun.log" >&2; fail 'rerun failed'; }
grep -q 'already resolves' "$fixture/rerun.log" || fail 'rerun did not reuse the existing links'
[[ "$(grep -c 'sync --locked' "$UV_LOG")" -eq 2 ]] || fail 'rerun did not resync the venv'

printf '%s\n' 'test.stage=main-checkout' >&2
run_setup "$main" "$fixture/main.log" || { cat "$fixture/main.log" >&2; fail 'main checkout setup failed'; }
grep -q 'main checkout, resolves in place' "$fixture/main.log" || fail 'main checkout was not recognised'
[[ ! -e "$fixture/speech-stack" && ! -e "$fixture/apple_developer" ]] || fail 'main checkout setup linked above the projects root'

printf '%s\n' 'test.stage=split-gpu-lock' >&2
if FAKE_STATE_DIR="$fixture/elsewhere/.state" run_setup "$worktree" "$fixture/split.log"; then
  fail 'a venv resolving a private GPU lock was accepted'
fi
grep -q "not the shared $projects/speech-stack/.state" "$fixture/split.log" || fail "split lock not reported: $(cat "$fixture/split.log")"

printf '%s\n' 'test.stage=conflicting-sibling' >&2
mkdir "$fixture/other-speech-stack"
rm "$main/.claude/worktrees/speech-stack"
ln -s "$fixture/other-speech-stack" "$main/.claude/worktrees/speech-stack"
syncs_before="$(grep -c 'sync --locked' "$UV_LOG")"
if run_setup "$worktree" "$fixture/conflict.log"; then fail 'a sibling link to another checkout was accepted'; fi
grep -q 'move it aside and rerun' "$fixture/conflict.log" || fail "conflict not reported: $(cat "$fixture/conflict.log")"
[[ "$(readlink "$main/.claude/worktrees/speech-stack")" == "$fixture/other-speech-stack" ]] || fail 'the conflicting link was replaced'
[[ "$(grep -c 'sync --locked' "$UV_LOG")" -eq "$syncs_before" ]] || fail 'setup synced despite the conflict'

printf '%s\n' 'test.stage=missing-sibling-project' >&2
rm "$main/.claude/worktrees/speech-stack"
mv "$projects/apple_developer" "$fixture/apple_developer.away"
if run_setup "$worktree" "$fixture/missing.log"; then fail 'a missing sibling project was accepted'; fi
grep -q "missing sibling project $projects/apple_developer" "$fixture/missing.log" || fail "missing sibling not reported: $(cat "$fixture/missing.log")"

printf '%s\n' 'worktree setup tests: OK'
