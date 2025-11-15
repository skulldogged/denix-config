{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "programs.mpv";

  options.programs.mpv = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    programs.mpv = {
      enable = true;
      scripts = [pkgs.mpvScripts.uosc];
    };
  };
}
