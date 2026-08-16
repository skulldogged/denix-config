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
      # pingdotgg/t3code main fee10def with PR #5882 and local Pi client fixes through 8c06b768.
      version = "0.0.39-mainfee10def.pi.8c06b768";
      appImage = pkgs.fetchurl {
        url = "https://github.com/skulldogged/denix-config/releases/download/t3code-${version}/T3-Code-${version}-x86_64.AppImage";
        hash = "sha256-XJtMC0diUFjEF9QhCr8CyWhwkyOVvIDKVUz2S/q/0hA=";
      };
      package = inputs.t3code-flake.packages.${system}.t3-code-nightly.overrideAttrs {
        inherit version;
        src = pkgs.appimageTools.extract {
          pname = "t3-code-nightly";
          inherit version;
          src = appImage;
        };
      };
    in
      pkgs.symlinkJoin {
        name = "${package.name}-gnome-libsecret";
        paths = [package];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          rm "$out/bin/${package.meta.mainProgram}"
          makeWrapper "${lib.getExe package}" "$out/bin/${package.meta.mainProgram}" \
            --add-flags "--password-store=gnome-libsecret"

          # T3 Code registers OAuth callbacks against t3code.desktop. Keep
          # that identity and advertise its custom URI scheme to XDG.
          rm "$out/share/applications/t3-code-nightly.desktop"
          install -Dm644 \
            "${package}/share/applications/t3-code-nightly.desktop" \
            "$out/share/applications/t3code.desktop"
          echo 'MimeType=x-scheme-handler/t3code;' \
            >> "$out/share/applications/t3code.desktop"
        '';
      };

    basePackages =
      (with pkgs; [
        alejandra
        claude-code
        file
        grc
        grok-build
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
