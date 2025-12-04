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

  home.ifEnabled = {
    imports = [inputs.draconisplusplus.homeModules.default];

    programs.draconisplusplus = {
      enable = true;

      configFormat = "hpp";
      enableCaching = true;
      enablePackageCount = true;
      enablePlugins = true;
      packageManagers = ["cargo" "nix"];
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
