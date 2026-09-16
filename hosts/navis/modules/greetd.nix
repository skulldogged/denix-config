{
  delib,
  inputs,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "navis";

  home.ifEnabled.wayland.windowManager.hyprland.settings.monitor = lib.mkForce [
    {
      output = "eDP-1";
      disabled = true;
    }
    {
      output = "desc:LG Electronics LG ULTRAGEAR 411BOYQ05442";
      mode = "2560x1440@180";
      position = "0x0";
      scale = 1;
    }
  ];

  nixos.ifEnabled = let
    package = import ../../../packages/navis-hyprland-preserve {inherit pkgs inputs;};
    session = pkgs.writeShellScript "navis-hyprland-session" ''
      if [ -f /persist/var/lib/navis-hyprland-preserve/disabled ]; then
        exec ${inputs.hyprland.packages.x86_64-linux.hyprland}/bin/start-hyprland
      fi
      exec ${package}/bin/start-hyprland
    '';
  in {
    programs.hyprland.package = lib.mkForce package;
    environment.etc."navis-hyprland-preserve".source = package;
    environment.etc."navis-hyprland-stock".source = inputs.hyprland.packages.x86_64-linux.hyprland;
    environment.etc."navis-hyprland-session".source = session;
    systemd.tmpfiles.rules = ["d /persist/var/lib/navis-hyprland-preserve 0755 root root -"];
    services.greetd = {
      enable = true;
      settings = rec {
        initial_session = {
          command = "/etc/navis-hyprland-session";
          user = "marshall";
        };
        default_session = initial_session;
      };
    };
  };
}
