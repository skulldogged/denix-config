{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "home.nix-index";

  options.home.nix-index = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    imports = [inputs.nix-index-database.homeModules.nix-index];
    programs.nix-index-database.comma.enable = true;
  };
}
