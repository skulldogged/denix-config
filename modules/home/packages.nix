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

    equibopPackage = pkgs.callPackage ../../pkgs/equibop/package.nix {};

    basePackages =
      (with pkgs; [
        alejandra
        bun
        claude-code
        codex
        file
        grc
      ])
      ++ lib.optionals pkgs.stdenv.isLinux (with pkgs; [
        mullvad-vpn
        wl-clipboard
        xclip
      ])
      ++ [inputs.nixvim.packages.${system}.default];

    desktopPackages =
      (with pkgs; [
        bitwarden-cli
        bitwarden-desktop
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
      ++ [equibopPackage];
  in {
    home.packages = basePackages ++ lib.optionals myconfig.host.isDesktop desktopPackages;

    services.tldr-update = lib.mkIf myconfig.host.isDesktop {
      enable = true;
      package = pkgs.tlrc;
    };
  };
}
