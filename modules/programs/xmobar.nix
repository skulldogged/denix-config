{delib, ...}:
delib.module {
  name = "programs.xmobar";

  options.programs.xmobar = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    programs.xmobar.enable = true;
  };
}
