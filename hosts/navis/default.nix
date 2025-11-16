{
  delib,
  inputs,
  ...
}:
delib.host {
  name = "navis";

  rice = "catppuccin-mocha";
  type = "desktop";

  nixos = {
    imports = [
      inputs.agenix.nixosModules.default
      inputs.impermanence.nixosModules.impermanence
      inputs.nixos-facter-modules.nixosModules.facter
      inputs.chaotic.nixosModules.nyx-cache
      inputs.chaotic.nixosModules.nyx-overlay
      inputs.chaotic.nixosModules.nyx-registry
    ];

    nixpkgs.config.allowUnfree = true;

    facter.reportPath = ./facter.json;

    age = {
      secrets.passwd.file = ../../secrets/passwd.age;
      identityPaths = ["/persist/root/.ssh/id_ed25519"];
    };

    environment = {
      persistence."/persist" = {
        hideMounts = true;

        files = ["/etc/machine-id"];

        directories = [
          "/etc/ssh"
          "/etc/NetworkManager"
          "/root/.ssh"
          "/var/lib/bluetooth"
          "/var/lib/iwd"
          "/var/lib/nixos"
          "/var/lib/systemd/coredump"
          "/var/lib/decky-loader"
          "/var/lib/libvirt"
        ];
      };

      sessionVariables.AQ_DRM_DEVICES = "/dev/dri/card1";
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

    boot.initrd = {
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

    services = {
      btrfs.autoScrub = {
        enable = true;
        fileSystems = ["/dev/mapper/enc"];
      };

      greetd = {
        enable = true;
        settings = rec {
          initial_session = {
            command = "${inputs.hyprland.packages.x86_64-linux.hyprland}/bin/Hyprland";
            user = "marshall";
          };
          default_session = initial_session;
        };
      };

      xserver.videoDrivers = ["nvidia"];
    };
  };

  myconfig = {
    system = {
      boot.enable = true;
      chaotic.enable = true;
      environment.enable = true;
      fonts.enable = true;
      hardware.enable = true;
      i18n.enable = true;
      networking.enable = true;
      networking.hostName = "navis";
      nix.enable = true;
      programs.enable = true;
      security.enable = true;
      services.enable = true;
      users.enable = true;
    };

    home = {
      fish.enable = true;
      hyprland.enable = true;
      nix-index.enable = true;
      packages.enable = true;
      shell.enable = true;
      vicinae.enable = true;
      wezterm.enable = true;
    };

    programs = {
      cava.enable = true;
      draconisplusplus.enable = true;
      helium.enable = true;
      mpv.enable = true;
      quickshell.enable = true;
      xmobar.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "0FF5B8826803F895";
      };
    };
  };
}
