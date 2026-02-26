{
  delib,
  inputs,
  pkgs,
  lib,
  ...
}:
delib.module {
  name = "programs.linux-wallpaperengine";

  options.programs.linux-wallpaperengine = with delib; {
    enable = boolOption false;

    assetsDir =
      description
      (readOnly (noDefault (strOption null)))
      "Path to wallpaper engine assets directory";

    wallpaperPath =
      description
      (readOnly (noDefault (strOption null)))
      "Path to wallpaper (can be a Nix store path or system path)";

    screen =
      description
      (strOption "")
      "Screen to use (e.g., DP-1). Empty for auto-detect.";

    extraArgs =
      description
      (listOfOption str [])
      "Extra arguments to pass to linux-wallpaperengine";
  };

  home.ifEnabled = {myconfig, ...}: let
    cfg = myconfig.programs.linux-wallpaperengine;

    # Override linux-wallpaperengine to use latest source from flake input
    linux-wallpaperengine = pkgs.linux-wallpaperengine.overrideAttrs (_old: {
      version = "0-unstable-${inputs.linux-wallpaperengine-src.lastModifiedDate or "latest"}";
      src = inputs.linux-wallpaperengine-src;
    });

    extraArgsStr = lib.concatStringsSep " " cfg.extraArgs;

    startScript = pkgs.writeShellScript "linux-wallpaperengine-start" ''
      # Auto-detect screen if not specified
      ${
        if cfg.screen != ""
        then ''SCREEN="${cfg.screen}"''
        else ''
          SCREEN=$(${pkgs.wlr-randr}/bin/wlr-randr 2>/dev/null | grep -E '^[A-Za-z]' | head -1 | cut -d' ' -f1)
          if [ -z "$SCREEN" ]; then
            SCREEN=$(${pkgs.xrandr}/bin/xrandr 2>/dev/null | grep ' connected primary' | cut -d' ' -f1)
          fi
          if [ -z "$SCREEN" ]; then
            SCREEN=$(${pkgs.xrandr}/bin/xrandr 2>/dev/null | grep ' connected' | head -1 | cut -d' ' -f1)
          fi
          if [ -z "$SCREEN" ]; then
            SCREEN="DP-1"
          fi
        ''
      }

      exec ${linux-wallpaperengine}/bin/linux-wallpaperengine \
        --assets-dir "${cfg.assetsDir}" \
        "${cfg.wallpaperPath}" \
        --screen-root "$SCREEN" \
        ${extraArgsStr}
    '';
  in {
    home.packages = [linux-wallpaperengine];

    systemd.user.services.linux-wallpaperengine = {
      Unit = {
        Description = "Linux Wallpaper Engine";
        After = ["hyprland-session.target"];
        PartOf = ["hyprland-session.target"];
      };

      Service = {
        Type = "simple";
        ExecStart = "${startScript}";
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install = {
        WantedBy = ["hyprland-session.target"];
      };
    };
  };
}
