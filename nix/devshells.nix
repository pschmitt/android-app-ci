# Shared Android app devShell builder for the fleet (nyetbox, augh, jollyfin, syncwich, ...).
#
# Not a flake itself - a plain function, imported directly from a consumer's own flake.nix so
# each app keeps its own nixpkgs/android-nixpkgs/git-hooks flake inputs (and its own flake.lock
# pins) rather than inheriting a second, potentially-diverging set from this repo. Typical caller:
#
#   android-app-ci = {
#     url = "github:pschmitt/android-app-ci";
#     flake = false;
#   };
#
#   ...
#
#   androidEnv = import "${android-app-ci}/nix/devshells.nix" {
#     inherit pkgs android-nixpkgs system;
#     appName = "Nyetbox";
#     buildToolsVersion = "37.0.0";
#     platformVersion = "37";
#     gitHooksLib = git-hooks.lib;    # null to skip pre-commit entirely
#     preCommitExtra = {
#       check-added-large-files.excludes = [ "^ci/netbox/fixtures/.*\\.dump$" ];
#     };
#     extraPackages = [ nyetboxSetup ];
#     screenshotsSystemImage = "system-images-android-34-google-apis-x86-64"; # null to skip
#     quickStart = ''
#       echo "  just build                    # Build debug APK on rofl-13"
#     '';
#   };
#
# in {
#   devShells.${system} = androidEnv.devShells;
#   checks.${system} = androidEnv.checks;         # only present if gitHooksLib was set
# }
{
  pkgs,
  android-nixpkgs,
  system,

  # Human-readable app name for the shellHook banner, e.g. "Nyetbox".
  appName,

  # Android build-tools/platform version pins, e.g. "37.0.0" / "37".
  buildToolsVersion,
  platformVersion,

  # JDK package to use, e.g. pkgs.jdk21.
  jdk ? pkgs.jdk21,

  # Extra packages in the default devShell beyond [ jdk just ktfmt android-composition ].
  extraPackages ? [ ],

  # git-hooks.nix integration (present in nyetbox/jollyfin/syncwich, absent in augh). Pass
  # `gitHooksLib = git-hooks.lib` (the flake output, so this module doesn't need its own
  # git-hooks.nix input) to enable; leave null to skip entirely.
  gitHooksLib ? null,
  preCommitSrc ? ./.,
  # Extra/overriding hooks merged into the default set below, e.g. to add per-repo
  # check-added-large-files excludes.
  preCommitExtra ? { },

  # Set to null to skip the "screenshots" devShell entirely (jollyfin/syncwich don't have local
  # AVD-based screenshot capture, only CI-driven capture).
  screenshotsSystemImage ? "system-images-android-34-google-apis-x86-64",

  # Extra shellHook lines appended after the standard "Quick start" block, e.g. app-specific
  # `just` recipe hints.
  quickStart ? "",
}:
let
  android-composition = android-nixpkgs.sdk.${system} (
    sdkPkgs:
    with sdkPkgs;
    [
      cmdline-tools-latest
      platform-tools
    ]
    ++ [
      sdkPkgs."build-tools-${builtins.replaceStrings [ "." ] [ "-" ] buildToolsVersion}"
      sdkPkgs."platforms-android-${platformVersion}"
    ]
  );

  android-composition-screenshots = android-nixpkgs.sdk.${system} (
    sdkPkgs:
    with sdkPkgs;
    [
      cmdline-tools-latest
      platform-tools
      emulator
      sdkPkgs.${screenshotsSystemImage}
    ]
  );

  defaultPreCommitHooks = {
    trim-trailing-whitespace.enable = true;
    end-of-file-fixer.enable = true;
    check-merge-conflicts.enable = true;
    check-yaml.enable = true;
    nixfmt.enable = true;
    statix.enable = true;
    # No ktfmt pre-commit hook: nixpkgs only ships a recent standalone ktfmt, but the project's
    # Gradle plugin pins an older ktfmt (see gradle/libs.versions.toml), and the two format some
    # constructs differently. A hook running the wrong version could "fix" a file into a state
    # that then fails CI's real `./gradlew ktfmtCheck`. Use `just lint` (remote, runs the pinned
    # Gradle plugin) as the authoritative check instead.
  };

  pre-commit-check =
    if gitHooksLib == null then
      null
    else
      gitHooksLib.${system}.run {
        src = preCommitSrc;
        hooks = defaultPreCommitHooks // preCommitExtra;
      };
