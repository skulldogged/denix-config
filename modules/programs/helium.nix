{
  delib,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "programs.helium";

  options.programs.helium = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {myconfig, ...}: let
    heliumUnwrapped = pkgs.appimageTools.wrapType2 rec {
      pname = "helium";
      version = "0.12.1.1";

      src = pkgs.fetchurl {
        url = "https://github.com/imputnet/helium-linux/releases/download/${version}/${pname}-${version}-x86_64.AppImage";
        sha256 = "sha256-+UE+JqQtxbA5szPvAohapXlES21VBOdNsV6Ej1dRRfs=";
      };

      extraInstallCommands = let
        contents = pkgs.appimageTools.extract {inherit pname version src;};
      in ''
        install -m 444 -D ${contents}/${pname}.desktop -t $out/share/applications
        substituteInPlace $out/share/applications/${pname}.desktop \
          --replace 'Exec=AppRun' 'Exec=${pname}'
        cp -r ${contents}/usr/share/icons $out/share
      '';
    };

    bypassPac = pkgs.writeText "helium-mullvad-bypass.pac" ''
      var bypassDomains = [
        "chatgpt.com",
        "openai.com",
        "oaistatic.com",
        "oaiusercontent.com",
        "reddit.com",
        "redd.it",
        "redditstatic.com",
        "redditmedia.com"
      ];

      function FindProxyForURL(url, host) {
        host = host.toLowerCase();

        for (var i = 0; i < bypassDomains.length; i++) {
          var domain = bypassDomains[i];
          if (host === domain || dnsDomainIs(host, "." + domain)) {
            return "SOCKS5 100.92.239.38:1080";
          }
        }

        return "DIRECT";
      }
    '';

    heliumWithSiteBypass = pkgs.symlinkJoin {
      name = "helium-with-mullvad-site-bypass-${heliumUnwrapped.version}";
      paths = [heliumUnwrapped];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = ''
        rm "$out/bin/helium"
        makeWrapper ${lib.getExe heliumUnwrapped} "$out/bin/helium" \
          --add-flags "--proxy-pac-url=file://${bypassPac}"
      '';
    };
  in {
    home.packages = [
      (
        if myconfig.host.isDesktop
        then heliumWithSiteBypass
        else heliumUnwrapped
      )
    ];
  };
}
