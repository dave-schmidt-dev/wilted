#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-runner.sh"
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  WILTED_TEST_RUNNER_TIMEOUT_SECONDS="${WILTED_TEST_RUNNER_TIMEOUT_SECONDS:-300}"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
node_runtime="${WILTED_PROTOTYPE_NODE:-/Users/dave/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node}"
modules="${WILTED_PROTOTYPE_MODULES:-/Users/dave/Documents/Projects/todojo/node_modules}"
cli="$modules/@playwright/test/cli.js"
if [[ ! -x "$node_runtime" || ! -f "$cli" ]]; then
  printf '%s\n' 'error: prototype requires bundled Node and @playwright/test 1.63.0; restore todojo/node_modules or set WILTED_PROTOTYPE_NODE and WILTED_PROTOTYPE_MODULES to a verified pinned runtime.' >&2
  exit 127
fi
scratch="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-core-prototype.XXXXXX")"
cleanup(){ wilted_stop_active_supervisor; rm -rf "$scratch"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export NODE_PATH="$modules"
export WILTED_PROTOTYPE_EVIDENCE="${WILTED_PROTOTYPE_EVIDENCE:-$repo_root/.logs/ship-2026-10-02/batch1-plan-20261003/prototype}"
mkdir -p "$WILTED_PROTOTYPE_EVIDENCE"
cat > "$scratch/playwright.config.cjs" <<CONFIG
module.exports={testDir:'$repo_root/docs/mockups',testMatch:'2026-10-03-core-reliability.test.cjs',timeout:20000,workers:2,fullyParallel:true,reporter:[['line'],['json',{outputFile:'$WILTED_PROTOTYPE_EVIDENCE/results.json'}]],outputDir:'$scratch/results',use:{headless:true}};
CONFIG
printf '%s\n' 'prototype.start runtime=@playwright/test pinned=1.63.0 surfaces=rail,side,full,phone,carplay widths=390,1280'
"$node_runtime" -e 'const p=require("@playwright/test/package.json");if(p.version!=="1.63.0"){console.error("error: expected @playwright/test 1.63.0, got "+p.version);process.exit(2)}'
"$node_runtime" -e 'const fs=require("fs");const s=fs.readFileSync(process.argv[1],"utf8");new Function(s.split("<script>")[1].split("</script>")[0]);console.log("prototype.syntax passed")' "$repo_root/docs/mockups/2026-10-03-core-reliability.html"
wilted_start_supervisor "$node_runtime" "$cli" test --config "$scratch/playwright.config.cjs" "$@"
wilted_wait_active_supervisor
printf '%s\n' 'prototype.complete'
