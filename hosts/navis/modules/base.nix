{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "navis";

  options.navis = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    facter.reportPath = ../facter.json;

    networking = {
      hosts."37.27.111.236" = ["builder"];
      networkmanager.wifi.powersave = false;
    };

    environment = {
      systemPackages = [pkgs.sbctl];
      sessionVariables.AQ_DRM_DEVICES = "/dev/dri/card1";
    };

    hardware.logitech.wireless = {
      enable = true;
      enableGraphical = true;
    };

    services = {
      gvfs.enable = true;

      tailscale = {
        enable = true;
        openFirewall = true;
      };

      xserver.videoDrivers = ["nvidia"];
    };
  };
}
