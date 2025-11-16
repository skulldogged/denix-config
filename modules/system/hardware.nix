{
  delib,
  pkgs,
  config,
  lib,
  ...
}:
delib.module {
  name = "system.hardware";

  options.system.hardware = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {myconfig, ...}: {
    hardware =
      {
        bluetooth.enable = true;

        graphics = {
          enable = true;
          enable32Bit = true;
        };
      }
      // lib.optionalAttrs myconfig.host.isDesktop {
        i2c.enable = true;
        nvidia-container-toolkit.enable = true;

        graphics.extraPackages = with pkgs; [
          libva-vdpau-driver
          nvidia-vaapi-driver
        ];

        nvidia = {
          package = config.boot.kernelPackages.nvidiaPackages.beta;
          modesetting.enable = true;
          powerManagement.enable = false;
          open = true;
        };
      };
  };
}
