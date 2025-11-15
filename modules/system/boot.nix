{
  delib,
  pkgs,
  lib,
  inputs,
  ...
}:
delib.module {
  name = "system.boot";

  options.system.boot = with delib; {
    enable = boolOption false;
    bootloader = strOption "limine"; # "limine" or "systemd-boot"
  };

  nixos.ifEnabled = {myconfig, ...}: {
    boot = {
      kernelPackages = pkgs.linuxPackages_cachyos;
      tmp.useTmpfs = true;

      kernel.sysctl = {
        "kernel.perf_event_paranoid" = 1;
        "kernel.kptr_restrict" = 0;
      };

      blacklistedKernelModules = [
        "nouveau"
        "i915"
      ];

      kernelModules = ["kvm-intel"];

      supportedFilesystems = [
        "btrfs"
        "ntfs3"
      ];

      initrd = {
        availableKernelModules = ["tpm_tis"];

        luks.devices."enc" = {
          device = "/dev/disk/by-uuid/9952fcd1-46eb-4c9c-ab7d-361d31fdb9a2";
          crypttabExtraOpts = ["tpm2-device=auto" "tpm2-measure-pcr=yes"];
        };

        systemd = {
          enable = true;
          emergencyAccess = true;
          tpm2.enable = true;

          services.wipe-root = {
            description = "Rollback BTRFS root subvolume to a pristine state";
            wantedBy = ["initrd.target"];
            after = ["dev-mapper-enc.device"];
            requires = ["dev-mapper-enc.device"];
            before = ["sysroot.mount"];
            unitConfig.DefaultDependencies = "no";
            serviceConfig.Type = "oneshot";
            script = ''
              (
                set -xe

                btrfs_subvolume_delete_recursive() {
                  btrfs subvolume list -o "$1" |
                    cut -f 9- -d ' ' |
                    while read -r subvolume; do
                      btrfs_subvolume_delete_recursive "$mount_point/$subvolume"
                    done

                  btrfs subvolume delete "$1"
                }

                mount_point=/mnt
                mkdir -p "$mount_point"
                mount -t btrfs "/dev/mapper/enc" "$mount_point"

                trap 'umount "$mount_point" && rmdir "$mount_point"' EXIT

                btrfs_subvolume_delete_recursive \
                  "$mount_point/root"

                btrfs subvolume create "$mount_point/root"
              )
            '';
          };
        };
      };

      extraModprobeConfig =
        "options nvidia "
        + lib.concatStringsSep " " [
          "NVreg_EnablePCIeGen3=1"
          "NVreg_RegistryDwords=RMUseSwI2c=0x01;RMI2cSpeed=100"
          "NVreg_UsePageAttributeTable=1"
        ];

      kernelParams = [
        "intel_iommu=on"
        "iommu=pt"
        "kvm.ignore_msrs=1"
        "modprobe.blacklist=nouveau,i915"
        "nvidia_drm.fbdev=1"
      ];

      loader = {
        efi.canTouchEfiVariables = true;

        limine = lib.mkIf (myconfig.system.boot.bootloader == "limine") {
          enable = true;
          maxGenerations = 3;

          style = {
            wallpapers = [(inputs.self + "/walls/blaidd.png")];
            interface.resolution = "2560x1440";
          };
        };

        systemd-boot = lib.mkIf (myconfig.system.boot.bootloader == "systemd-boot") {
          enable = true;
        };
      };
    };
  };
}
