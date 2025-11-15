{
  delib,
  inputs,
  pkgs,
  ...
}:
delib.module {
  name = "programs.quickshell";

  options.programs.quickshell = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    programs.quickshell = {
      enable = true;

      package = inputs.quickshell.packages.${pkgs.system}.default.overrideAttrs (oldAttrs: {
        buildInputs =
          oldAttrs.buildInputs
          ++ (with pkgs; [
            qt6.qt5compat
            kdePackages.syntax-highlighting
          ]);
      });

      systemd = {
        enable = true;
        target = "hyprland-session.target";
      };
    };
  };
}
