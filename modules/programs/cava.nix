{delib, ...}:
delib.module {
  name = "programs.cava";

  options.programs.cava = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    programs.cava.enable = true;
  };
}
