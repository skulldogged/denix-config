{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "programs.caelestia-shell";

  options.programs.caelestia-shell = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    imports = [inputs.caelestia-shell.homeManagerModules.default];

    programs.caelestia = {
      enable = true;
      cli.enable = true;

      settings = {
        appearance.font.family = {
          sans = "Rubik";
          mono = "Maple Mono NF";
        };

        bar.status.showBattery = false;

        general.apps = {
          terminal = ["wezterm"];
          explorer = ["nautilus"];
          playback = ["mpv"];
        };

        services = {
          weatherLocation = "39.953388,-74.198151";
          useFahrenheit = true;
          defaultPlayer = "Jellyfin";
        };
      };

      systemd = {
        enable = true;
        target = "hyprland-session.target";
      };
    };
  };
}
