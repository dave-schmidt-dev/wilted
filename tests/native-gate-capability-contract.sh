# Sourced by tests/test-native-gate.sh: capability and entitlement source contract.
# Expects $repo_root to be set by the caller.
# shellcheck shell=bash

assert_capability_source_contract() {
  local project="$repo_root/project.yml"
  local mac_development="$repo_root/WiltedMac/WiltedMac.entitlements"
  local mac_release="$repo_root/WiltedMac/WiltedMacProduction.entitlements"
  local ios_development="$repo_root/WiltediOS/WiltediOS.entitlements"
  local ios_release="$repo_root/WiltediOS/WiltediOSProduction.entitlements"

  for required in \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.mac.tests' \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.ios.tests' \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.mac.uitests' \
    'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.ios.uitests'; do
    assert_contains "$required" "$project"
  done
  assert_contains 'Development: debug' "$project"
  target_block() {
    local target="$1"
    awk -v target="$target" '
      index($0, "  " target ":") == 1 { found = 1 }
      found && index($0, "  " target ":") != 1 && $0 ~ /^  [A-Za-z0-9_]+:/ { exit }
      found { print }
    ' "$project"
  }
  mac_block="$(target_block WiltedMac)"
  ios_block="$(target_block WiltediOS)"
  config_block() {
    local block="$1"; local config="$2"
    printf '%s\n' "$block" | awk -v config="$config" '
      index($0, "        " config ":") == 1 { found = 1 }
      found && $0 ~ /^        [A-Za-z0-9_]+:/ && index($0, "        " config ":") != 1 { exit }
      found { print }
    '
  }
  assert_target_config() {
    local target="$1"; local block="$2"; local config="$3"; local expected="$4"
    local expected_bundle="PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.wilted.$([ "$target" = WiltedMac ] && printf mac || printf ios)"
    local selected_config
    selected_config="$(config_block "$block" "$config")"
    [[ "$block" == *"$expected_bundle"* ]] || {
      printf 'assertion failed: %s bundle ID missing\n' "$target" >&2
      exit 1
    }
    [[ "$selected_config" == *"$expected"* ]] || {
      printf 'assertion failed: %s %s mapping missing %s\n' "$target" "$config" "$expected" >&2
      exit 1
    }
  }
  assert_target_config WiltedMac "$mac_block" Debug 'CODE_SIGN_ENTITLEMENTS: ""'
  assert_target_config WiltedMac "$mac_block" Debug 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"'
  assert_target_config WiltedMac "$mac_block" Development 'CODE_SIGN_ENTITLEMENTS: WiltedMac/WiltedMac.entitlements'
  assert_target_config WiltedMac "$mac_block" Development 'CODE_SIGN_STYLE: Automatic'
  assert_target_config WiltedMac "$mac_block" Development 'CODE_SIGN_IDENTITY: "Apple Development"'
  assert_target_config WiltedMac "$mac_block" Development 'DEVELOPMENT_TEAM: 4CJ49V6QHW'
  assert_target_config WiltedMac "$mac_block" Development 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE"'
  assert_target_config WiltedMac "$mac_block" Release 'CODE_SIGN_ENTITLEMENTS: WiltedMac/WiltedMacProduction.entitlements'
  assert_target_config WiltedMac "$mac_block" Release 'CODE_SIGN_IDENTITY: "Developer ID Application"'
  assert_target_config WiltedMac "$mac_block" Release 'CODE_SIGN_STYLE: Manual'
  assert_target_config WiltedMac "$mac_block" Release 'DEVELOPMENT_TEAM: 4CJ49V6QHW'
  assert_target_config WiltedMac "$mac_block" Release 'ENABLE_HARDENED_RUNTIME: YES'
  assert_target_config WiltedMac "$mac_block" Release 'PROVISIONING_PROFILE_SPECIFIER: Wilted Developer ID'
  assert_target_config WiltedMac "$mac_block" Release 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE"'
  assert_target_config WiltediOS "$ios_block" Debug 'CODE_SIGN_ENTITLEMENTS: ""'
  assert_target_config WiltediOS "$ios_block" Debug 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"'
  assert_target_config WiltediOS "$ios_block" Development 'CODE_SIGN_ENTITLEMENTS: WiltediOS/WiltediOS.entitlements'
  assert_target_config WiltediOS "$ios_block" Development 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE WILTED_SIRI"'
  assert_target_config WiltediOS "$ios_block" Release 'CODE_SIGN_ENTITLEMENTS: WiltediOS/WiltediOSProduction.entitlements'
  assert_target_config WiltediOS "$ios_block" Release 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) WILTED_CLOUDKIT_LIVE"'
  forbid_condition() { local b; b="$(config_block "$1" "$2")"; [[ "$b" != *"$3"* ]] || { printf 'assertion failed: %s defines %s\n' "$2" "$3" >&2; exit 1; }; }
  forbid_condition "$mac_block" Debug WILTED_CLOUDKIT_LIVE; forbid_condition "$ios_block" Debug WILTED_CLOUDKIT_LIVE
  # Only the Development profile carries the Siri entitlement.
  forbid_condition "$ios_block" Debug WILTED_SIRI; forbid_condition "$ios_block" Release WILTED_SIRI
  for wiring in \
    '  WiltedCloudKit:' \
    '    path: CloudSync' \
    '  WiltedPlayback:' \
    '    path: Playback' \
    '        product: WiltedSync' \
    '        product: WiltedCloudKit'; do
    assert_contains "$wiring" "$project"
  done
  assert_contains '        product: WiltedPlayback' "$project"
  if rg -n 'com\.example\.wilted' \
    "$project" "$mac_development" "$mac_release" "$ios_development" "$ios_release"; then
    printf '%s\n' 'assertion failed: placeholder binding remains' >&2
    exit 1
  fi
  assert_contains 'CODE_SIGN_IDENTITY: Apple Distribution' "$project"
  assert_contains 'DEVELOPMENT_TEAM: 4CJ49V6QHW' "$project"
  assert_contains 'PROVISIONING_PROFILE_SPECIFIER: Wilted App Store' "$project"

  assert_entitlement() {
    local file="$1"; local key="$2"; local value="$3"
    plutil -p "$file" | grep -Fq "\"$key\" => \"$value\"" || {
      printf 'assertion failed: %s missing %s=%s\n' "$file" "$key" "$value" >&2
      exit 1
    }
  }
  assert_entitlement "$mac_development" 'com.apple.developer.aps-environment' development
  assert_entitlement "$ios_development" 'aps-environment' development
  assert_entitlement "$mac_release" 'com.apple.developer.aps-environment' production
  assert_entitlement "$ios_release" 'aps-environment' production
  assert_entitlement "$mac_release" 'com.apple.developer.icloud-container-environment' Production
  assert_entitlement "$ios_release" 'com.apple.developer.icloud-container-environment' Production
  for file in "$mac_development" "$mac_release"; do
    plutil -p "$file" | grep -Fq '"com.apple.security.personal-information.location" => true' || {
      printf 'assertion failed: %s missing the location entitlement\n' "$file" >&2
      exit 1
    }
  done
  plutil -p "$repo_root/WiltedMac/Info.plist" | grep -Fq 'NSLocationUsageDescription' || {
    printf '%s\n' 'assertion failed: Mac Info.plist lacks NSLocationUsageDescription' >&2
    exit 1
  }
  assert_contains 'NSLocationUsageDescription:' "$project"
  for file in "$mac_development" "$mac_release" "$ios_development" "$ios_release"; do
    plutil -p "$file" | grep -Fq 'CloudKit' || {
      printf 'assertion failed: %s missing CloudKit service\n' "$file" >&2
      exit 1
    }
    plutil -p "$file" | grep -Fq 'iCloud.com.zerodelta.wilted' || {
      printf 'assertion failed: %s missing approved CloudKit container\n' "$file" >&2
      exit 1
    }
  done
  for file in "$mac_development" "$ios_development"; do
    if plutil -p "$file" | grep -Fq 'icloud-container-environment'; then
      printf '%s\n' 'assertion failed: Development entitlements contain Production environment key' >&2
      exit 1
    fi
  done
  plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq 'UIBackgroundModes' || {
    printf '%s\n' 'assertion failed: iOS Info.plist lacks UIBackgroundModes' >&2
    exit 1
  }
  plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq 'audio' || {
    printf '%s\n' 'assertion failed: iOS Info.plist lacks audio background mode' >&2
    exit 1
  }
  plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq '"ITSAppUsesNonExemptEncryption" => false' || {
    printf '%s\n' 'assertion failed: iOS Info.plist lacks the exempt-encryption declaration' >&2
    exit 1
  }
  for orientation in \
    UIInterfaceOrientationPortrait \
    UIInterfaceOrientationPortraitUpsideDown \
    UIInterfaceOrientationLandscapeLeft \
    UIInterfaceOrientationLandscapeRight; do
    plutil -p "$repo_root/WiltediOS/Info.plist" | grep -Fq "$orientation" || {
      printf 'assertion failed: iOS Info.plist lacks %s\n' "$orientation" >&2
      exit 1
    }
  done
}
