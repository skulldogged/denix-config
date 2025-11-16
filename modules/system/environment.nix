{
  delib,
  pkgs,
  inputs,
  lib,
  ...
}:
delib.module {
  name = "system.environment";

  options.system.environment = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}: {
    environment = {
      localBinInPath = true;

      sessionVariables =
        {
          DIRENV_WARN_TIMEOUT = "100s";
          EDITOR = "nvim";
        }
        // lib.optionalAttrs myconfig.host.isDesktop {
          BROWSER = "helium";
          NIXOS_OZONE_WL = "1";
          TERMINAL = "wezterm";
        };

      systemPackages = with pkgs;
        [
          inputs.agenix.packages.${system}.default
          libsecret
          man-pages
          man-pages-posix
          nixd
          pciutils
        ]
        ++ lib.optionals myconfig.host.isDesktop [
          jamesdsp
          nautilus
          papirus-icon-theme
          python313
          sound-theme-freedesktop
          tpm2-tss
          uutils-coreutils-noprefix
          wineWowPackages.waylandFull
          xclip
        ];
    };

    systemd.user.extraConfig = ''
      DefaultEnvironment="PATH=${lib.concatStringsSep ":" [
        "/run/wrappers/bin"
        "/etc/profiles/per-user/%u/bin"
        "/nix/var/nix/profiles/default/bin"
        "/run/current-system/sw/bin"
      ]}"
    '';

    time = {
      hardwareClockInLocalTime = myconfig.host.isDesktop;
      timeZone = "America/New_York";
    };

    documentation = {
      enable = true;
      doc.enable = true;
      dev.enable = true;
      man.enable = true;
      man.generateCaches = true;
    };
  };
}
