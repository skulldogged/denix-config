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

  nixos.ifEnabled = _: {
    programs.chromium.enable = true;
  };

  home.ifEnabled = _: {
    home.packages = [inputs.nix-clawdbot.packages.${pkgs.system}.default];
  };
}
