# nix-config

Modular NixOS / Home Manager / nix-darwin configuration built with
[Denix](https://github.com/yunfachi/denix).

## Hosts

| Host     | System         | Type    | Notes                                                        |
| -------- | -------------- | ------- | ------------------------------------------------------------ |
| `navis`  | x86_64-linux   | desktop | Hyprland, impermanence (btrfs wipe), LUKS+TPM2, secure boot  |
| `polaris`| x86_64-linux   | server  | media/stack services, Forgejo, Home Assistant, ingress/VPN   |
| `canis`  | aarch64-darwin | laptop  | MacBook Air                                                  |

## Layout

```
flake.nix    # inputs, denix configurations, formatter/checks (treefmt), devShell
hosts/       # per-host config; host-specific modules live in hosts/<name>/modules/
modules/     # shared modules:
  config/    #   cross-cutting concerns (constants, user, nixpkgs overlay, home)
  system/    #   NixOS/darwin system modules (myconfig.system.*)
  home/      #   Home Manager modules (myconfig.home.*)
  programs/  #   program modules (myconfig.programs.*)
rices/       # theme bundles (delib.rice), e.g. catppuccin-mocha
pkgs/        # custom packages, exposed to modules as pkgs.local.* (overlay)
secrets/     # sops-nix secrets (.sops.yaml + per-host yaml)
files/       # static assets referenced by modules
```

Everything under `hosts/`, `modules/`, and `rices/` is auto-discovered by
Denix — new files just need to be tracked by git (flakes ignore untracked
files; `git add` them before evaluating).

## Daily use

```sh
nix develop   # enter the dev shell
build         # nix fmt + nh os|darwin switch
up            # nix flake update
nix fmt       # format + deadnix (treefmt: alejandra, stylua, taplo, jsonfmt)
nix flake check
```

## Adding things

**Module** — create `modules/<area>/<name>.nix`:

```nix
{delib, ...}:
delib.module {
  name = "programs.foo";

  options.programs.foo = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    # ...
  };
}
```

then enable it per host in `hosts/<name>/default.nix` with
`myconfig.programs.foo.enable = true;`.

**Host** — create `hosts/<name>/default.nix` with a `delib.host` block
(mirror an existing host), then add the name to the `getAttrs` list for its
module system in `flake.nix`. Host-specific NixOS config goes in
`hosts/<name>/modules/` as `delib.module`s gated on the host's enable option
(see `hosts/polaris/modules/base.nix` for the pattern).

**Custom package** — add `pkgs/<name>/package.nix` (standard `callPackage`
style) and register it in the overlay in `modules/config/nixpkgs.nix`; use it
as `pkgs.local.<name>`.

## Secrets

Secrets are managed with [sops-nix](https://github.com/Mic92/sops-nix). Each
host has `secrets/<host>.yaml`, encrypted per the rules in
`secrets/.sops.yaml`. To edit:

```sh
sops secrets/navis.yaml
```

You need an age identity matching one of the file's recipients (see
`.sops.yaml`). Hosts decrypt at activation using their SSH host key
via sops-nix's `age.sshKeyPaths`. On impermanent hosts, configure the key's
persistent backing path (for navis,
`/persist/etc/ssh/ssh_host_ed25519_key`) because activation runs before the
`/etc/ssh` bind mount is established.
