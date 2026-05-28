{
  delib,
  inputs,
  pkgs,
  ...
}:
delib.module {
  name = "home.fish";

  options.home.fish = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = _: let
    mkFishPlugin = name: src: {
      inherit name src;
    };

    extraPlugins = [
      (mkFishPlugin "bang-bang" inputs.bang-bang)
      (mkFishPlugin "fish-git-abbr" inputs.fish-git-abbr)
      (mkFishPlugin "license" inputs.license)
      (mkFishPlugin "replay-fish" inputs.replay-fish)
    ];

    mkFishPlugins = names:
      map (name: {
        inherit name;
        inherit (pkgs.fishPlugins.${name}) src;
      })
      names;
  in {
    programs.fish = {
      enable = true;

      functions.export =
        # fish
        ''
          if test -z "$argv"
            set -x
            return 0
          end
          for arg in $argv
            set -l v (string split -m 1 = -- $arg)
            if test (count $v) -eq 2
              set -gx $v[1] $v[2]
            else
              set -gx $v[1] $v[1]
            end
          end
        '';

      plugins =
        extraPlugins
        ++ (mkFishPlugins ["autopair" "bass" "colored-man-pages" "done" "fifc"]);

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
