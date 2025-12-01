{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "programs.helium";

  options.programs.helium = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    home.packages = with pkgs; [
      (appimageTools.wrapType2 rec {
        pname = "helium";
        version = "0.6.9.1";

        src = fetchurl {
          url = "https://github.com/imputnet/helium-linux/releases/download/${version}/${pname}-${version}-x86_64.AppImage";
          sha256 = "sha256-L59Sm5qgORlV3L2yM6C0R8lDRyk05jOZcD5JPhQtbJE=";
        };

        extraInstallCommands = let
          contents = appimageTools.extract {inherit pname version src;};
        in ''
          install -m 444 -D ${contents}/${pname}.desktop -t $out/share/applications
          substituteInPlace $out/share/applications/${pname}.desktop \
            --replace 'Exec=AppRun' 'Exec=${pname}'
          cp -r ${contents}/usr/share/icons $out/share
        '';
      })
    ];
  };
}
