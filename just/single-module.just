# Shared remote build/deploy pipeline for single-Gradle-module apps in the fleet (nyetbox, augh,
# syncwich - jollyfin is multi-module and keeps its own local versions instead, see
# just/common.just's header comment). Imported the same way:
#
#   import '.just/single-module.just'
#
# Variables an importing justfile must define before this import (a plain `import` fails
# immediately if any recipe here references an undefined variable, so define them even if a value
# is just ""):
#   remote_host, remote_path, local_dist, application_id
#   default_abi             - "" for a universal APK (no per-ABI split), else e.g. "arm64-v8a"
#   gradle_extra_props       - "" or e.g. "-PaughCommit=abc123", appended to every remote Gradle
#                              invocation
#   enable_release_signing  - the literal string "true" or "false" (a recipe-body string, not a
#                              real `just` boolean). false: `build variant=release` just runs
#                              assembleRelease with no keystore - the app's own build.gradle.kts
#                              decides how (or whether) it's signed.
#   rbw_keystore_entry, keystore_jks_attachment, keystore_env_attachment, ci_tmp_dir_name
#                            - only read when enable_release_signing is "true"; see `build` below
#   zenfone_serial, mipad_host, mipad_ssh_port, mipad_adb_port, px5_host
#                            - device-deploy recipes work against the same physical fleet devices
#                              regardless of whether a given app used them before switching to
#                              this shared file; harmless to define even for an app that's never
#                              actually deployed to one of them

# --- Remote build (rofl-13 / rofl-14) ---------------------------------------

# Sync the working tree to the remote build host (excludes .git/build/.gradle). The .git exclude
# has no trailing slash so it matches both a real .git/ directory (the main checkout) and a plain
# .git file (a linked worktree's gitlink, which points at a local-only .git/worktrees/... path
# that doesn't exist on the remote host and breaks `nix develop` there if it gets copied over).
sync host=remote_host:
    rsync -az --delete \
        --exclude='.git' --exclude='**/build/' \
        --exclude='.gradle/' --exclude='**/.gradle/' \
        ./ {{host}}:{{remote_path}}/

# Run one or more Gradle tasks on the remote host (syncs first).
gradle host=remote_host *tasks: (sync host)
    ssh {{host}} 'cd {{remote_path}} && nix develop --command ./gradlew {{tasks}} {{gradle_extra_props}}'

