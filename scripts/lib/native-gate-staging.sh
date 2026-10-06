# shellcheck shell=bash
# Disposable integration-root staging for scripts/test-gate.sh.
#
# Relies on the gate's `repo_root`, `tmp_root` and `project_yml`, and sets its
# `integration_root`.

# Signing inputs that XcodeGen resolves relative to the generated project; the
# xcodebuild legs must find them there so nothing reads or writes the checkout.
wilted_gate_xcodegen_inputs=(
  WiltedMac/Info.plist
  WiltedMac/WiltedMac.entitlements
  WiltedMac/WiltedMacProduction.entitlements
  WiltediOS/Info.plist
  WiltediOS/WiltediOS.entitlements
  WiltediOS/WiltediOSProduction.entitlements
  WiltediOSIntents/Info.plist
  WiltediOSIntents/WiltediOSIntents.entitlements
  WiltediOSIntents/WiltediOSIntentsProduction.entitlements
  WiltedWatch/Info.plist
)

prepare_integration_root() {
  integration_root="$tmp_root/integration-root"
  mkdir -p "$integration_root/WiltedKit" "$integration_root/Producer" "$integration_root/CloudSync" "$integration_root/Playback" "$integration_root/Listener"
  cp "$project_yml" "$integration_root/project.yml"
  cp -R "$repo_root/Shared" "$repo_root/WiltedMac" "$repo_root/WiltedMacTests" \
    "$repo_root/WiltedMacUITests" "$repo_root/WiltediOS" "$repo_root/WiltediOSTests" \
    "$repo_root/WiltediOSIntents" "$repo_root/WiltedWatch" "$repo_root/WiltediOSUITests" "$integration_root/"
  cp "$repo_root/WiltedKit/Package.swift" "$integration_root/WiltedKit/Package.swift"
  cp -R "$repo_root/WiltedKit/Sources" "$repo_root/WiltedKit/Tests" "$integration_root/WiltedKit/"
  cp "$repo_root/Producer/Package.swift" "$integration_root/Producer/Package.swift"
  cp -R "$repo_root/Producer/Sources" "$repo_root/Producer/Tests" "$integration_root/Producer/"
  cp "$repo_root/CloudSync/Package.swift" "$integration_root/CloudSync/Package.swift"
  cp -R "$repo_root/CloudSync/Sources" "$repo_root/CloudSync/Tests" "$integration_root/CloudSync/"
  cp "$repo_root/Playback/Package.swift" "$integration_root/Playback/Package.swift"
  cp -R "$repo_root/Playback/Sources" "$repo_root/Playback/Tests" "$integration_root/Playback/"
  cp "$repo_root/Listener/Package.swift" "$integration_root/Listener/Package.swift"
  cp -R "$repo_root/Listener/Sources" "$repo_root/Listener/Tests" "$integration_root/Listener/"
}
