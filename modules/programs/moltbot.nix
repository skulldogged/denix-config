{
  delib,
  pkgs,
  inputs,
  ...
}:
delib.module {
  name = "programs.moltbot";

  options.programs.moltbot = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    environment.systemPackages = [
      pkgs.chromium
    ];
  };

  home.ifEnabled = {
    home.packages = [inputs.nix-moltbot.packages.${pkgs.system}.default];
  };
}
