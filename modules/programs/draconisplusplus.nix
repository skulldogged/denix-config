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

  home.ifEnabled = {myconfig, ...}: let
    system = pkgs.stdenv.hostPlatform.system;
  in {
    imports = [inputs.draconisplusplus.homeModules.default];

    programs.draconisplusplus = {
      enable = true;

      configFormat = "hpp";
      enableCaching = true;
      enablePackageCount = true;
      enablePlugins = true;
      packageManagers = ["nix"];
      pluginMode = "static";
      username = "Mars";

      pluginPackages = [
        (inputs.draconisplusplus-plugins.lib.${system}.mkPluginRoot {
          plugins = {
            json_format = true;
            markdown_format = true;
            now_playing = true;
            weather = {
              enable = true;
              settings = {
                provider = "openmeteo";
                units = "imperial";
                coords = {
                  lat = 39.953388;
                  lon = -74.198151;
                };
              };
            };
            yaml_format = true;
          };
        })
        (inputs.draconisplusplus-plugin-lab.lib.${system}.mkPluginRoot {
          plugins = {
            vpn_info = true;
            container_info = {
              enable = myconfig.host.isServer;
              settings.backends = ["podman"];
            };
          };
        })
      ];

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
          rows =
            [
              {key = "de";}
              {key = "wm";}
              {key = "plugin.vpn_info";}
            ]
            ++ pkgs.lib.optional myconfig.host.isServer {key = "plugin.container_info";};
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
