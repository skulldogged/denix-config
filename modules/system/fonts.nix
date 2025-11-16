{
  delib,
  pkgs,
  lib,
  ...
}:
delib.module {
  name = "system.fonts";

  options.system.fonts = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}:
    lib.mkIf myconfig.host.isDesktop {
      fonts = {
        fontconfig.defaultFonts = {
          emoji = ["Twitter Color Emoji"];
          sansSerif = ["Rubik"];
          serif = ["Brygada 1918"];
          monospace = ["Maple Mono NF"];
        };

        packages = with pkgs;
          [
            brygada-1918
            maple-mono.NF
            material-symbols
            overpass
            proggyfonts
            rubik

            # is this stupid? probably. does it work? yes!
            (twemoji-color-font.overrideAttrs {
              version = "17.0.2";
              src = ../../files/TwitterColorEmoji-SVGinOT-Linux-17.0.2.tar.gz; # source: https://github.com/RyeMutt/twemoji-color-font
            })

            (twitter-color-emoji.overrideAttrs rec {
              version = "17.0.2";
              __intentionallyOverridingVersion = true;

              srcs = [
                noto-fonts-color-emoji.src
                (fetchFromGitHub {
                  name = "twemoji";
                  owner = "jdecked";
                  repo = "twemoji";
                  rev = "v${version}";
                  hash = "sha256-LeAIXrPzp6rmmrz4ixehaD4/U1i15NDR0wvYyFOjw0U=";
                })
              ];
            })
          ]
          ++ (with nerd-fonts; [
            iosevka
            jetbrains-mono
            symbols-only
            ubuntu-mono
          ]);
      };
    };
}