in
{
  devShells = {
    default = pkgs.mkShell {
      buildInputs = [
        jdk
        android-composition
        pkgs.just
        pkgs.ktfmt
      ]
      ++ extraPackages;

      shellHook =
        (if pre-commit-check != null then pre-commit-check.shellHook else "")
        + ''
          echo "Development environment: ${appName}"

          export JAVA_HOME=${jdk}/lib/openjdk
          export ANDROID_SDK_ROOT=${android-composition}/share/android-sdk
          export ANDROID_HOME=$ANDROID_SDK_ROOT
          export PATH=$PATH:$ANDROID_SDK_ROOT/platform-tools
          export PATH=$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin
          export PATH=$PATH:$ANDROID_SDK_ROOT/build-tools/${buildToolsVersion}
          export GRADLE_OPTS="-Dorg.gradle.daemon=false -Dorg.gradle.project.android.aapt2FromMavenOverride=$ANDROID_SDK_ROOT/build-tools/${buildToolsVersion}/aapt2"

          # Removing sdk.dir from local.properties if present, otherwise aidl fails to run.
          if [ -f local.properties ]; then
            sed -i -E '/^sdk\.dir=/d' local.properties
          fi

          echo "Java version: $(java -version 2>&1 | head -n1)"
          echo "Available commands: ./gradlew, adb, aapt2, just, ktfmt"
          echo ""
          if [ "$(hostname)" != "rofl-13" ] && [ "$(hostname)" != "rofl-14" ]; then
            echo "Don't run ./gradlew directly on this machine - see AGENTS.md."
            echo "Use the 'just' recipes below, which build on rofl-13/rofl-14 instead:"
            echo ""
            echo "Quick start:"
            echo "  just build                    # Build debug APK on rofl-13"
            echo "  just build-fetch              # ...and copy it back to ./dist"
            echo "  just --list                   # See all available recipes"
            ${quickStart}
          else
            echo "Quick start (on a remote build host):"
            echo "  ./gradlew :app:assembleDebug   # Build debug APK"
            echo "  ./gradlew :app:installDebug    # Install to connected device"
            echo "  ./gradlew test"
          fi
        '';
    };
  }
  // pkgs.lib.optionalAttrs (screenshotsSystemImage != null) {
    screenshots = pkgs.mkShell {
      packages = [
        pkgs.fastlane
        android-composition-screenshots
      ];

      shellHook = ''
        export ANDROID_SDK_ROOT=${android-composition-screenshots}/share/android-sdk
        export ANDROID_HOME=$ANDROID_SDK_ROOT
        export PATH=$PATH:$ANDROID_SDK_ROOT/platform-tools
        export PATH=$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin
        export PATH=$PATH:$ANDROID_SDK_ROOT/emulator

        # avdmanager (XDG-aware) and emulator (not) disagree on the default AVD home when unset -
        # avdmanager creates under XDG_CONFIG_HOME, emulator looks in ~/.android. Pin both to the
        # same location explicitly so they agree.
        export ANDROID_AVD_HOME="$HOME/.android/avd"
        mkdir -p "$ANDROID_AVD_HOME"
      '';
    };
  };
}
// {
  # Always present (possibly empty) so callers can unconditionally write
  # `checks.${system} = androidEnv.checks;` without an `or {}` guard.
  checks = pkgs.lib.optionalAttrs (pre-commit-check != null) {
    inherit pre-commit-check;
  };
}
