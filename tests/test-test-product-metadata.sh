#!/usr/bin/env bash
set -euo pipefail

if [[ "${WILTED_BOUNDED_ENTRY:-0}" != "1" ]]; then
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$repo_root/scripts/lib/test-runner.sh"
  wilted_reexec_bounded "${BASH_SOURCE[0]}" "$@"
fi

# Negative regression for the Mac UI leg's test-product metadata admission.
#
# The historical "resource fork, Finder information, or similar detritus not
# allowed" CodeSign failure came from com.apple.FinderInfo on generated product
# bundle roots. This test runs the gate's own metadata audit block (extracted
# verbatim from scripts/test-gate.sh, so drift fails here) against synthetic
# bundles in a temp root it owns, and proves:
#   - a product carrying FinderInfo or quarantine is refused, and FinderInfo
#     really does make codesign reject the bundle;
#   - an allowed build-system attribute is admitted, signs, and is preserved;
#   - the audit is read-only and scoped: a path outside the audited products
#     keeps its attribute names and bytes, and the gate and cache helper never
#     strip or rewrite extended attributes;
#   - the audited products resolve inside the checkout-owned Xcode cache.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/test-gate.sh"
build_with_cache="$repo_root/scripts/build-with-cache.py"

fail() {
  printf 'product-metadata.fail %s\n' "$*" >&2
  exit 1
}
pass() { printf 'product-metadata.ok %s\n' "$*" >&2; }

for tool in xattr codesign shasum python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is missing: $tool"
done

root="$(mktemp -d "${TMPDIR:?TMPDIR must be set}/wilted-product-metadata-test.XXXXXX")"
root="$(cd -P "$root" && pwd)"
cleanup() { [[ -n "$root" && -d "$root" ]] && rm -rf "$root"; root=""; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# 1. Extract the gate's metadata audit exactly as it runs inside leg_macos_ui_tests.
audit_block="$(awk '
  /if ! runner_metadata="\$\(xattr -lr "\$runner"/ { capture = 1 }
  capture { print }
  capture && /forbidden Mac UI quarantine\/FinderInfo metadata remains/ { seen = 1 }
  capture && seen && /^  fi$/ { exit }
' "$gate")"
[[ "$(printf '%s\n' "$audit_block" | wc -l | tr -d ' ')" == "8" ]] ||
  fail "gate metadata audit block changed shape; review this test with it: $audit_block"
for needle in 'xattr -lr "$runner"' 'xattr -lr "$host"' "com.apple.quarantine" "com.apple.FinderInfo" "return 1"; do
  [[ "$audit_block" == *"$needle"* ]] || fail "gate metadata audit lost: $needle"
done
eval "gate_metadata_audit() {
  local runner=\"\$1\" host=\"\$2\" runner_metadata host_metadata metadata_info
$audit_block
  return 0
}"
pass 'extracted the gate metadata audit block'

# 2. The gate and the cache helper only read metadata; neither strips or rewrites it.
if grep -En 'xattr[[:space:]]+(-[a-z]*[cdw][a-z]*|.*[[:space:]]-[cdw])' "$gate" "$build_with_cache"; then
  fail 'gate or cache helper mutates extended attributes'
fi
if grep -Eq 'removexattr|setxattr' "$build_with_cache"; then
  fail 'cache helper mutates extended attributes'
fi
pass 'gate and cache helper never strip or rewrite extended attributes'

# 3. The audited products are the checkout-owned Xcode cache products.
mac_ui_block="$(sed -n '/^leg_macos_ui_tests()/,/^}$/p' "$gate")"
for needle in 'label_data="$(build_cache_path xcode "$cache_key")"' \
  'runner="$label_data/Build/Products/Debug/WiltedMacUITests-Runner.app"' \
  'host="$label_data/Build/Products/Debug/WiltedMac.app"' \
  'find "$label_data/Build/Products" -type d -name '"'"'WiltedMacUITests-Runner.app'"'"'' \
  'find "$label_data/Build/Products" -type d -name '"'"'WiltedMac.app'"'"''; do
  [[ "$mac_ui_block" == *"$needle"* ]] || fail "Mac UI products are no longer scoped to the cache: $needle"
done
cache_root="$(python3 - "$build_with_cache" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("build_with_cache", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
cache, _lock = module.cache_paths(module.checkout_root(sys.argv[1]), "xcode", "native-macos-ui-tests")
print(cache)
PY
)"
[[ "$cache_root" == "$repo_root/.build/xcode" ]] || fail "Mac UI cache resolves outside the checkout: $cache_root"
pass 'Mac UI products resolve inside the checkout-owned .build/xcode cache'

