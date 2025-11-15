{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "system.fonts";

  options.system.fonts = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
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

          # Commenting out custom twemoji until we get the correct hash
          # (twemoji-color-font.overrideAttrs {
          #   version = "16.0.1";
          #   src = pkgs.fetchurl {
          #     url = "https://github.com/hanakla/twemoji-color-font/releases/download/v16.0.1/TwitterColorEmoji-SVGinOT-Linux-16.0.1.tar.gz";
          #     sha256 = ""; # TODO: Get correct hash
          #   };
          # })

          (twitter-color-emoji.overrideAttrs rec {
            version = "16.0.1";
            __intentionallyOverridingVersion = true;

            srcs = [
              pkgs.noto-fonts-color-emoji.src
              (pkgs.fetchFromGitHub {
                name = "twemoji";
                owner = "jdecked";
                repo = "twemoji";
                rev = "v${version}";
                hash = "sha256-wuiMNEwgauPWV0q0SqxZ17wcdPhCF1QPKUFf56rldDo=";
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
