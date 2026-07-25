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

    t3CodeNightly = let
      package = inputs.t3code-flake.packages.${system}.t3-code-nightly;
    in
      pkgs.symlinkJoin {
        name = "${package.name}-gnome-libsecret";
        paths = [package];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          rm "$out/bin/t3-code-nightly"
          makeWrapper "${lib.getExe package}" "$out/bin/t3-code-nightly" \
            --add-flags "--password-store=gnome-libsecret"
        '';
      };

    basePackages =
      (with pkgs; [
        alejandra
        claude-code
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
        duf
        equibop
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
      ++ [t3CodeNightly];
  in {
    home.packages = basePackages ++ lib.optionals myconfig.host.isDesktop desktopPackages;

    services.tldr-update = lib.mkIf myconfig.host.isDesktop {
      enable = true;
      package = pkgs.tlrc;
    };
  };
}
