{
  delib,
  inputs,
  pkgs,
  ...
}:
delib.module {
  name = "programs.draconisplusplus";

  options.programs.draconisplusplus = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {...}: {
    imports = [inputs.draconisplusplus.homeModules.default];

    programs.draconisplusplus = {
      enable = true;

      configFormat = "hpp";

      enableCaching = true;
      enablePackageCount = true;
      enablePlugins = true;
      packageManagers = ["nix"];
      pluginPackages = [
        (inputs.draconisplusplus-plugins.lib.${pkgs.system}.mkPluginRoot {
          weather = {
            provider = "openmeteo";
            units = "imperial";
            coords = {
              lat = 39.953388;
              lon = -74.198151;
            };
          };
        })
        inputs.draconisplusplus-plugin-lab.packages.${pkgs.system}.all
      ];
      staticPlugins = [
        "container_info"
        "json_format"
        "markdown_format"
        "now_playing"
        "vpn_info"
        "weather"
        "yaml_format"
      ];
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
            {key = "plugin.vpn_info";}
            {key = "plugin.container_info";}
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
        path = ../../files/tiger-cub.gif;
        protocol = "iterm2";
        width = 200;
        height = 200;
      };
    };
  };
}
