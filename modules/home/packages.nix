{
  delib,
  pkgs,
  inputs,
  lib,
  ...
}:
delib.module {
  name = "home.packages";

  options.home.packages = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {myconfig, ...}: let
    inherit (pkgs.stdenv.hostPlatform) system;

    windsurfInfo =
      (pkgs.lib.importJSON ../packages/windsurf/info.json)."${system}"
        or (throw "windsurf: unsupported system ${system}");

    windsurfPackage = pkgs.windsurf.overrideAttrs (oldAttrs: {
      inherit (windsurfInfo) version;
      src = pkgs.fetchurl {
        inherit (windsurfInfo) url sha256;
      };
      passthru =
        oldAttrs.passthru
        // {
          inherit (windsurfInfo) vscodeVersion;
        };
    });

    equibopPackage = pkgs.callPackage ../../pkgs/equibop/package.nix {};

    basePackages =
      (with pkgs; [
        alejandra
        bun
        codex
        file
        grc
        mullvad-vpn
        wl-clipboard
        xclip
      ])
      ++ [inputs.nixvim.packages.${system}.default];

    desktopPackages =
      (with pkgs; [
        bitwarden-cli
        bitwarden-desktop
        claude-code
        distrobox_git
        duf
        glow
        jellyfin-tui
        killall
        libnotify
        lm_sensors
        loupe
        meteor-git
        moonlight-qt
        nicotine-plus
        nodejs
        obsidian
        playerctl
        ryubing
        statix
        telegram-desktop
        tlrc
        translate-shell
        uv
      ])
      ++ [windsurfPackage equibopPackage];
  in {
    home.packages = basePackages ++ lib.optionals myconfig.host.isDesktop desktopPackages;

    services.tldr-update = lib.mkIf myconfig.host.isDesktop {
      enable = true;
      package = pkgs.tlrc;
    };
  };
}
