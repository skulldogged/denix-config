# Personal T3 Code release channel

Builder checks published official T3 Code nightly releases every three hours. It merges the latest published nightly tag into the personal branch in `skulldogged/t3code`, dispatches `personal-release.yml` from fork `main`, and waits for the builds to pass. Releases preserve the official nightly version and append `.personal.REVISION`, starting at 1 for each nightly. For example, official `v0.0.39-nightly.20260905.1289` becomes `personal-v0.0.39-nightly.20260905.1289.personal.1`. Personal changes cover Android background connections, notifications, Catppuccin Mocha, and release infrastructure. Pi and subscription-limit patches are not included. Dispatching from one stable ref lets GitHub reuse Gradle and compiler caches between Android builds. The workflow builds:

- the Linux AppImage;
- the unsigned Windows NSIS installer and updater metadata;
- the preview Android APK;
- the server package.

After all checks and builds pass, Builder verifies the release checksums, deploys Polaris and Canis, updates the Navis Nix pin in `denix-config`, and switches Builder last. The Linux switches use the T3 service launcher's trial-and-rollback protocol. The Canis launchd switch keeps a plist backup and restores it if the new server does not become healthy.

Only published official nightly tags are tracked, not upstream main or PR heads. Official builds are scheduled at `38 */3 * * *` UTC; Builder checks at 01:20, 04:20, 07:20, 10:20, 13:20, 16:20, 19:20, and 22:20 UTC, with up to ten minutes of jitter. An unchanged source does not rebuild. During the initial transition, publication waits until a nightly contains the upstream commits previously merged into the fork. A merge conflict stops the run without changing the running fleet. Git rerere records reviewed resolutions. The health probe groups unresolved merge conflicts into one stable incident, and Personal Agent suppresses further actionable alerts while an earlier approval is pending.

## Builder

Keep the T3 fork's documentation identical to the tracked official nightly, including app READMEs.
Personal setup and maintenance notes belong here instead of in the T3 repository. Android background
connections, notification channels, promoted live updates, and bundled Catppuccin Mocha remain personal
code changes; removing their fork documentation does not remove those features.

Install the user timer once:

```sh
./tools/t3code-channel/install-builder.sh
```

Run an update immediately:

```sh
systemctl --user start t3code-channel-update.service
journalctl --user -fu t3code-channel-update.service
```

The durable state and downloaded releases live in `~/.local/state/t3code-channel`. Failed builds do
not advance `state.json`. A successful build records its version before fleet deployment.
Rebuilds of the same nightly use the next personal revision after the highest existing release tag.
If deployment is interrupted, state remains pending and the same release is retried when the source
has not changed. A new official nightly starts again at `.personal.1`. The switch from the old
independent patch counter lowers the base version; clients that reject downgrades may need a one-time
manual installation. Subsequent versions follow upstream ordering.

`health.json` records the updater's current stage, source commits, workflow URL, and either a healthy,
blocked, or failed condition. `health-check.mjs` converts that file into Personal Agent's
transition-aware `status_check` protocol. It also reports a problem if the hourly updater has not
refreshed the file in seven hours (allowing for the three-hour polling interval and build time).

## Clients

Windows and writable AppImage installs use the release feed embedded at build time: `skulldogged/t3code`. The installer is unsigned, so Windows may show SmartScreen on first install.

For Android, add this URL to Obtainium once:

```text
https://github.com/skulldogged/t3code
```

Select the APK ending in `-preview.apk`. Each workflow run uses a larger Android version code, so updates install over the previous preview build. Personal preview APKs target `arm64-v8a`, which covers the Pixel fleet while avoiding unused x86 and 32-bit native builds.

Navis remains Nix-managed. Each successful fleet release pushes a small `modules/home/t3code-release.json` update to `denix-config`; Navis only needs to pull and rebuild. A separate auto-rebuild policy can be added later if every `denix-config` main commit is safe to apply unattended.

## Recovery patches

`patches/` contains historical Pi-era recovery artifacts, not the current patch set. Do not replay them to reconstruct the current fork. The fork's Git history records the removal of Pi and subscription limits; normal scheduled runs advance that branch by merging official nightly tags.
