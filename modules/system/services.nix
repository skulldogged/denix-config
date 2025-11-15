{
  delib,
  pkgs,
  inputs,
  ...
}:
delib.module {
  name = "system.services";

  options.system.services = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}: {
    services = {
      flatpak.enable = true;
      geoclue2.enable = true;
      getty.autologinUser = myconfig.constants.username;
      gnome.gnome-keyring.enable = true;
      mullvad-vpn.enable = true;
      openssh.enable = true;
      udisks2.enable = true;

      btrfs.autoScrub = {
        enable = true;
        fileSystems = ["/dev/mapper/enc"];
      };

      greetd = {
        enable = true;
        settings = rec {
          initial_session = {
            command = "${inputs.hyprland.packages.${pkgs.system}.hyprland}/bin/Hyprland";
            user = myconfig.constants.username;
          };
          default_session = initial_session;
        };
      };

      libinput = {
        enable = true;
        touchpad.naturalScrolling = true;
      };

      xserver = {
        enable = true;
        videoDrivers = ["nvidia"];
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
      tpm2.enable = true;
      network.wait-online.enable = false;
    };
  };
}
