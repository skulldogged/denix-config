{
  delib,
  lib,
  ...
}:
delib.module {
  name = "home.shell";

  options.home.shell = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    programs = {
      bat.enable = true;
      btop.enable = true;
      fd.enable = true;
      git-cliff.enable = true;
      jq.enable = true;
      ripgrep.enable = true;
      starship.enable = true;

      atuin = {
        enable = true;
        settings = {
          inline_height = 20;
          show_preview = true;
          style = "compact";
        };
      };

      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      eza = {
        enable = true;
        git = true;
        icons = "always";
      };

      fzf = {
        enable = true;
        colors = with lib; {
          bg = mkForce "-1";
          "bg+" = mkForce "-1";
        };
      };

      zoxide = {
        enable = true;
        options = ["--cmd" "cd"];
      };
    };
  };
}
