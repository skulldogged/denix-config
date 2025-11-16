{
  delib,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "home";

  home.always = {myconfig, ...}: let
    inherit (myconfig.constants) username;
  in {
    home = {
      inherit username;

      homeDirectory =
        if pkgs.stdenv.isDarwin
        then "/Users/${username}"
        else "/home/${username}";
    };

    xdg = {
      enable = true;
      userDirs = {
        enable = true;
        music = lib.mkIf myconfig.host.isDesktop "/mnt/music";
      };
    };
  };
}
