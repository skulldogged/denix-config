{
  delib,
  lib,
  ...
}:
delib.module {
  name = "system.services";

  options.system.services = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}: {
    services = {
      flatpak.enable = lib.mkDefault myconfig.host.isDesktop;
      geoclue2.enable = myconfig.host.isDesktop;
      getty.autologinUser = lib.mkIf myconfig.host.isDesktop myconfig.constants.username;
      gnome.gnome-keyring.enable = myconfig.host.isDesktop;
      mullvad-vpn.enable = false;
      udisks2.enable = true;
      xserver.enable = lib.mkDefault myconfig.host.isDesktop;

      libinput = lib.mkIf myconfig.host.isDesktop {
        enable = true;
        touchpad.naturalScrolling = true;
      };

      openssh = {
        enable = true;

        settings = {
          PasswordAuthentication = false;
          PermitRootLogin = "no";
          KbdInteractiveAuthentication = false;
        };
      };

      pipewire = {
        enable = true;
        pulse.enable = true;

        alsa = {
          enable = true;
          support32Bit = true;
        };
      };
    };

    systemd = {
      tpm2.enable = myconfig.host.isDesktop;
      network.wait-online.enable = false;

      # The 64-bit defaults allow systemd-coredump to process and store up to
      # 32 GiB per crash. Electron's huge mapped address space can hit that
      # ceiling and saturate memory and storage I/O even when the compressed
      # dump is small.
      coredump.settings.Coredump = {
        Storage = "external";
        Compress = true;
        ProcessSizeMax = "512M";
        ExternalSizeMax = "512M";
        MaxUse = "1G";
        KeepFree = "10G";
      };
    };
  };
}
