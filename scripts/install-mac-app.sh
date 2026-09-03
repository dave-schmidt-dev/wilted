#!/usr/bin/env bash
set -Eeuo pipefail

# Builds the Mac app and installs it as the locally running copy.
#
# Debug, not Release: Release signs with a Developer ID identity and a
# distribution profile this machine is not required to hold, while Debug is
# Apple Development signed with a certificate-anchored designated requirement.
# That requirement is what keeps the Documents TCC grant for
# com.zerodelta.wilted.mac alive across rebuilds, so the installed copy does
# not re-prompt every time it is replaced.
#
# Idempotent: run it again after any change and the installed copy is replaced
# in place. A running copy is quit first, because ditto over a live bundle
# leaves a half-replaced app.
#
# Usage: scripts/install-mac-app.sh [destination-dir]   (default: /Applications)

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/app-identity.sh
source "$repo_root/scripts/lib/app-identity.sh"
destination_dir="${1:-/Applications}"
bundle_id='com.zerodelta.wilted.mac'
derived="$repo_root/.build/mac-install"

status() { printf '%s\n' "$*" >&2; }

[[ -d "$destination_dir" && -w "$destination_dir" ]] ||
  { status "install.error destination is not a writable directory: $destination_dir"; exit 1; }

command -v xcodegen >/dev/null 2>&1 || { status 'install.error missing xcodegen'; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { status 'install.error missing xcodebuild'; exit 1; }

mkdir -p "$derived"

status 'install.generate project'
xcodegen generate --spec "$repo_root/project.yml" --project "$repo_root" --project-root "$repo_root" >/dev/null

# Xcode's code-signing pass rejects Finder metadata left on a prior product.
# Remove only the installer-owned app product; the rest of DerivedData remains
# available for incremental builds.
previous_app="$derived/Build/Products/Debug/WiltedMac.app"
if [[ -d "$previous_app" || -L "$previous_app" ]]; then
  status "install.clean previous-product=$previous_app"
  rm -rf -- "$previous_app"
fi

status 'install.build configuration=Debug'
xcodebuild build \
  -project "$repo_root/Wilted.xcodeproj" \
  -scheme WiltedMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived" \
  -quiet >"$derived.log" 2>&1 || {
    status 'install.build failed; last 40 lines follow'
    tail -40 "$derived.log" >&2
    exit 1
  }

app="$(find "$derived/Build/Products" -maxdepth 2 -type d -name '*.app' -print -quit)"
[[ -n "$app" && -d "$app" ]] || { status 'install.error no app product was produced'; exit 1; }

# Refuse to install something that is not this app, rather than overwriting
# whatever happens to share the product name.
built_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
[[ "$built_id" == "$bundle_id" ]] ||
  { status "install.error built bundle identifier is '$built_id', expected '$bundle_id'"; exit 1; }
codesign --verify --strict "$app" || { status 'install.error built app failed signature verification'; exit 1; }

target="$destination_dir/$(basename "$app")"
if [[ -e "$target" ]]; then
  existing_id="$(wilted_bundle_identifier "$target")"
  [[ "$existing_id" == "$bundle_id" ]] ||
    { status "install.error $target exists and is not $bundle_id; refusing to replace it"; exit 1; }
fi

# The check above covers one path. LaunchServices does not: it resolves the
# identifier across every registered bundle, so a second app in the destination
# claiming $bundle_id makes the click a coin flip regardless of what is written
# here. Refuse and name it rather than deleting someone else's app.
conflicts=()
while IFS= read -r conflict; do
  [[ -n "$conflict" ]] && conflicts+=("$conflict")
done < <(wilted_conflicting_bundles "$destination_dir" "$bundle_id" "$target")
if (( ${#conflicts[@]} > 0 )); then
  status "install.error another bundle in $destination_dir already claims $bundle_id:"
  for conflict in "${conflicts[@]}"; do status "install.error   $conflict"; done
  status 'install.error move it to the Trash and run this again; two bundles for one identifier'
  status 'install.error make which binary launches unpredictable'
  exit 1
fi

# Every running copy, not just the one at the install path: on 2026-09-01 the
# owner was running a stale gate build from build/quickcheck, which an install
# keyed on $target would have left running and believing itself current.
running=()
while IFS= read -r pid; do
  [[ -n "$pid" ]] && running+=("$pid")
done < <(wilted_running_bundle_pids "$bundle_id")
if (( ${#running[@]} > 0 )); then
  for pid in "${running[@]}"; do
    status "install.quit pid=$pid path=$(ps -o comm= -p "$pid" 2>/dev/null || echo unknown)"
  done
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  # A copy the Apple Event did not reach (a second bundle under the same
  # identifier only sometimes answers) gets a plain terminate, then a kill.
  # Each is a request; the install proceeds only once the process list is
  # empty, otherwise the old binary outlives the bundle it was loaded from and
  # keeps running while believing itself current.
  if ! wilted_wait_for_bundle_exit "$bundle_id" 5; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done < <(wilted_running_bundle_pids "$bundle_id")
    if ! wilted_wait_for_bundle_exit "$bundle_id" 5; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && kill -KILL "$pid" 2>/dev/null || true
      done < <(wilted_running_bundle_pids "$bundle_id")
      wilted_wait_for_bundle_exit "$bundle_id" 3 || {
        status "install.error a running copy would not exit: $(wilted_running_bundle_pids "$bundle_id" | tr '\n' ' ')"
        exit 1
      }
    fi
  fi
fi

rm -rf "$target"
ditto "$app" "$target"
codesign --verify --strict "$target" || { status 'install.error installed app failed signature verification'; exit 1; }

# Stale products under the repo's own build roots are deleted, not merely
# unregistered: Spotlight indexes ~/Documents and the Dock remembers paths, so
# a bundle that still exists can be launched by path and re-register itself.
# That is how an eleven-hour-old build/quickcheck app came back an hour after
# a clean install. Bundles outside the repo are never deleted.
while IFS= read -r pruned; do
  [[ -n "$pruned" ]] && status "install.prune removed=$pruned"
done < <(wilted_prune_build_products "$repo_root" "$bundle_id" "$app")

# Gate and capture runs build into temp roots they then delete, and every one of
# those bundles registered under this identifier on the way past. The records
# survive the deletion, so they are swept here where exactly one path is known
# to be the right answer.
status 'install.register sweep'
wilted_sweep_registrations "$bundle_id" "$target"

# The check that would have caught the 2026-09-01 failure. Writing the bundle
# proves nothing about what a click resolves to; only asking LaunchServices does.
registered=()
while IFS= read -r path; do
  [[ -n "$path" ]] && registered+=("$path")
done < <(wilted_registered_bundle_paths "$bundle_id")
if (( ${#registered[@]} != 1 )) || [[ "${registered[0]}" != "$target" ]]; then
  status "install.error $bundle_id does not resolve to $target after the sweep; registered paths:"
  if (( ${#registered[@]} == 0 )); then
    status 'install.error   (none)'
  else
    for path in "${registered[@]}"; do status "install.error   $path"; done
  fi
  exit 1
fi
status "install.register resolves=$target"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist" 2>/dev/null || echo unknown)"
# describe --always --dirty, not rev-parse: a plain revision stamped from a dirty
# tree names a commit the installed binary was not built from.
status "install.complete path=$target version=$version commit=$(git -C "$repo_root" describe --always --dirty)"
