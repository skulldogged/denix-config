{
  config,
  delib,
  ...
}:
delib.module {
  name = "navis";

  nixos.ifEnabled = {
    environment.persistence."/persist" = {
      hideMounts = true;

      files = ["/etc/machine-id"];

      directories = [
        "/etc/ssh"
        "/etc/NetworkManager"
        "/root/.ssh"
        "/var/lib/bluetooth"
        "/var/lib/iwd"
        "/var/lib/nixos"
        "/var/lib/sbctl"
        "/var/lib/systemd/coredump"
        "/var/lib/systemd/bert"
        "/var/lib/systemd/kdump"
        "/var/lib/systemd/pstore"
        "/var/lib/systemd/timers"
        "/var/lib/navis-diagnostics"
        "/var/lib/rasdaemon"
        "/var/lib/decky-loader"
        "/var/lib/libvirt"
        "/var/lib/tailscale"
      ];
    };

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

      "/mnt/Shared" = {
        device = "/dev/disk/by-uuid/00AFAB5C797254C7";
        fsType = "ntfs";
        options = [
          "rw"
          "uid=1000"
          "gid=1000"
          "umask=007"
          "nofail"
        ];
      };

      "/mnt/Music" = {
        device = "//192.168.1.82/music";
        fsType = "cifs";
        options = [
          "noauto,x-systemd.automount,x-systemd.idle-timeout=5m,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s,uid=1000,gid=100,credentials=${config.sops.secrets.cifs.path}"
        ];
      };
    };

    environment.etc."udisks2/mount_options.conf".text = ''
      [defaults]
      ntfs_drivers=ntfs,ntfs3
    '';

    services.btrfs.autoScrub = {
      enable = true;
      fileSystems = ["/dev/mapper/enc"];
      limit = "500M";
    };
  };
}
