{
  delib,
  inputs,
  pkgs,
  ...
}: let
  codexPackage = inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.codex;
in
  delib.module {
    name = "programs.codex-desktop";

    options.programs.codex-desktop = with delib; {
      enable = boolOption false;
    };

    home.ifEnabled = {
      imports = [inputs.codex-desktop-linux.homeManagerModules.default];

      home.packages = [codexPackage];

      programs.codexDesktopLinux = {
        enable = true;
      };
    };
  }
