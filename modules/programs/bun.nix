{delib, ...}:
delib.module {
  name = "programs.bun";

  options.programs.bun = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled.programs.bun = {
    enable = true;
    settings.install.minimumReleaseAge = 604800;
  };
}
