{
  delib,
  inputs,
  ...
}:
delib.rice {
  name = "catppuccin-mocha";

  nixos = {
    imports = [inputs.catppuccin.nixosModules.catppuccin];

    catppuccin = {
      autoEnable = true;
      enable = true;
      cache.enable = true;
      flavor = "mocha";
      accent = "green";
    };
  };

  home = {
    imports = [
      inputs.catppuccin.homeModules.catppuccin
      inputs.nix-colors.homeManagerModules.default
    ];

    catppuccin = {
      autoEnable = true;
      enable = true;
      flavor = "mocha";
      accent = "green";
      cursors.enable = true;
      kvantum.enable = false;
    };

    colorScheme = inputs.nix-colors.colorSchemes.catppuccin-mocha;

    home.pointerCursor.enable = true;

    gtk.enable = true;

    qt = {
      enable = true;
      platformTheme.name = "kde";
    };

    xdg.enable = true;
  };
}
