{
  delib,
  inputs,
  pkgs,
  ...
}:
delib.module {
  name = "programs.codex-desktop";

  options.programs.codex-desktop = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    imports = [inputs.codex-desktop-linux.homeManagerModules.default];

    programs.codexDesktopLinux = {
      enable = true;
      cliPackage = pkgs.codex;
    };
  };
}
