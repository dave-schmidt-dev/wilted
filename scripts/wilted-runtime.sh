#!/bin/bash
# wilted-runtime.sh — least-privilege launcher for Wilted's credentialed feeds.

set -euo pipefail

readonly KEYCHAIN_SERVICE="bws-wilted-runtime"
readonly KEYCHAIN_ACCOUNT="access-token"
readonly BWS_BINARY="/usr/local/bin/bws"
readonly SECURITY_BINARY="/usr/bin/security"
readonly UV_BINARY="/Users/dave/.local/bin/uv"
readonly RUNTIME_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
readonly FEED_SECRETS=(
    WILTED_FEED_NPR_PLUS_HOW_TO_DO_EVERYTHING
    WILTED_FEED_NPR_PLUS_POP_CULTURE_HAPPY_HOUR
    WILTED_FEED_NPR_PLUS_WAIT_WAIT
)
fail() {
    echo "wilted-runtime: $*" >&2
    exit 1
}

resolve_project_root() {
    local runtime_script="${BASH_SOURCE[0]}"
    if [[ -L "$runtime_script" ]]; then
        runtime_script="$(readlink "$runtime_script")"
    fi
    cd "$(dirname "$runtime_script")/.." && pwd
}

run_clean_wilted() {
    local project_root="$1"
    shift

    local secret_name
    for secret_name in "${FEED_SECRETS[@]}"; do
        [[ -n "${!secret_name:-}" ]] || fail "required feed secret ${secret_name} is unavailable"
    done
    [[ -z "${BWS_ACCESS_TOKEN:-}" ]] || fail "BWS access token unexpectedly reached runtime launcher"
    [[ -z "${BWS_PROJECT_ID:-}" ]] || fail "BWS project identifier unexpectedly reached runtime launcher"

    # bws run supplies only the assigned feed values to this inner shell. The
    # actual Wilted process is re-execed under an allowlisted environment.
    #
    # --no-sync --frozen: use the already-provisioned venv (${UV_PROJECT_ENVIRONMENT})
    # and existing lockfile as-is. A background tick must NEVER resolve/sync
    # dependencies on the hot path — under launchd's clean env that sync stage can
    # stall on the network with no timeout and no python ever spawning. Provisioning
    # happens during dev/`make`, not per-invocation.
    #
    # TERM_PROGRAM/LC_TERMINAL are terminal identification strings, not secrets, and
    # mouse input does not work without them (BUG-7). Textual gates a known-buggy
    # iTerm2 code path on `IS_ITERM`, which it derives from exactly these two
    # variables. Strip them and Textual cannot tell it is on iTerm2, so it enables
    # in-band window resize and with it SGR-pixel mouse mode (`\e[?1016h`). iTerm2
    # then reports mouse position in PIXELS while Textual reads them as cells, so
    # every click lands far outside the grid: mouse totally dead, keyboard fine.
    # Textual's own source comments the guard "iTerm is buggy in one or more of the
    # protocols required here" — env -i was defeating that guard.
    exec /usr/bin/env -i \
        HOME="${HOME:-}" \
        PATH="$RUNTIME_PATH" \
        TMPDIR="${TMPDIR:-/tmp}" \
        UV_CACHE_DIR="${UV_CACHE_DIR:-${project_root}/.uv-cache}" \
        UV_PROJECT_ENVIRONMENT="${UV_PROJECT_ENVIRONMENT:-${HOME:-}/.venvs/wilted}" \
        WILTED_PROJECT_ROOT="$project_root" \
        TERM="${TERM:-}" \
        COLORTERM="${COLORTERM:-}" \
        TERM_PROGRAM="${TERM_PROGRAM:-}" \
        LC_TERMINAL="${LC_TERMINAL:-}" \
        LANG="${LANG:-}" \
        LC_ALL="${LC_ALL:-}" \
        LC_CTYPE="${LC_CTYPE:-}" \
        WILTED_DEBUG="${WILTED_DEBUG:-}" \
        WILTED_WEATHER_TEST_TRIGGER="${WILTED_WEATHER_TEST_TRIGGER:-}" \
        NERD_FONTS="${NERD_FONTS:-}" \
        WILTED_TRANSCRIBE_TIMEOUT_S="${WILTED_TRANSCRIBE_TIMEOUT_S:-}" \
        WILTED_TRANSCRIBE_MEM_LIMIT="${WILTED_TRANSCRIBE_MEM_LIMIT:-}" \
        WILTED_FEED_NPR_PLUS_HOW_TO_DO_EVERYTHING="$WILTED_FEED_NPR_PLUS_HOW_TO_DO_EVERYTHING" \
        WILTED_FEED_NPR_PLUS_POP_CULTURE_HAPPY_HOUR="$WILTED_FEED_NPR_PLUS_POP_CULTURE_HAPPY_HOUR" \
        WILTED_FEED_NPR_PLUS_WAIT_WAIT="$WILTED_FEED_NPR_PLUS_WAIT_WAIT" \
        "$UV_BINARY" run --no-sync --frozen --project "$project_root" python -m wilted.cli "$@"
}

main() {
    local project_root
    project_root="$(resolve_project_root)"

    if [[ "${1:-}" == "--runtime-inner" ]]; then
        shift
        run_clean_wilted "$project_root" "$@"
    fi

    [[ -x "$SECURITY_BINARY" ]] || fail "macOS security tool is unavailable"
    [[ -x "$BWS_BINARY" ]] || fail "BWS binary is unavailable"

    local access_token
    if ! access_token="$("$SECURITY_BINARY" find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" -w)"; then
        fail "runtime Keychain access token is unavailable"
    fi
    [[ -n "$access_token" ]] || fail "runtime Keychain access token is unavailable"

    # The assignment applies solely to the outer bws process. bws then invokes
    # this fixed script with a fixed subcommand; user input can only become
    # Wilted CLI arguments, never a command selected by the caller.
    BWS_ACCESS_TOKEN="$access_token" exec "$BWS_BINARY" run -- "$0" --runtime-inner "$@"
}

main "$@"
