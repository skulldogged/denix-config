{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "home.fish";

  options.home.fish = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {myconfig, ...}: let
    mkFishPlugin = sources: {
      inherit (sources) src;
      name = sources.pname;
    };

    sources = import ../../_sources/generated.nix {inherit (pkgs) fetchFromGitHub;};

    extraPlugins = pkgs.lib.attrsets.mapAttrsToList (_: mkFishPlugin) sources;

    mkFishPlugins = names:
      map (name: {
        inherit name;
        inherit (pkgs.fishPlugins.${name}) src;
      })
      names;
  in {
    programs.fish = {
      enable = true;

      plugins =
        extraPlugins
        ++ (mkFishPlugins ["autopair" "bass" "colored-man-pages" "done" "fifc" "forgit"]);

      shellAliases = {
        cat = "${pkgs.bat}/bin/bat";
        df = "${pkgs.duf}/bin/duf";
        rm = "${pkgs.rm-improved}/bin/rip";
      };

      interactiveShellInit = ''
        function fish_greeting
          if type -q draconis++
            draconis++ ${pkgs.lib.optionalString myconfig.host.isDesktop "--logo-path ${../../files/tiger-cub.gif} --logo-protocol iterm2 --logo-height 200 --logo-width 200"}
          end
        end

        bind --erase \ct

        fish_add_path /opt/homebrew/bin
        fish_add_path /Users/marshall/.nix-profile/bin
      '';
    };
  };
}
