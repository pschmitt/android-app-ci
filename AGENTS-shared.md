# Shared AGENTS.md conventions for the Android app fleet

Pulled in as a git submodule at `.just/android-app-ci` in each app repo (see this repo's README).
Each app's own `AGENTS.md` references the relevant section(s) below instead of repeating them -
read this file too, not just the app's own `AGENTS.md`. Sections an app doesn't use (e.g. a
physical device it has no recipes for) don't apply to it; its own `AGENTS.md` says which do.

## Task tracking

- `TODO.md` is the running backlog/changelog for this project, one `## <PREFIX>-N:` entry per
  feature or fix (see the app's own `AGENTS.md` for its exact prefix), numbered sequentially
  (never reuse or renumber an id). Each entry has a checklist of sub-items (`- [ ]`/`- [x]`) and
  ends with a `Status:` line (`not started` / `in progress` / `mostly done` / `**done**`, plus a
  date and how it was verified).
- Before starting any non-trivial new feature or fix, add (or update) a `<PREFIX>-N` entry
  describing it - even if the same conversation immediately goes on to implement it. Update the
  checklist/status as work actually lands, rather than writing the whole entry retroactively once
  everything's finished. This keeps `TODO.md` an accurate record of what's done vs. still open,
  and lets another agent (or a future you) resume the work cold from just this file.
- Trivial one-off asks (a typo, a single-line tweak) don't need their own entry.

## Dev environment

- `nix develop` provides the full toolchain (JDK 21, Android SDK, `just`, `ktfmt`) and installs
  the repo's pre-commit hooks (see `flake.nix`'s `git-hooks.nix` integration, wired through
  `nix/devshells.nix` in this repo - trailing whitespace, EOF fixer, merge-conflict/large-file
  checks, `nixfmt`, `statix`). The generated `.pre-commit-config.yaml` is gitignored - it's
  regenerated from `flake.nix` on every shell entry, don't hand-edit it.
  - Deliberately **no** `ktfmt` pre-commit hook: nixpkgs only ships a recent standalone `ktfmt`,
    but each app's Gradle plugin pins an older `ktfmt` (see its `gradle/libs.versions.toml`), and
    the two format some constructs differently - a hook running the wrong version could "fix" a
    file into a state that then fails CI's real `ktfmtCheck`. Confirmed live on jollyfin: it once
    inserted spurious blank lines between every `include()` in `settings.gradle.kts`. Use
    `just lint` (runs the pinned Gradle plugin remotely) as the authoritative check - `just
    format` is a quick local pass, but treat its output as advisory, not final (see below).
- Prefer the `justfile` recipes over raw `./gradlew`/`ssh`/`adb` invocations - run `just --list`
  for the full set. `nix develop`'s shellHook also auto-runs `git submodule update --init` on
  every entry, so a fresh git worktree (this fleet creates plenty for agent-driven work) never
  needs a manual submodule init step before `just` works.

## Builds

- **Never run Gradle builds locally on this machine** - always build on `rofl-13.brkn.lol` or
  `rofl-14.brkn.lol` instead (see the app's own `justfile`/`AGENTS.md` for its exact recipe names
  and any module-specific flags).
- **CI is the sole authority on lint/format, full stop - not `just lint`, not `just format`, not
  local judgment.** Confirmed the hard way more than once: a change that passed a local/remote
  check still failed CI's `Lint` job after being pushed. If CI's `Lint` job fails:
  - `.github/workflows/lint.yaml`'s `ktfmt` job auto-uploads a `ktfmt-diff-patch` artifact
    whenever `ktfmtCheck` fails - on any trigger, push/PR or manual (`gh workflow run
    lint.yaml` to get one preemptively). It contains exactly what `./gradlew ktfmtFormat` would
    change, computed in the same environment CI's `ktfmtCheck` uses. Grab it with
    `gh run download <run-id> -n ktfmt-diff-patch` and apply it (`git apply`) rather than
    guessing or reformatting by hand.
  - Fix every lint/format violation CI reports before calling a change done, even in files the
    current change didn't touch or author - don't scope a fix to "only the lines I changed" if CI
    flags something adjacent. Never disable, skip, or baseline around a lint failure to make it
    go away; fix the actual violation.
  - `just format` runs the local `ktfmt` CLI over *every* tracked `.kt`/`.kts` file in the repo,
    not just the ones a change touched - combined with the local/CI ktfmt version drift above,
    this can silently reformat (and sometimes visibly worsen the formatting of) dozens of
    unrelated files in one run. Diff-review its output before committing; `git checkout --
    <file>` anything it touched outside the actual change, don't assume every file it modified
    was an intended fix.
- Never tag a release from a commit whose CI hasn't gone green on that exact commit's SHA - not
  an assumption, not an older green run. `gh run list --branch main --limit 5` (check the commit
  SHA column) or `gh run list --commit <sha>`. If a tag was already pushed and CI on it fails,
  delete the tag (`git push origin :refs/tags/<tag>`) and recreate it once a fixed commit is
  fully green - never leave a released tag pointing at a red build.

## Physical test devices

Whichever of these an app's `justfile` has recipes for (see its own `AGENTS.md`) - same physical
hardware across the whole fleet, so the connection details and gotchas below are identical
regardless of which app you're testing.

- **Zenfone 10** (`arm64-v8a`), connected directly over USB to this machine's adb:
  `just zenfone-install <apk>`, `just zenfone-uninstall [pkg]`, `just zenfone-logcat [filter]`,
  `just deploy-zenfone [variant]` (build + fetch + install in one step).
- **Mi Pad 4** (`arm64-v8a`, rooted), reachable via SSH at `mi-pad-4.lan` port `8022` (Termux).
  Recipes go through `just mipad-connect` first (finds the port `adbd` is listening on via a root
  SSH shell, `adb connect`s to it - only falls back to forcing `adbd` on via
  `setprop service.adb.tcp.port` if nothing is listening): `just mipad-install <apk>`,
  `just mipad-uninstall [pkg]`, `just mipad-logcat [filter]`, `just deploy-mipad [variant]`.
  Deliberately built on real `adb install` rather than `scp` into `/sdcard` + `pm install`:
  `system_server` can't read the FUSE-backed `/sdcard` back (SELinux denies it), and Termux's
  `sshd` has no `sftp-server` subsystem configured anyway.
- **Pixel 5** (`arm64-v8a`, codename `redfin`), wireless adb at `px5.lan` - not always listening,
  enabled on demand via `zhj adb::connect px5.lan` (triggers wireless debugging through Home
  Assistant/Tasker on the phone). The port changes every time it's (re)enabled, so
  `just px5-connect` always re-discovers it from `adb devices` rather than assuming a fixed one.
  `just px5-install <apk>`, `just px5-uninstall [pkg]`, `just px5-logcat [filter]`,
  `just deploy-px5 [variant]`.
- **Deploy to every device an app targets**, not just one, after landing a verified change
  (compiled, tested, lint-checked remotely): `just deploy-all [variant]` builds, fetches, and
  installs on every named device in one step. Only target a single device
  (`just deploy-zenfone`/`deploy-mipad`/`deploy-px5`) when there's a specific reason to, e.g.
  reproducing a device-specific bug.
- Signature mismatch gotcha: if a device already has a build signed with a different key than the
  one you're installing, install fails with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Fix is
  `just <device>-uninstall` then install fresh - this wipes local app data (Room DB cache, stored
  credentials/tokens). Confirm with the user before doing this if it's not their own throwaway
  data.
