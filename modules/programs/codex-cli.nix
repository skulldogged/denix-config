{
  delib,
  inputs,
  pkgs,
  ...
}: let
  codexPackage = inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.codex;
in
  delib.module {
    name = "programs.codex-cli";

    options.programs.codex-cli = with delib; {
      enable = boolOption false;
    };

    home.ifEnabled = {
      home.packages = [codexPackage];
    };
  }
