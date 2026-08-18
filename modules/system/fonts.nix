{
  delib,
  inputs,
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
            fairfax
            fairfax-hd
            maple-mono.NF
            material-symbols
            overpass
            proggyfonts
            rubik

            (twitter-color-emoji.overrideAttrs {
              inherit ((builtins.fromJSON (builtins.readFile "${inputs.twemoji-src}/package.json"))) version;
              __intentionallyOverridingVersion = true;

              srcs = [
                noto-fonts-color-emoji.src
                (builtins.path {
                  path = inputs.twemoji-src;
                  name = "twemoji-src";
                })
              ];
            })
          ]
          ++ (with nerd-fonts; [
            iosevka
            jetbrains-mono
            (symbols-only.overrideAttrs (_: {
              version = "3.5.0";
              src = pkgs.fetchurl {
                url = "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.0/NerdFontsSymbolsOnly.tar.xz";
                hash = "sha256-t+8ig0YrQ18f6R1yncQS1dvjQmndLH9OHYA+QQXI2IM=";
              };
            }))
            ubuntu-mono
          ]);
      };
    };
}
