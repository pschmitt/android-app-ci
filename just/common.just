# Shared task-runner recipes for the Android app fleet (nyetbox, augh, jollyfin, syncwich, ...).
#
# This file is vendored (committed, not gitignored - not a submodule either, see this repo's
# README for why) into each app repo as `.just/common.just` and imported near the top of the
# app's own justfile:
#
#   import '.just/common.just'
#
# `just update-common` (defined in each app's own justfile) re-fetches this file on demand - it
# has to be a real committed file, not fetched lazily, since `just` fails to parse an `import` of
# a file that doesn't exist yet at all, and there'd be no way to run update-common to fetch it.
#
# No `default` recipe here even though every app wants one: `just` only considers recipes written
# directly in the top-level justfile (not ones pulled in via import) when deciding what a bare
# `just` invocation runs, regardless of the import statement's position - each app keeps its own
# trivial `default: @just --list` as the literal first recipe in its own justfile instead.
#
# Only recipes that need *no* app-specific variables live here, deliberately: the remote
# sync/build/deploy pipeline (rofl-13/rofl-14, the worktree-suffix trick, per-app keystore/rbw
# entries, ABI-split vs. universal APKs, device-specific deploy targets) still differs enough
# between apps - an extra Gradle property here, no ABI split there, a signed release build there -
# that force-fitting it into one shared recipe risks silently changing behavior. That's a good
# candidate for a follow-up pass with more per-app verification, not this one.
#
# Variables an importing justfile must define before this recipe is used:
#   play_package  - Play Console packageName, only needed for `screenshots-upload`

# Format Kotlin sources locally with ktfmt (lightweight - not a Gradle build, safe to run on this
# machine). CAUTION: this is nixpkgs' standalone ktfmt, which may be a newer version than the one
# CI actually uses (see gradle/libs.versions.toml) - treat this as an advisory quick pass, not a
# substitute for CI's real ktfmtCheck.
format:
    ktfmt --kotlinlang-style $(git ls-files '*.kt' '*.kts')

# Nix formatting for this repo's flake.nix.
nix-fmt:
    nix develop --command nixfmt flake.nix

# Nix lint for this repo's flake.nix.
nix-lint:
    nix develop --command statix check

# Upload the generated screenshots to the Play Console listing. Deliberately separate from
# capturing them: review the images (build artifact, or the PR screenshots.yaml opens with
# open_pr) before this ever runs. Replaces each bucket's existing images with the local set rather
# than appending to it (see the delete-all call below) - the locally generated set is always the
# authoritative "current" one.
screenshots-upload:
    #!/usr/bin/env bash
    set -euo pipefail
    image_dir="fastlane/metadata/android"
    shopt -s nullglob
    image_types=(phoneScreenshots sevenInchScreenshots tenInchScreenshots)
    found_images=0
    for image_type in "${image_types[@]}"
    do
      image_glob=("$image_dir"/en-US/images/"$image_type"/*)
      if [[ ${#image_glob[@]} -gt 0 ]]
      then
        found_images=1
      fi
    done
    if [[ "$found_images" -eq 0 ]]
    then
      printf 'No generated screenshots found under %s\n' "$image_dir" >&2
      printf 'Run the screenshot-capture recipe first.\n' >&2
      exit 1
    fi
    if ! command -v gpc >/dev/null
    then
      printf 'gpc (playconsole-cli) is required for Play Console uploads\n' >&2
      exit 1
    fi
    if ! gpc apps list --output json | rg -q '"package_name":"{{play_package}}"'
    then
      printf 'Play Console package %s was not found via `gpc apps list`\n' "{{play_package}}" >&2
      exit 1
    fi
    for image_type in "${image_types[@]}"
    do
      image_glob=("$image_dir"/en-US/images/"$image_type"/*)
      [[ ${#image_glob[@]} -gt 0 ]] || continue
      # StoreScreenshotTest-style tests capture every screen in both dark and light mode (5
      # screens x 2 = 10 per device type), but Play rejects more than 8 screenshots per language
      # outright (confirmed live: "This app has more than 8 screenshots for language en-US.").
      # Sort and cap at 8 rather than fail the whole upload: "NN_name" sorts immediately before
      # its "NN_name_light" counterpart for each screen, so a plain sort interleaves dark/light
      # pairs per screen (01, 01_light, 02, 02_light, ...) - taking the first 8 keeps both modes
      # of the first 4 screens. All captures stay committed in git either way; only the Play
      # Console upload is capped.
      if [[ ${#image_glob[@]} -gt 8 ]]
      then
        IFS=$'\n' image_glob=($(sort <<< "${image_glob[*]}"))
        unset IFS
        image_glob=("${image_glob[@]:0:8}")
      fi
      # Delete existing images of this type first: gpc's upload only ever appends, so re-running
      # this against a bucket that already has images (a prior manual upload, or just re-running
      # after a fresh capture) silently piles up duplicates instead of replacing them - confirmed
      # live, twice, once as literal duplicate screenshots and once by exceeding Play's 8-per-
      # language screenshot cap outright. The locally generated set is always the authoritative
      # "current" one, so start from empty every time instead.
      gpc --package {{play_package}} images delete-all --locale en-US --type "$image_type" --confirm
      for image in "${image_glob[@]}"
      do
        printf 'Uploading %s\n' "$image"
        gpc --package {{play_package}} images upload \
          --locale en-US \
          --type "$image_type" \
          --file "$image"
      done
    done
