{delib, ...}:
delib.module {
  name = "system.filesystems";

  options.system.filesystems = with delib; {
    enable = boolOption false;
  };

  nixos.ifEnabled = {
    fileSystems = {
      "/" = {
        device = "/dev/disk/by-uuid/d375c3a3-63a3-47f8-8b77-58fabbb8f67b";
        fsType = "btrfs";
        options = ["subvol=root"];
      };

      "/home" = {
        device = "/dev/disk/by-uuid/d375c3a3-63a3-47f8-8b77-58fabbb8f67b";
        fsType = "btrfs";
        options = [
          "subvol=home"
          "compress=zstd"
        ];
      };

      "/nix" = {
        device = "/dev/disk/by-uuid/d375c3a3-63a3-47f8-8b77-58fabbb8f67b";
        fsType = "btrfs";
        options = [
          "subvol=nix"
          "compress=zstd"
          "noatime"
        ];
      };

      "/persist" = {
        device = "/dev/disk/by-uuid/d375c3a3-63a3-47f8-8b77-58fabbb8f67b";
        neededForBoot = true;
        fsType = "btrfs";
        options = [
          "subvol=persist"
          "compress=zstd"
        ];
      };

      "/var/log" = {
        device = "/dev/disk/by-uuid/d375c3a3-63a3-47f8-8b77-58fabbb8f67b";
        fsType = "btrfs";
        options = [
          "subvol=log"
          "compress=zstd"
          "noatime"
        ];
        neededForBoot = true;
      };

      "/boot" = {
        device = "/dev/disk/by-uuid/12CE-A600";
        fsType = "vfat";
        options = [
          "fmask=0022"
          "dmask=0022"
        ];
      };

      "/mnt/games" = {
        device = "/dev/disk/by-uuid/00AFAB5C797254C7";
        fsType = "ntfs3";
        options = [
          "rw"
          "uid=1000"
          "gid=1000"
          "umask=007"
          "nofail"
        ];
      };

      "/mnt/windows" = {
        device = "/dev/disk/by-uuid/52C84B24C84B0627";
        fsType = "ntfs3";
        options = [
          "rw"
          "uid=1000"
          "gid=1000"
          "umask=007"
          "nofail"
        ];
      };
    };
  };
}
