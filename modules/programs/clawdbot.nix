{
  delib,
  pkgs,
  inputs,
  ...
}:
delib.module {
  name = "programs.clawdbot";

  options.programs.clawdbot = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    home.packages = [inputs.nix-clawdbot.packages.${pkgs.system}.default];
  };
}
