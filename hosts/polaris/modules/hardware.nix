{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "polaris";

  nixos.ifEnabled = {
    boot = {
      binfmt.emulatedSystems = ["aarch64-linux"];
      kernelPackages = pkgs.linuxPackages_xanmod_latest;
      loader.systemd-boot.enable = true;

      initrd.availableKernelModules = [
        "nvme"
        "sd_mod"
        "uas"
        "usb_storage"
        "xhci_pci"
      ];

      kernelModules = [
        "e1000e"
        "i915"
        "kvm-intel"
      ];
    };

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/NIXOS_ROOT";
        fsType = "ext4";
      };

      "/boot" = {
        device = "/dev/disk/by-label/NIXOS_BOOT";
        fsType = "vfat";
        options = [
          "dmask=0022"
          "fmask=0022"
        ];
      };

      "/mnt" = {
        device = "/dev/disk/by-label/POLARIS_DATA";
        fsType = "ext4";
        options = [
          "nofail"
          "x-systemd.device-timeout=10s"
        ];
      };
    };

    hardware = {
      cpu.intel.updateMicrocode = true;
      enableRedistributableFirmware = true;
      graphics.extraPackages = [pkgs.intel-media-driver];
    };
  };
}
