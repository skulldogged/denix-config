# Personal T3 Code release channel

Builder checks upstream hourly. When `pingdotgg/t3code` main changes, it merges main into the personal branch in `skulldogged/t3code`, dispatches the release workflow from fork `main`, and waits for GitHub Actions to publish a monotonically versioned `pi-v...` release. The legacy tag prefix and `.pi.` version component are retained for compatibility with installed clients; the fork no longer includes Pi integration or subscription-limit reporting. Personal changes cover Android background connections, notifications, Catppuccin Mocha, and release infrastructure. Dispatching from one stable ref lets GitHub reuse Gradle and compiler caches between Android builds. The workflow builds:

- the Linux AppImage;
- the unsigned Windows NSIS installer and updater metadata;
- the preview Android APK;
- the server package.

After all checks and builds pass, Builder verifies the release checksums, deploys Polaris and Canis, updates the Navis Nix pin in `denix-config`, and switches Builder last. The Linux switches use the T3 service launcher's trial-and-rollback protocol. The Canis launchd switch keeps a plist backup and restores it if the new server does not become healthy.

Only upstream main is tracked; PR #5882 is no longer fetched or gated. A merge conflict stops the run without changing the running fleet. Git rerere records reviewed conflict resolutions so equivalent conflicts can be reused. The health probe groups unresolved merge conflicts into one stable incident, and Personal Agent suppresses further actionable alerts while an earlier approval is pending.

## Builder

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
not advance `state.json`. A successful build advances the release sequence before fleet deployment,
and the highest published tag is also used as a sequence floor. If deployment is interrupted, the
state remains pending and the same release is retried when the source has not changed. A newer source
always receives a larger numeric version, even when the previous deployment did not reach every
machine.

`health.json` records the updater's current stage, source commits, workflow URL, and either a healthy,
blocked, or failed condition. `health-check.mjs` converts that file into Personal Agent's
transition-aware `status_check` protocol. It also reports a problem if the hourly updater has not
refreshed the file in three hours.

## Clients

Windows and writable AppImage installs use the release feed embedded at build time: `skulldogged/t3code`. The installer is unsigned, so Windows may show SmartScreen on first install.

For Android, add this URL to Obtainium once:

```text
https://github.com/skulldogged/t3code
```

Select the APK ending in `-preview.apk`. Each workflow run uses a larger Android version code, so updates install over the previous preview build. Personal preview APKs target `arm64-v8a`, which covers the Pixel fleet while avoiding unused x86 and 32-bit native builds.

Navis remains Nix-managed. Each successful fleet release pushes a small `modules/home/t3code-release.json` update to `denix-config`; Navis only needs to pull and rebuild. A separate auto-rebuild policy can be added later if every `denix-config` main commit is safe to apply unattended.

## Recovery patches

`patches/` contains historical Pi-era recovery artifacts, not the current patch set. Do not replay them to reconstruct the current fork. The fork's Git history records the removal of Pi and subscription limits; normal scheduled runs advance that branch by merging upstream main.
