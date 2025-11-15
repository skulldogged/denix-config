{
  delib,
  pkgs,
  inputs,
  ...
}:
delib.module {
  name = "home.packages";

  options.home.packages = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = let
    windsurfInfo =
      (pkgs.lib.importJSON ../packages/windsurf/info.json)."${pkgs.stdenv.hostPlatform.system}"
        or (throw "windsurf: unsupported system ${pkgs.stdenv.hostPlatform.system}");
  in {
    home.packages =
      (with pkgs; [
        alejandra
        bitwarden-cli
        bitwarden-desktop
        claude-code
        distrobox_git
        duf
        equibop
        glow
        grc
        jellyfin-tui
        killall
        libnotify
        lm_sensors
        loupe
        meteor-git
        moonlight-qt
        mullvad-vpn
        nicotine-plus
        nodejs
        obsidian
        playerctl
        ryubing
        statix
        tlrc
        translate-shell
        uv

        inputs.nixvim.packages.${system}.default
      ])
      ++ [
        (pkgs.windsurf.overrideAttrs (oldAttrs: {
          inherit (windsurfInfo) version;
          src = pkgs.fetchurl {
            inherit (windsurfInfo) url sha256;
          };
          passthru =
            oldAttrs.passthru
            // {
              inherit (windsurfInfo) vscodeVersion;
            };
        }))
      ];

    services.tldr-update = {
      enable = true;
      package = pkgs.tlrc;
    };
  };
}
