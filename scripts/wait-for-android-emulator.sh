#!/usr/bin/env bash

# Waits for a booted Android emulator to actually be ready for UI input, not just for
# sys.boot_completed to flip. reactivecircus/android-emulator-runner already waits for the
# emulator to come up, but sys.boot_completed can flip to 1 before the device is actually ready
# to receive UI input (settings/package manager not fully up yet) - on a freshly created AVD
# (force-avd-creation) that race can show up as the very first UI interaction in an instrumented
# test failing with "Failed to inject touch input". Wait for a fuller set of readiness signals
# before doing anything else.
#
# Used two ways:
# - as a normal job step, via the wait-for-android-emulator composite action in this repo
# - inline inside android-emulator-runner's own `script:` field (which runs plain shell text, not
#   job steps, so a `uses:` composite action can't be called from there):
#     bash <(curl -fsSL https://raw.githubusercontent.com/pschmitt/android-app-ci/main/scripts/wait-for-android-emulator.sh)

set -u

wait_for_android() {
  local attempt boot_completed device_provisioned package_service package_path

  adb wait-for-device

  for attempt in $(seq 1 60)
  do
    boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    device_provisioned="$(adb shell settings get global device_provisioned 2>/dev/null | tr -d '\r' || true)"
    package_service="$(adb shell service check package 2>/dev/null | tr -d '\r' || true)"
    package_path="$(adb shell cmd package path android 2>/dev/null | tr -d '\r' || true)"

    if [[ "$boot_completed" == "1" && "$device_provisioned" == "1" && "$package_service" == *found* && "$package_path" == package:* ]]
    then
      return 0
    fi

    if [[ "$attempt" == "60" ]]
    then
      printf 'Android system providers did not become ready\n' >&2
      adb shell getprop sys.boot_completed || true
      adb shell settings get global device_provisioned || true
      adb shell service check package || true
      adb shell cmd package path android || true
      return 1
    fi

    sleep 5
  done
}

main() {
  wait_for_android
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]
then
  main "$@"
fi

# vim: set ft=sh et ts=2 sw=2 :
