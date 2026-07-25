{
  config,
  delib,
  inputs,
  pkgs,
  ...
}:
delib.host {
  name = "navis";

  rice = "catppuccin-mocha";
  system = "x86_64-linux";
  type = "desktop";

  nixos = {
    imports = [
      inputs.impermanence.nixosModules.impermanence
      inputs.lanzaboote.nixosModules.lanzaboote
    ];

    nixpkgs.config.allowUnfree = true;

    nix = {
      distributedBuilds = true;
      buildMachines = [
        {
          hostName = "builder";
          protocol = "ssh-ng";
          sshUser = "nix-builder";
          sshKey = "/persist/root/.ssh/id_ed25519";
          publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUVlOHJ0eTl4L0sxS1kvU2srOHQyQ1FTeE41amVLa3p0SW9USUt6dG5OSHogcm9vdEBidWlsZGVyCg==";
          systems = ["x86_64-linux"];
          maxJobs = 8;
          speedFactor = 20;
          supportedFeatures = [
            "benchmark"
            "nixos-test"
            "kvm"
            "recursive-nix"
            "big-parallel"
            "gccarch-x86-64-v4"
          ];
        }
      ];
    };

    networking.hosts."37.27.111.236" = ["builder"];
    networking.networkmanager.wifi.powersave = false;

    facter.reportPath = ./facter.json;

    sops = {
      defaultSopsFile = ../../secrets/navis.yaml;
      age.sshKeyPaths = ["/persist/root/.ssh/id_ed25519"];

      secrets = {
        cifs = {};
        passwd = {};
        zipline_token = {
          owner = "marshall";
        };
      };
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
          "/var/lib/sbctl"
          "/var/lib/systemd/coredump"
          "/var/lib/systemd/kdump"
          "/var/lib/systemd/pstore"
          "/var/lib/systemd/timers"
          "/var/lib/decky-loader"
          "/var/lib/libvirt"
          "/var/lib/tailscale"
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

      "/mnt/music" = {
        device = "//192.168.1.82/music";
        fsType = "cifs";
        options = [
          "noauto,x-systemd.automount,x-systemd.idle-timeout=5m,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s,uid=1000,gid=100,credentials=${config.sops.secrets.cifs.path}"
        ];
      };
    };

    systemd.services.fix-games-mount = {
      description = "Fix NTFS filesystem on games drive before mounting";
      before = ["mnt-games.mount"];
      wantedBy = ["mnt-games.mount"];
      serviceConfig.Type = "oneshot";
      script = "${pkgs.ntfs3g}/bin/ntfsfix -d /dev/disk/by-uuid/00AFAB5C797254C7";
    };

    systemd.targets.kdump-save = {
      description = "Save kernel crash diagnostics";
      requires = ["kdump-save.service"];
      after = ["kdump-save.service"];
    };

    systemd.services.kdump-save = {
      description = "Save kernel crash diagnostics";
      before = ["kdump-save.target"];
      onFailure = ["emergency.target"];
      unitConfig = {
        ConditionPathExists = "/proc/vmcore";
        RequiresMountsFor = "/var/lib/systemd/kdump";
        SuccessAction = "reboot-force";
      };
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "10min";
      };
      path = [
        pkgs.coreutils
        pkgs.kexec-tools
      ];
      script = ''
        set -euo pipefail
        umask 077

        output_dir=/var/lib/systemd/kdump
        timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"
        dmesg_file="$output_dir/$timestamp.dmesg"
        metadata_file="$output_dir/$timestamp.meta"

        mkdir -p "$output_dir"

        vmcore-dmesg /proc/vmcore > "$dmesg_file.tmp"
        {
          printf 'Captured: %s\n' "$timestamp"
          printf 'VMCore bytes: '
          stat --format=%s /proc/vmcore
          printf 'Crash kernel: '
          uname -a
          printf 'Crash kernel command line: '
          cat /proc/cmdline
        } > "$metadata_file.tmp"

        mv "$dmesg_file.tmp" "$dmesg_file"
        mv "$metadata_file.tmp" "$metadata_file"
        sync "$dmesg_file" "$metadata_file"
      '';
    };

    environment.systemPackages = [
      pkgs.sbctl
    ];

    boot = {
      crashDump = {
        enable = true;
        reservedMemory = "512M";
        kernelParams = [
          "systemd.unit=kdump-save.target"
          "boot.shell_on_fail"
          "loglevel=7"
        ];
      };

      extraModprobeConfig = ''
        options iwlwifi power_save=0
        options iwlmvm power_scheme=1
      '';

      kernelParams = [
        "oops=panic"
        "panic=30"
      ];

      lanzaboote = {
        enable = true;
        pkiBundle = "/var/lib/sbctl";
        configurationLimit = 3;
        autoEnrollKeys = {
          enable = true;
          includeMicrosoftKeys = true;
        };
        settings.timeout = 0;
      };

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
    };

    hardware.logitech.wireless = {
      enable = true;
      enableGraphical = true;
    };

    services = {
      gvfs.enable = true;

      btrfs.autoScrub = {
        enable = true;
        fileSystems = ["/dev/mapper/enc"];
        limit = "500M";
      };

      greetd = {
        enable = true;
        settings = rec {
          initial_session = {
            command = "${inputs.hyprland.packages.x86_64-linux.hyprland}/bin/start-hyprland";
            user = "marshall";
          };
          default_session = initial_session;
        };
      };

      tailscale.enable = true;
      tailscale.openFirewall = true;

      xserver.videoDrivers = ["nvidia"];
    };
  };

  myconfig = {
    system = {
      boot.enable = true;
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
      wezterm.enable = true;
    };

    programs = {
      bun.enable = true;
      cava.enable = true;
      codex-desktop.enable = true;
      draconisplusplus.enable = true;
      helium.enable = true;
      mpv.enable = true;
      mpd.enable = true;
      rmpc.enable = true;
      caelestia-shell.enable = true;

      git = {
        enable = true;
        credentialHelper = "libsecret";
        signingKey = "263409D620072FB8";
      };

      linux-wallpaperengine = {
        enable = true;
        assetsDir = "/mnt/games/SteamLibrary/steamapps/common/wallpaper_engine/assets";
        wallpaperPath = "/mnt/games/SteamLibrary/steamapps/workshop/content/431960/2847826034";
        screen = "DP-1";
      };
    };
  };
}
