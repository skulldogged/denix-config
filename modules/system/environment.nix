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

  nixos.ifEnabled = _: {
    environment = {
      localBinInPath = true;

      sessionVariables = {
        AQ_DRM_DEVICES = "/dev/dri/card1";
        BROWSER = "helium";
        DIRENV_WARN_TIMEOUT = "100s";
        EDITOR = "nvim";
        NIXOS_OZONE_WL = "1";
        TERMINAL = "wezterm";
      };

      systemPackages = with pkgs; [
        inputs.agenix.packages.${system}.default
        jamesdsp
        libsecret
        man-pages
        man-pages-posix
        nautilus
        nixd
        papirus-icon-theme
        pciutils
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
      hardwareClockInLocalTime = true;
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
