{
  delib,
  pkgs,
  config,
  ...
}:
delib.module {
  name = "system.hardware";

  options.system.hardware = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    hardware = {
      bluetooth.enable = true;
      i2c.enable = true;
      nvidia-container-toolkit.enable = true;

      graphics = {
        enable = true;
        enable32Bit = true;
        extraPackages = with pkgs; [
          libva-vdpau-driver
          nvidia-vaapi-driver
        ];
      };

      nvidia = {
        package = config.boot.kernelPackages.nvidiaPackages.beta;
        modesetting.enable = true;
        powerManagement.enable = false;
        open = true;
      };
    };
  };
}
