{
  config,
  delib,
  lib,
  pkgs,
  ...
}: let
  bareMetal = config.myconfig.polaris.bareMetal;
in
  delib.module {
    name = "polaris";

    nixos.ifEnabled = lib.mkMerge [
      {
        boot = {
          binfmt.emulatedSystems = ["aarch64-linux"];
          kernelPackages = pkgs.linuxPackages_xanmod_latest;
          loader.systemd-boot.enable = true;
        };
      }

      (lib.mkIf (!bareMetal) {
        facter.reportPath = ../facter.json;

        fileSystems = {
          "/" = {
            device = "/dev/disk/by-uuid/64079eb2-d3e3-47b7-a889-d5b2fee4fa82";
            fsType = "ext4";
          };

          "/boot" = {
            device = "/dev/disk/by-uuid/BC12-6397";
            fsType = "vfat";
          };

          "/mnt" = {
            device = "/dev/disk/by-uuid/88133d6c-7eed-4b4c-aba3-f561f9ac34f6";
            fsType = "ext4";
            options = ["nofail"];
          };
        };
      })

      (lib.mkIf bareMetal {
        boot = {
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
      })
    ];
  }