# 4. Synthetic owned products.
make_bundle() {
  local bundle="$1" name="$2"
  mkdir -p "$bundle/Contents/MacOS"
  cp /usr/bin/true "$bundle/Contents/MacOS/$name"
  xattr -c "$bundle/Contents/MacOS/$name"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $name" \
    -c "Add :CFBundleIdentifier string test.wilted.metadata.$name" \
    -c 'Add :CFBundlePackageType string APPL' "$bundle/Contents/Info.plist" >/dev/null
  codesign --force --sign - "$bundle" >/dev/null 2>&1 || fail "could not ad-hoc sign fixture $name"
}
attribute_names() { xattr -r "$1" 2>/dev/null | awk -F': ' '{print $NF}' | sort; }
tree_digest() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256); }

products="$root/cache/Build/Products/Debug"
runner="$products/WiltedMacUITests-Runner.app"
host="$products/WiltedMac.app"
make_bundle "$runner" Runner
make_bundle "$host" Host
finder_info=0000000000000000040000000000000000000000000000000000000000000000

# Allowed metadata: admitted, signable, preserved.
xattr -w com.apple.xcode.CreatedByBuildSystem true "$runner"
allowed_before="$(attribute_names "$runner")"
gate_metadata_audit "$runner" "$host" 2>"$root/allowed.err" || fail "allowed attribute was refused: $(cat "$root/allowed.err")"
codesign --force --sign - "$runner" >/dev/null 2>&1 || fail 'allowed attribute broke signing'
codesign --verify --strict "$runner" || fail 'allowed attribute broke verification'
[[ "$(attribute_names "$runner")" == "$allowed_before" ]] || fail 'allowed attribute was not preserved'
pass 'allowed build-system attribute is admitted, signs, and is preserved'

# Non-owned path outside the audited products: never touched, never consulted.
foreign="$root/foreign/Unowned.app"
make_bundle "$foreign" Unowned
xattr -wx com.apple.FinderInfo "$finder_info" "$foreign"
foreign_names_before="$(attribute_names "$foreign")"
foreign_digest_before="$(tree_digest "$foreign")"
gate_metadata_audit "$runner" "$host" 2>"$root/foreign.err" ||
  fail "audit consulted a path outside the products: $(cat "$root/foreign.err")"

# Prohibited FinderInfo on an owned product: codesign rejects it and the audit refuses it.
xattr -wx com.apple.FinderInfo "$finder_info" "$host"
if codesign --force --sign - "$host" >"$root/finder-sign.log" 2>&1; then
  fail 'codesign accepted a bundle carrying FinderInfo; the regression premise changed'
fi
grep -q 'detritus not allowed' "$root/finder-sign.log" || fail "unexpected codesign failure: $(cat "$root/finder-sign.log")"
if gate_metadata_audit "$runner" "$host" 2>"$root/finder.err"; then
  fail 'audit admitted a product carrying com.apple.FinderInfo'
fi
grep -q 'forbidden Mac UI quarantine/FinderInfo metadata remains' "$root/finder.err" ||
  fail "FinderInfo refusal lost its diagnostic: $(cat "$root/finder.err")"
attribute_names "$host" | grep -qx com.apple.FinderInfo || fail 'audit mutated the refused product'
pass 'owned product with FinderInfo is refused by codesign and the gate audit, and left for diagnosis'
xattr -d com.apple.FinderInfo "$host"

# Prohibited quarantine on an owned product: refused.
xattr -w com.apple.quarantine '0081;00000000;wilted-test;' "$runner"
if gate_metadata_audit "$runner" "$host" 2>"$root/quarantine.err"; then
  fail 'audit admitted a product carrying com.apple.quarantine'
fi
grep -q 'forbidden Mac UI quarantine/FinderInfo metadata remains' "$root/quarantine.err" ||
  fail "quarantine refusal lost its diagnostic: $(cat "$root/quarantine.err")"
pass 'owned product with quarantine is refused by the gate audit'

[[ "$(attribute_names "$foreign")" == "$foreign_names_before" ]] || fail 'foreign path attribute names changed'
[[ "$(tree_digest "$foreign")" == "$foreign_digest_before" ]] || fail 'foreign path contents changed'
pass 'path outside the audited products is untouched'

cleanup
trap - EXIT INT TERM
printf '%s\n' 'test-product metadata regression passed (gate audit refuses FinderInfo/quarantine, admits build-system metadata, stays read-only and cache-scoped)'
