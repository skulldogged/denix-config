{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "home.beets";

  options.home.beets = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {myconfig, ...}: let
    inherit (myconfig.constants) username;
    homeDirectory =
      if pkgs.stdenv.isDarwin
      then "/Users/${username}"
      else "/home/${username}";
  in {
    programs.beets = {
      enable = true;

      settings = {
        directory = "/mnt/music";
        library = "${homeDirectory}/.local/share/beets/library.db";

        import = {
          move = true;
          write = true;
        };

        plugins = ["inline" "fetchart"];

        item_fields = {
          artist = "artists";
        };
      };
    };
  };
}
