{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "home.wezterm";

  options.home.wezterm = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = { ...}: {
    programs.wezterm = {
      enable = true;
      extraConfig =
        if pkgs.stdenv.isDarwin
        then builtins.readFile ../../files/wezterm/wezterm-darwin.lua
        else builtins.readFile ../../files/wezterm/wezterm.lua;
    };
  };
}
