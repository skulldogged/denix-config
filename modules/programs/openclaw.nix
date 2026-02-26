{
  delib,
  pkgs,
  inputs,
  ...
}:
delib.module {
  name = "programs.openclaw";

  options.programs.openclaw = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    environment.systemPackages = [
      pkgs.chromium
    ];
  };

  home.ifEnabled = {
    home.packages = [inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system}.default];
  };
}
