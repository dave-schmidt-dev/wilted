# shellcheck shell=bash
# iOS 27 App Intents system-runner integration leg.
#
# The iOS 27 simulator is intentionally isolated from the deployed iOS 26
# suite. This leg creates a disposable device on the exact installed runtime;
# simctl_gate_lib.sh owns shutdown and deletion on every exit path.

leg_ios27_appintents_tests() {
  local spec runtime device_type udid result=0
  if [[ "${native_self_test:-0}" == "1" ]]; then
    status 'native.simulator.skip purpose=ios27-appintents reason=self-test'
    return 0
  fi
  spec="$(select_ios_simulator_spec 27.2)" || return $?
  read -r runtime device_type <<<"$spec"
  udid="$(gate_sim_create wilted ios27-appintents "$device_type" "$runtime")" || return $?
  status "native.simulator.create purpose=ios27-appintents runtime=$runtime device_type=$device_type udid=$udid"
  xcode_test_leg ios27-appintents-tests "$integration_root/WiltediOS27UITests" WiltediOS27 \
    "platform=iOS Simulator,id=$udid" \
    WiltediOS27UITests/WiltedSiriAppIntentsTests/testAudioSchemaQueryAndPlaybackThroughSystemRunner \
    WiltediOS27UITests/WiltedSiriAppIntentsTests/testAmbiguousShowWaitsForChosenEntityAndPlaysLatest \
    WiltediOS27UITests/WiltedSiriAppIntentsTests/testDuplicateEpisodeTitlesAreDisambiguatedByShow \
    WiltediOS27UITests/WiltedSiriAppIntentsTests/testQueueLocationNextDoesNotStartPlayback \
    WiltediOS27UITests/WiltedSiriAppIntentsTests/testMarkCompletedIntentPersistsOutboxBeforeTransportAck \
    || result=$?
  return "$result"
}
