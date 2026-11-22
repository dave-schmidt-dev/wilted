#!/usr/bin/env bash
set -euo pipefail
if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/canonical-path.sh"
fixture="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/canonical-path-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
python3 "$repo_root/scripts/check-no-global-tmp.py"
python3 - "$repo_root" <<'PY'
import importlib.util
import sys
from pathlib import Path
root = Path(sys.argv[1])
name = "no_global_tmp"
spec = importlib.util.spec_from_file_location(name, root / "scripts/check-no-global-tmp.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert module.violations(Path("sample.sh"), "echo /" + "tmp/old")
assert module.violations(Path("sample.md"), "See /private/" + "tmp/old")
assert not module.violations(Path("sample.sh"), "echo $TMPDIR/new")
assert module.selected(Path("scripts/build.sh"))
assert module.selected(Path("scripts/canonical.swift"))
assert module.selected(Path("docs/README.md"))
assert not module.selected(Path("tests/test_fixture.py"))
# Built in pieces so this file never trips the rule it tests.
MK = "mk" + "temp"
OWNED = '"${TMPDIR:?TMPDIR must be set}/wilted-a.XXXXXX"'
escapes = [
    f'x="$({MK} -t wilted-a.XXXXXX)"',
    f'x="$({MK} -d -t a.XXXXXX)"',
    f'x="$({MK} -dt a.XXXXXX)"',
    f'x="$({MK} -q -t a)"',
    f'x="$({MK})"',
    f'x="$({MK} -d)"',
    f'{MK} -d {OWNED}',
    f'x="$({MK} {OWNED})"; wilted_temp_mark_owned "$x"',
]
for line in escapes:
    assert module.violations(Path("tests/test-x.sh"), line), line
assert module.violations(Path("Makefile"), f"\t@d=$$({MK} -t a)")
anchored = [
    f'x="$({MK} -d {OWNED})"; wilted_temp_mark_owned "$x"',
    f'x="$({MK} "$work_dir/output.XXXXXX")"',
    f'x="$({MK} -d "${{root%/}}/sizing.XXXXXX")" || fail',
    f'# {MK} -t is the escape this rule rejects',
    f'{MK}_tail=1',
    f'echo "{MK}-only"',
]
for line in anchored:
    assert not module.violations(Path("tests/test-x.sh"), line), line
assert not module.violations(Path("CHANGELOG.md"), f"replaced {MK} -t with anchored templates")
assert not module.violations(Path("scripts/x.py"), f"{MK} -t a")
tmpdir_name = "TMP" + "DIR"
raw_tmp_path = "$" + "{" + tmpdir_name + ":?}/wilted-scratch.XXXXXX"
raw_shell_comparison = f'[[ "$candidate" == "{raw_tmp_path}" ]]'
assert module.violations(Path("tests/example.sh"), raw_shell_comparison), raw_shell_comparison
raw_assignment = f'work="$({MK} -d "${tmpdir_name}/fixture.XXXXXX")"'
for operator in ("=", "==", "!="):
    comparison = f'[[ "$work" {operator} "$expected" ]]'
    assert module.violations(Path("sample.sh"), raw_assignment + "\n" + comparison)
raw_swift_comparison = (
    f'let expected = ProcessInfo.processInfo.environment["{tmpdir_name}"]! + "wilted-scratch"; '
    "assert(path == expected)"
)
assert module.violations(Path("scripts/example.swift"), raw_swift_comparison), raw_swift_comparison
canonical_comparison = f'[[ "$(wilted_canonical_path "{raw_tmp_path}")" == "$expected" ]]'
assert not module.violations(Path("tests/example.sh"), canonical_comparison), canonical_comparison
print("no-global-tmp tests: OK")
PY

mkdir "$fixture/target"
ln -s "$fixture/target" "$fixture/alias"
target_path="$(wilted_canonical_path "$fixture/target/missing-leaf")"
alias_path="$(wilted_canonical_path "$fixture/alias/missing-leaf")"
[[ "$target_path" == "$alias_path" ]] || { echo 'canonical-path helper did not resolve a missing suffix through a symlink' >&2; exit 1; }
cat >"$fixture/canonical-path.swift" <<'SWIFT'
import Foundation

func canonical(_ helper: String, _ path: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", helper, path]
    let output = Pipe()
    process.standardOutput = output
    do {
        try process.run()
    } catch {
        fputs("canonical-path helper launch failed\n", stderr)
        exit(1)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(1) }
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .newlines)
}

let arguments = CommandLine.arguments
if canonical(arguments[1], arguments[2]) != canonical(arguments[1], arguments[3]) {
    fputs("Swift script received different canonical paths\n", stderr)
    exit(1)
}
SWIFT
swift "$fixture/canonical-path.swift" "$repo_root/scripts/lib/canonical_path.py" \
  "$fixture/alias/missing-leaf" "$fixture/target/missing-leaf"
printf '%s\n' 'canonical-path helper shell and Swift tests: OK'
