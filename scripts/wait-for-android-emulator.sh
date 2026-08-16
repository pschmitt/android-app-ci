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
# - inline inside android-emulator-runner's own `script:` field (which runs each line via `sh -c`,
#   not job steps and not bash, so neither a `uses:` composite action nor bash-only process
#   substitution works there - pipe into bash instead):
#     curl -fsSL https://raw.githubusercontent.com/pschmitt/android-app-ci/main/scripts/wait-for-android-emulator.sh | bash

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

# Always executed, never sourced (both call sites above run this file directly - as the composite
# action's own step, or piped into a fresh `bash`) - unlike the sibling scripts vendored in each
# app's own ci/, there's no in-repo caller that sources this one for its functions instead. The
# usual "${BASH_SOURCE[0]}" == "${0}" guard some scripts use to support both breaks under `set -u`
# when piped into bash rather than executed as a file: BASH_SOURCE is then an empty array, and
# BASH_SOURCE[0] is an unbound reference into it - confirmed live ("BASH_SOURCE[0]: unbound
# variable") on the very first real screenshots.yaml run after adopting this script fleet-wide.
main "$@"

# vim: set ft=sh et ts=2 sw=2 :
