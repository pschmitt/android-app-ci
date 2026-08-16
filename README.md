# android-app-ci

Shared GitHub Actions (and a shared Nix devShell builder) for [@pschmitt](https://github.com/pschmitt)'s
fleet of Kotlin/Compose Android apps: [nyetbox](https://github.com/pschmitt/nyetbox),
[augh](https://github.com/pschmitt/augh), [jollyfin](https://github.com/pschmitt/jollyfin), and
[syncwich](https://github.com/pschmitt/syncwich).

These apps started as copies of each other and kept drifting - the same CI pipeline
hand-ported from repo to repo, picking up small inconsistencies and missed features each time
(see git blame/comments like "ported from the sibling nyetbox project's screenshot/E2E CI" in
several of those repos). This repo is the canonical version of that shared pipeline: each
consuming app keeps a thin caller workflow with its own triggers/parameters and calls out here
with `uses:`, instead of vendoring the whole thing.

Where the 4 apps' existing workflows disagreed on how complete a feature was (e.g. one repo's
`release.yaml` had asset-vacuuming and screenshot-triggering, another had only one of the two),
this repo standardizes on the more complete/safer behavior for everyone, not the lowest common
denominator.

## What's here

### Composite actions (`.github/actions/`)

- **`setup-jdk-gradle`** - installs the pinned Temurin JDK + `gradle/actions/setup-gradle`. Used
  by nearly every job below.
- **`wait-for-android-emulator`** - waits for a booted emulator to actually be ready for UI input,
  not just for `sys.boot_completed`. Replaces each repo's hand-copied `ci/android-e2e-wait.sh` /
  `ci/android-emulator-wait.sh` for use as a normal job step. `android-emulator-runner`'s own
  `script:` input runs each line via `sh -c` (not bash, and not job steps), so neither a composite
  action's `uses:` nor bash-only process substitution (`bash <(curl ...)`) works from inside it -
  confirmed live, `sh` rejected `<(` outright ("Syntax error: "(" unexpected"). Pipe into bash
  instead:
  ```yaml
  script: |
    curl -fsSL https://raw.githubusercontent.com/pschmitt/android-app-ci/main/scripts/wait-for-android-emulator.sh | bash
    # ... rest of the capture script
  ```
- **`enable-kvm`** - grants the job user `/dev/kvm` access on GitHub-hosted runners (without this
  the emulator silently falls back to software rendering and takes 15+ minutes to boot).
- **`decode-ci-keystore`** - thin wrapper around `timheuer/base64-to-file` for the fleet's shared
  `CI_KEYSTORE_BASE64`/`CI_KEYSTORE_PASSWORD`/`CI_KEY_ALIAS`/`CI_KEY_PASSWORD` secret convention.

### Reusable workflows (`.github/workflows/`, all `on: workflow_call`)

- **`lint.yaml`** - ktfmt + Android Lint, with the ktfmt auto-fix-PR behavior.
- **`build.yaml`** - debug build + unit tests + per-ABI artifact upload. Parameterized enough to
  call twice for a multi-module app (see jollyfin's template below).
- **`release.yaml`** - the full signed-APK GitHub Release pipeline (rolling "latest" prerelease +
  tagged releases, SLSA attestation, checksums, stale-asset vacuuming, screenshot-refresh
  trigger).
- **`play-store.yaml`** - signed AAB build + gated Play Console internal-track publish (requires
  the `PLAY_PUBLISH_ENABLED` repo variable, so a fresh checkout can never publish by accident).
- **`play-store-assets.yaml`** - pushes `fastlane/metadata/.../images/**` to the Play Console
  listing via `gpc` (delegates the actual upload to the caller's own `just screenshots-upload`).
- **`screenshots-open-pr.yaml`** - the "download capture artifacts, flatten, open/update a PR with
  an inline gallery" tail end of a Screenshots workflow. The `capture` job itself (emulator +
  fixture setup) stays in each app's own workflow - the fixture (NetBox/Jellyfin/Mealie/none) is
  too app-specific to share, though the KVM step and `android-emulator-runner` config block are
  identical across all 4 apps if you want to copy them by hand.

See "Just recipes" and "Nix" below for `just/` and `nix/devshells.nix`.

## Caller templates

Every reusable workflow needs `secrets: inherit` on the calling job so `CI_KEYSTORE_*`,
`PLAY_SERVICE_ACCOUNT_JSON`, and `WORKFLOW_PUSH_TOKEN` reach it. Pin `@main` or a tag/SHA per your
risk tolerance - `@main` is simplest and matches how the 4 apps previously trusted a hand-copied
file anyway, but a tag gives you an explicit upgrade step instead of picking up changes silently.

### `lint.yaml`

```yaml
name: Lint
on:
  push:
    branches: [main]
    paths: ['**.kt', '**.kts', '.github/workflows/lint.yaml', 'app/lint-baseline.xml']
  pull_request:
    paths: ['**.kt', '**.kts', '.github/workflows/lint.yaml', 'app/lint-baseline.xml']
  workflow_dispatch:
jobs:
  lint:
    uses: pschmitt/android-app-ci/.github/workflows/lint.yaml@main
    secrets: inherit
```

### `build.yaml`

```yaml
name: Build
on: [push, pull_request]
jobs:
  build:
    uses: pschmitt/android-app-ci/.github/workflows/build.yaml@main
```

Multi-module (jollyfin: `app/phone` + `app/tv`), matrixed over module:

```yaml
name: Build
on: [push, pull_request]
jobs:
  phone:
    uses: pschmitt/android-app-ci/.github/workflows/build.yaml@main
    with:
      gradle-task: ':app:phone:assembleLibreDebug'
      apk-dir: app/phone/build/outputs/apk/libre/debug
      artifact-prefix: phone-libre
  tv:
    uses: pschmitt/android-app-ci/.github/workflows/build.yaml@main
    with:
      run-unit-tests: false # already covered by the phone job
      gradle-task: ':app:tv:assembleLibreDebug'
      apk-dir: app/tv/build/outputs/apk/libre/debug
      artifact-prefix: tv-libre
```

### `release.yaml`

```yaml
name: Release
on:
  push:
    branches: [main]
    tags: ['v*', '*.*.*']
  workflow_dispatch:
jobs:
  release:
    uses: pschmitt/android-app-ci/.github/workflows/release.yaml@main
    with:
      app-display-name: Nyetbox
      application-id: dev.pschmitt.nyetbox
      artifact-label: nyetbox
      # compute-version-name: true   # syncwich-style -PversionName from `git describe`
      # enable-release-signing: false  # augh-style unsigned/debug-key release
    secrets: inherit
```

### `play-store.yaml`

```yaml
name: Play Store Release
on:
  push:
    tags: ['v*', '*.*.*']
  workflow_dispatch:
    inputs:
      version_code: { type: string }
      version_name: { type: string }
      publish: { type: boolean, default: false, required: true }
jobs:
  play-store:
    uses: pschmitt/android-app-ci/.github/workflows/play-store.yaml@main
    with:
      application-id: dev.pschmitt.nyetbox
      artifact-label: nyetbox
      version-code: ${{ github.event_name == 'workflow_dispatch' && inputs.version_code || '' }}
      version-name: ${{ github.event_name == 'workflow_dispatch' && inputs.version_name || '' }}
      publish: ${{ github.event_name == 'workflow_dispatch' && inputs.publish || true }}
    secrets: inherit
```

### `play-store-assets.yaml`

```yaml
name: Play Store Assets
on:
  push:
    branches: [main]
    paths: ['fastlane/metadata/android/en-US/images/**']
  workflow_dispatch:
jobs:
  upload:
    uses: pschmitt/android-app-ci/.github/workflows/play-store-assets.yaml@main
    with:
      application-id: dev.pschmitt.nyetbox
    secrets: inherit
```

### `screenshots.yaml`

Keep your own `capture` job (fixture-specific), then call the shared tail:

```yaml
jobs:
  capture:
    # ... unchanged, app-specific ...
    # Must upload artifacts named "<artifact-label>-<device_type>-screenshots-${{ github.run_id }}"

  open-pr:
    needs: capture
    if: ${{ inputs.open_pr }}
    uses: pschmitt/android-app-ci/.github/workflows/screenshots-open-pr.yaml@main
    with:
      artifact-label: nyetbox
      # sync-readme: true
      # readme-images: |
      #   01_dashboard|docs/images/readme-dashboard.png|_light_[0-9]*.png
      #   02_device_detail|docs/images/readme-device-detail.png|_light_[0-9]*.png
    secrets: inherit
```

## Just recipes (`just/`)

- **`common.just`** - `format`, `nix-fmt`, `nix-lint`, `screenshots-upload` (with a Play
  &gt;8-screenshots-per-language cap fix). No build-topology assumptions, so every app in the fleet
  imports it, including multi-module jollyfin.
- **`single-module.just`** - the full remote build/deploy pipeline: `sync`/`gradle`/`build`/
  `fetch`/`build-fetch`/`clean`/`lint`/`test` plus the `zenfone-*`/`mipad-*`/`px5-*`/`deploy-all`
  device recipes, parameterized for the `rofl-13`/`rofl-14` remote-build convention, the
  worktree-suffix trick, per-app release signing (or none), and ABI-split-vs-universal APKs.
  Imported by the 3 single-Gradle-module apps (nyetbox, augh, syncwich) - jollyfin is multi-module
  (`app/phone` + `app/tv`) and keeps its own local versions, since `build`/`fetch`/`deploy-*` need
  a module axis this file doesn't have.

Both files are vendored (committed, not gitignored - see "How this gets into an app repo" below)
into each app repo as `.just/common.just` / `.just/single-module.just` and pulled in near the top
of the app's own `justfile`:

```just
import '.just/common.just'
import '.just/single-module.just'   # only the 3 single-module apps
```

`just update-common` (defined in each app's own `justfile`, not in the shared files themselves)
re-fetches both from this repo's `main` on demand.

### How this gets into an app repo

Not a git submodule (submodules interact badly with the fleet's heavy use of parallel git
worktrees for agent-driven work - `git worktree add` doesn't check out submodules by default,
and remembering `--init` per worktree is exactly the kind of friction this repo exists to remove).
Instead: a plain committed copy, refreshed on demand via `curl` (`just update-common` for
`just/*.just`; the GitHub Actions side doesn't need this since `uses: ...@main` always resolves
fresh). This trades automatic freshness for simplicity and diffability - a `just/common.just`
change shows up as a normal, reviewable diff in the app repo's next commit, not silently.

## Nix (`nix/devshells.nix`)

Wired into all 4 apps' `flake.nix` (as a `flake = false` input, `import`ed directly - see the file
's own doc comment for the exact call shape). Validated end-to-end on rofl-13 for all 4:
`nix flake check` and actually entering every devShell (`default`, plus `screenshots` where
applicable) both work.

## What's deliberately *not* centralized here (yet)

- **The `screenshots.yaml` `capture` job** - fixture setup (NetBox/Jellyfin/Mealie docker-compose,
  seed scripts) is genuinely per-app. The KVM-enable step and `android-emulator-runner@v2` `with:`
  block are byte-identical across all 4 apps if you want to copy them by hand; they weren't worth
  a composite action on their own since the surrounding fixture code isn't shareable anyway.
- **`jollyfin`'s remote build/deploy pipeline** - multi-module (`app/phone` + `app/tv`), needs a
  module axis `just/single-module.just` doesn't have. Its `sync`/`clean` are already identical to
  the shared ones in shape, just not extracted - low value on their own without the rest.
- **`AGENTS.md` boilerplate** - the task-tracking convention (`NBC-N`/`AUG-N`/`JF-N`/`SW-N`
  numbered TODO entries), the "never build locally, use `just`" rule, and the physical-device
  section are near-verbatim across repos. Worth extracting to a shared doc each repo's `AGENTS.md`
  links to, not done in this pass.
- **`android-e2e.yaml`/`baseline-profile.yaml`** - nyetbox-only workflows tied to its NetBox
  fixture, not shared by design.
- **`sync-upstream.yaml`** - jollyfin-only (syncs its `findroid` upstream fork), not applicable to
  the other apps.
- **`play-store.yaml`'s two historical shapes** - augh/syncwich previously always published on a
  tag push with no `PLAY_PUBLISH_ENABLED` gate and a slightly different version-code derivation
  (`major*1000000 + minor*1000 + patch` from the tag). This repo's `play-store.yaml` standardizes
  on nyetbox/jollyfin's safer gated design (`app/build.gradle.kts`-derived version by default,
  optional override, explicit publish gate) for all 4 - migrating augh/syncwich onto it is an
  intentional behavior change (they gain the safety gate), not a lossless refactor. jollyfin
  already matches this design but its AAB-locating step uses a glob the reusable workflow doesn't
  support yet.
- **`jollyfin`'s `build.yaml`** - its single Gradle invocation already builds both modules
  together; the shared `build.yaml` assumes one module per call, so calling it twice would rebuild
  everything twice for no benefit.

## Versioning

No tags yet - everything above is pinned `@main` by the 4 apps' migration. Once this settles,
consider cutting `v1` and having callers pin to it instead, so a change here can't silently break
a release pipeline mid-flight.

## License

GPL-3.0-or-later - see [LICENSE](LICENSE).
