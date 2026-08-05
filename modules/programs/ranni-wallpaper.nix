{
  delib,
  pkgs,
  lib,
  ...
}:
delib.module {
  name = "programs.ranni-wallpaper";

  options.programs.ranni-wallpaper = with delib; {
    enable = boolOption false;

    scenePackage =
      description
      (readOnly (noDefault (strOption null)))
      "Path to the installed Wallpaper Engine scene.pkg";

    engineAssetsRoot =
      description
      (readOnly (noDefault (strOption null)))
      "Path to the installed Wallpaper Engine assets directory";

    renderNode =
      description
      (strOption "/dev/dri/by-path/pci-0000:00:02.0-render")
      "Stable DRM render-node path for the Intel GPU";
  };

  home.ifEnabled = {myconfig, ...}: let
    cfg = myconfig.programs.ranni-wallpaper;
    package = pkgs.local.ranni-wallpaper;
    command = lib.escapeShellArgs [
      (lib.getExe package)
      cfg.renderNode
      "--scene-pkg"
      cfg.scenePackage
      "--engine-assets"
      cfg.engineAssetsRoot
    ];
  in {
    home.packages = [package];

    systemd.user.services.ranni-wallpaper = {
      Unit = {
        Description = "Ranni wallpaper renderer";
        After = ["hyprland-session.target"];
        PartOf = ["hyprland-session.target"];
      };

      Service = {
        Type = "simple";
        ExecStart = command;
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
      };

      Install.WantedBy = ["hyprland-session.target"];
    };
  };
}
