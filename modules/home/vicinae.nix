{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "home.vicinae";

  options.home.vicinae = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    imports = [
      inputs.vicinae.homeManagerModules.default
    ];

    services.vicinae = {
      enable = true;

      systemd = {
        enable = true;
        autoStart = true;

        environment = {
          USE_LAYER_SHELL = true;
        };
      };

      settings = {
        launcher_window.opacity = 0.95;

        theme.dark = {
          name = "catppuccin-mocha";
          icon_theme = "default";
        };
      };
    };
  };
}
