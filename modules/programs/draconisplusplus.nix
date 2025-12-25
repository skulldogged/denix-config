{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "programs.draconisplusplus";

  options.programs.draconisplusplus = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {myconfig, ...}: {
    imports = [inputs.draconisplusplus.homeModules.default];

    programs.draconisplusplus = {
      enable = true;

      pluginsSrc = inputs.draconisplusplus-plugins;

      configFormat = "hpp";
      enableCaching = true;
      enablePackageCount = true;
      enablePlugins = true;
      packageManagers = ["nix"];
      staticPlugins = ["now_playing" "weather"];
      username = "Mars";

      layout = [
        {
          name = "intro";
          rows = [
            {key = "date";}
            {key = "plugin.weather";}
          ];
        }
        {
          name = "system";
          rows = [
            {key = "host";}
            {key = "os";}
            {key = "kernel";}
          ];
        }
        {
          name = "hardware";
          rows = [
            {key = "cpu";}
            {key = "gpu";}
            {key = "ram";}
            {key = "disk";}
            {key = "uptime";}
          ];
        }
        {
          name = "software";
          rows = [
            {key = "shell";}
            {key = "packages";}
          ];
        }
        {
          name = "session";
          rows = [
            {key = "de";}
            {key = "wm";}
            {key = "playing";}
          ];
        }
        {
          name = "nowplaying";
          rows = [
            {
              key = "plugin.now_playing";
              autoWrap = true;
              color = "Magenta";
            }
          ];
        }
      ];

      logo = {
        path =
          if myconfig.host.isDesktop
          then ../../files/tiger-cub.gif
          else null;
        protocol = "iterm2";
        width = 200;
        height = 200;
      };

      pluginConfigs = {
        weather = {
          enabled = true;
          provider = "openmeteo";
          units = "imperial";
          coords = {
            lat = 39.953388;
            lon = -74.198151;
          };
        };
      };
    };
  };
}
