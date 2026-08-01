{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "home.t3code";

  options.home.t3code = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = let
    buildTools = pkgs.symlinkJoin {
      name = "t3code-build-tools";
      paths = with pkgs; [
        gcc
        gnumake
        python3
      ];
    };
  in {
    xdg.configFile."systemd/user/t3code.service.d/build-tools.conf".text = ''
      [Service]
      Environment=PATH=${buildTools}/bin:/run/current-system/sw/bin:/etc/profiles/per-user/marshall/bin:%h/.nix-profile/bin
    '';
  };
}
