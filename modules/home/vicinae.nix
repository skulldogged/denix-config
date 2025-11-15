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
      autoStart = true;
      useLayerShell = true;

      settings = {
        popToRootOnClose = false;
        faviconService = "twenty";
        font.size = 11;
        theme.name = "catppuccin-mocha";

        window = {
          opacity = 0.95;
          rounding = 10;
        };
      };
    };
  };
}