# Build an APK remotely. variant: debug (default) or release. With enable_release_signing="true",
# release builds are signed with the persistent CI keystore (fetched from the rbw entry named by
# rbw_keystore_entry and staged on the build host only for the duration of the build) - without
# it, Gradle silently signs with the host's throwaway ~/.android/debug.keystore, and devices
# carrying CI-signed installs (GitHub releases / Obtainium) reject the APK with
# INSTALL_FAILED_UPDATE_INCOMPATIBLE.
build variant="debug" host=remote_host:
    #!/usr/bin/env bash
    set -euo pipefail
    git_revision=$(git describe --always --abbrev=12 --dirty --exclude=latest)
    build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "{{variant}}" != "release" || "{{enable_release_signing}}" != "true" ]]; then
      just sync "{{host}}"
      task="assembleDebug"
      [[ "{{variant}}" == "release" ]] && task="assembleRelease"
      ssh "{{host}}" "
        export GIT_REVISION='$git_revision'
        export BUILD_DATE='$build_date'
        cd {{remote_path}} && nix develop --command ./gradlew ':app:'$task {{gradle_extra_props}}
      "
      exit 0
    fi
    if ! rbw unlocked >/dev/null 2>&1; then
      printf 'rbw is locked - run "rbw unlock" first (needed for the CI signing keystore)\n' >&2
      exit 2
    fi
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    rbw attachment get "{{rbw_keystore_entry}}" --attachment {{keystore_jks_attachment}} --output "$tmpdir/ci.jks"
    rbw attachment get "{{rbw_keystore_entry}}" --attachment {{keystore_env_attachment}} --output "$tmpdir/ci-keystore.env"
    just sync "{{host}}"
    ssh "{{host}}" 'mkdir -p ~/{{ci_tmp_dir_name}} && chmod 700 ~/{{ci_tmp_dir_name}}'
    scp -q "$tmpdir/ci.jks" "$tmpdir/ci-keystore.env" "{{host}}:{{ci_tmp_dir_name}}/"
    # The keystore is shredded on the host whether or not the build succeeds.
    ssh "{{host}}" "
      artifact={{remote_path}}/app/build/outputs/apk/release/app-{{default_abi}}-release.apk
      previous_mtime=0
      [[ -f \"\$artifact\" ]] && previous_mtime=\$(stat -c %Y \"\$artifact\")
      set -a
      . ~/{{ci_tmp_dir_name}}/ci-keystore.env
      set +a
      export CI_KEYSTORE_PATH=\$HOME/{{ci_tmp_dir_name}}/ci.jks
      export GIT_REVISION='$git_revision'
      export BUILD_DATE='$build_date'
      cd {{remote_path}} && nix develop --command ./gradlew ':app:assembleRelease' {{gradle_extra_props}} --rerun-tasks 2>&1 | tee ~/{{ci_tmp_dir_name}}-build.log
      rc=\$?
      if [[ \$rc -eq 0 && (! -f \"\$artifact\" || \$(stat -c %Y \"\$artifact\") -le \$previous_mtime) ]]; then
        echo 'release build did not refresh its APK artifact' >&2
        rc=1
      fi
      shred -u ~/{{ci_tmp_dir_name}}/* 2>/dev/null || true
      rmdir ~/{{ci_tmp_dir_name}} 2>/dev/null || true
      exit \$rc
    "

# Copy a built APK split back to ./dist locally. variant/host same as `build`, plus abi=<abi>
# (default_abi may be "" for a universal, non-split APK).
fetch variant="debug" host=remote_host abi=default_abi:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{local_dist}}
    suffix="{{abi}}"
    [ -n "$suffix" ] && suffix="-$suffix"
    scp "{{host}}:{{remote_path}}/app/build/outputs/apk/{{variant}}/app$suffix-{{variant}}.apk" {{local_dist}}/

# Build an APK remotely and copy it back to ./dist. Same args as `build`.
build-fetch variant="debug" host=remote_host:
    just build {{variant}} {{host}}
    just fetch {{variant}} {{host}}

# ktfmt check via Gradle, remotely (mirrors .github/workflows/lint.yaml).
lint host=remote_host: (gradle host "ktfmtCheck")

# Run the unit test suite remotely.
test host=remote_host: (gradle host ":app:testDebugUnitTest")

# Remote `./gradlew clean`.
clean host=remote_host: (gradle host "clean")

# --- Zenfone 10 (USB, directly attached to this machine) --------------------

# Install an APK on the Zenfone 10 over adb (USB).
zenfone-install apk:
    adb -s {{zenfone_serial}} install -r {{apk}}

# Uninstall a package from the Zenfone 10. WARNING: wipes that app's local data (Room DB, saved
# credentials).
zenfone-uninstall pkg=application_id:
    adb -s {{zenfone_serial}} uninstall {{pkg}}

# Tail logcat from the Zenfone 10, optionally filtered by a grep pattern.
zenfone-logcat filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{filter}}" ]; then
        adb -s {{zenfone_serial}} logcat | grep -i --line-buffered "{{filter}}"
    else
        adb -s {{zenfone_serial}} logcat
    fi

# Build an APK remotely, fetch it, and install it on the Zenfone 10. variant: debug (default) or release.
deploy-zenfone variant="debug":
    just build-fetch {{variant}}
    just zenfone-install "{{local_dist}}/app{{ if default_abi != '' { '-' + default_abi } else { '' } }}-{{variant}}.apk"

# --- Mi Pad 4 (rooted, Termux SSH on port 8022) ------------------------------

# Run an arbitrary command on the Mi Pad 4 over SSH.
mipad-ssh +cmd:
    ssh -p {{mipad_ssh_port}} {{mipad_host}} "{{cmd}}"

# Interactive shell on the Mi Pad 4.
mipad-shell:
    ssh -p {{mipad_ssh_port}} {{mipad_host}}

# Find the port adbd is actually listening on (via `ss -ltnp` over root SSH), starting it as a
# fallback if it isn't running at all, then `adb connect` to it. Prints the resulting "host:port"
# adb target on stdout so other recipes can capture it - status/progress goes to stderr.
mipad-connect:
    #!/usr/bin/env bash
    set -euo pipefail
    port=$(ssh -p {{mipad_ssh_port}} {{mipad_host}} "su -c 'ss -ltnp'" 2>/dev/null \
        | awk '/adbd/ { n = split($4, a, ":"); print a[n]; exit }')
    if [ -z "$port" ]; then
        echo "adbd not listening - starting it via root shell" >&2
        ssh -p {{mipad_ssh_port}} {{mipad_host}} \
            "su -c 'setprop service.adb.tcp.port {{mipad_adb_port}} && stop adbd && start adbd'" >&2
        sleep 1
        port={{mipad_adb_port}}
    fi
    target="{{mipad_host}}:$port"
    adb connect "$target" >&2
    echo "$target"

# Install an APK on the Mi Pad 4 over adb (network, via mipad-connect). Simpler and more reliable
# than scp + `pm install`: adb push/install runs as adbd, which doesn't hit the SELinux/FUSE
# permission issues a plain scp into /sdcard runs into when system_server tries to read the file
# back.
mipad-install apk:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just mipad-connect)
    adb -s "$target" install -r {{apk}}

# Uninstall a package from the Mi Pad 4. WARNING: wipes that app's local data.
mipad-uninstall pkg=application_id:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just mipad-connect)
    adb -s "$target" uninstall {{pkg}}

# Tail logcat from the Mi Pad 4, optionally filtered by a grep pattern.
mipad-logcat filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just mipad-connect)
    if [ -n "{{filter}}" ]; then
        adb -s "$target" logcat | grep -i --line-buffered "{{filter}}"
    else
        adb -s "$target" logcat
    fi

# Build an APK remotely, fetch it, and install it on the Mi Pad 4. variant: debug (default) or release.
deploy-mipad variant="debug":
    just build-fetch {{variant}}
    just mipad-install "{{local_dist}}/app{{ if default_abi != '' { '-' + default_abi } else { '' } }}-{{variant}}.apk"

# --- Pixel 5 (px5.lan, wireless adb enabled on demand via Home Assistant/Tasker) --------------

# Enable wireless adb on the Pixel 5 (via `zhj adb::connect`, which triggers it through Home
# Assistant/Tasker) and connect. The port is dynamic (assigned fresh each time wireless debugging
# is (re)enabled), so this always re-discovers it from `adb devices` rather than assuming a fixed
# one - prints the resulting "host:port" target on stdout, status goes to stderr.
px5-connect:
    #!/usr/bin/env bash
    set -euo pipefail
    zhj adb::connect {{px5_host}} >&2
    target=$(adb devices | awk -v h="{{px5_host}}" '$1 ~ h { print $1; exit }')
    if [ -z "$target" ]; then
        echo "px5 (host {{px5_host}}) not found in \`adb devices\` after connecting" >&2
        exit 1
    fi
    echo "$target"

# Install an APK on the Pixel 5 over adb (wireless, via px5-connect).
px5-install apk:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just px5-connect)
    adb -s "$target" install -r {{apk}}

# Uninstall a package from the Pixel 5. WARNING: wipes that app's local data.
px5-uninstall pkg=application_id:
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just px5-connect)
    adb -s "$target" uninstall {{pkg}}

# Tail logcat from the Pixel 5, optionally filtered by a grep pattern.
px5-logcat filter="":
    #!/usr/bin/env bash
    set -euo pipefail
    target=$(just px5-connect)
    if [ -n "{{filter}}" ]; then
        adb -s "$target" logcat | grep -i --line-buffered "{{filter}}"
    else
        adb -s "$target" logcat
    fi

# Build an APK remotely, fetch it, and install it on the Pixel 5. variant: debug (default) or release.
deploy-px5 variant="debug":
    just build-fetch {{variant}}
    just px5-install "{{local_dist}}/app{{ if default_abi != '' { '-' + default_abi } else { '' } }}-{{variant}}.apk"

# --- All devices -------------------------------------------------------------

# Build once, fetch once, install on every named test device (Zenfone 10, Mi Pad 4, Pixel 5). The
# default target for iterating on changes - see AGENTS.md.
deploy-all variant="debug":
    just build-fetch {{variant}}
    just zenfone-install "{{local_dist}}/app{{ if default_abi != '' { '-' + default_abi } else { '' } }}-{{variant}}.apk"
    just mipad-install "{{local_dist}}/app{{ if default_abi != '' { '-' + default_abi } else { '' } }}-{{variant}}.apk"
    just px5-install "{{local_dist}}/app{{ if default_abi != '' { '-' + default_abi } else { '' } }}-{{variant}}.apk"
