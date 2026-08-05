{
  delib,
  pkgs,
  lib,
  ...
}:
delib.module {
  name = "system.boot";

  options.system.boot = with delib; {
    enable = boolOption false;

    enableIntelGraphics =
      description
      (boolOption false)
      "Enable the Intel graphics driver instead of blacklisting i915";
  };

  nixos.ifEnabled = {myconfig, ...}: let
    enableIntelGraphics = myconfig.system.boot.enableIntelGraphics;
  in {
    boot = {
      kernelPackages = lib.mkIf myconfig.host.isDesktop pkgs.linuxPackages_zen;
      tmp.useTmpfs = true;

      kernel.sysctl = lib.mkIf myconfig.host.isDesktop {
        "kernel.perf_event_paranoid" = 1;
        "kernel.kptr_restrict" = 0;
      };

      blacklistedKernelModules =
        lib.optionals myconfig.host.isDesktop ["nouveau"]
        ++ lib.optional (myconfig.host.isDesktop && !enableIntelGraphics) "i915";

      kernelModules = lib.optionals myconfig.host.isDesktop ["kvm-intel"];

      supportedFilesystems =
        ["ntfs"]
        ++ lib.optionals myconfig.host.isDesktop [
          "btrfs"
          "ntfs3"
        ];

      extraModprobeConfig = lib.mkIf myconfig.host.isDesktop (
        "options nvidia "
        + lib.concatStringsSep " " [
          "NVreg_EnablePCIeGen3=1"
          "NVreg_RegistryDwords=RMUseSwI2c=0x01;RMI2cSpeed=100"
          "NVreg_UsePageAttributeTable=1"
        ]
      );

      kernelParams = lib.optionals myconfig.host.isDesktop [
        "intel_iommu=on"
        "iommu=pt"
        "kvm.ignore_msrs=1"
        "modprobe.blacklist=nouveau${lib.optionalString (!enableIntelGraphics) ",i915"}"
        "nvidia_drm.fbdev=1"
      ];

      loader.efi.canTouchEfiVariables = true;
    };
  };
}
