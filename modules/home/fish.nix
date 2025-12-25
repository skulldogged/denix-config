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

  home.ifEnabled = _: let
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
            draconis++
          end
        end

        bind --erase \ct

        fish_add_path /opt/homebrew/bin
        fish_add_path /Users/marshall/.nix-profile/bin
      '';
    };
  };
}
