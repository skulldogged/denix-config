{
  config,
  delib,
  lib,
  pkgs,
  ...
}: let
  wifiRecovery = pkgs.writeShellApplication {
    name = "navis-wifi-recover";

    runtimeInputs = [
      pkgs.coreutils
      pkgs.networkmanager
    ];

    text = ''
      set -euo pipefail

      pci_device=/sys/bus/pci/devices/0000:04:00.0
      pci_parent=/sys/bus/pci/devices/0000:00:1c.0
      expected_vendor=0x8086
      expected_device=0x2725

      log() {
        printf 'navis-wifi-recover: %s\n' "$*"
      }

      verify_device() {
        [[ -r "$pci_device/vendor" ]] \
          && [[ -r "$pci_device/device" ]] \
          && [[ "$(< "$pci_device/vendor")" == "$expected_vendor" ]] \
          && [[ "$(< "$pci_device/device")" == "$expected_device" ]]
      }

      wifi_interface() {
        local candidate

        for candidate in "$pci_device"/net/*; do
          if [[ -e "$candidate" ]]; then
            basename "$candidate"
            return 0
          fi
        done

        return 1
      }

      if [[ ! -w "$pci_parent/rescan" ]]; then
        log "PCIe root-port rescan control is unavailable"
        exit 1
      fi

      if [[ -e "$pci_device" ]] && ! verify_device; then
        log "refusing to remove unexpected device at 0000:04:00.0"
        exit 1
      fi

      # iwlwifi emits EVENT=INACCESSIBLE immediately before its asynchronous
      # PCI removal. Give that work time to finish before forcing removal.
      for _ in $(seq 1 100); do
        [[ ! -e "$pci_device" ]] && break
        sleep 0.1
      done

      if [[ -e "$pci_device" ]]; then
        if ! verify_device; then
          log "device identity changed while waiting for driver removal"
          exit 1
        fi

        log "driver removal did not finish; removing the inaccessible AX210"
        printf '1\n' > "$pci_device/remove"

        for _ in $(seq 1 50); do
          [[ ! -e "$pci_device" ]] && break
          sleep 0.1
        done
      fi

      if [[ -e "$pci_device" ]]; then
        log "AX210 remained registered after removal request"
        exit 1
      fi

      log "rescanning the AX210 PCIe root port"
      for attempt in $(seq 1 30); do
        printf '1\n' > "$pci_parent/rescan"

        if [[ -e "$pci_device" ]] && verify_device; then
          log "AX210 returned on PCI rescan attempt $attempt"
          break
        fi

        sleep 2
      done

      if [[ ! -e "$pci_device" ]] || ! verify_device; then
        log "AX210 did not return within 60 seconds"
        exit 1
      fi

      interface=""
      for _ in $(seq 1 100); do
        interface="$(wifi_interface || true)"
        [[ -n "$interface" ]] && break
        sleep 0.2
      done

      if [[ -z "$interface" ]]; then
        log "iwlwifi did not create a network interface"
        exit 1
      fi

      log "waiting for NetworkManager to reconnect $interface"
      for _ in $(seq 1 10); do
        state="$(nmcli --get-values GENERAL.STATE device show "$interface" 2>/dev/null || true)"
        if [[ "$state" == 100* ]]; then
          log "$interface reconnected automatically"
          exit 0
        fi
        sleep 2
      done

      log "requesting an explicit NetworkManager reconnect for $interface"
      nmcli --wait 30 device connect "$interface"

      state="$(nmcli --get-values GENERAL.STATE device show "$interface" 2>/dev/null || true)"
      if [[ "$state" != 100* ]]; then
        log "$interface returned but did not reach the connected state"
        exit 1
      fi

      log "$interface is connected"
    '';
  };
in
  delib.module {
    name = "navis";

    nixos.ifEnabled = {
      boot = {
        extraModprobeConfig = ''
          options iwlwifi power_save=0 enable_ini=0 fw_restart=1 remove_when_gone=1
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
          availableKernelModules = [
            "nvme"
            "tpm_tis"
            "xhci_pci"
          ];
          kernelModules = ["nvidia"];

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

        kernelModules = ["i915"];
      };

      hardware = {
        enableRedistributableFirmware = true;
        cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
        graphics.extraPackages = [pkgs.intel-media-driver];
      };

      services.udev.extraRules = ''
        ACTION=="change", SUBSYSTEM=="pci", KERNEL=="0000:04:00.0", ATTR{vendor}=="0x8086", ATTR{device}=="0x2725", ENV{EVENT}=="INACCESSIBLE", RUN+="${config.systemd.package}/bin/systemctl --no-block start navis-wifi-recovery.service"
      '';

      systemd.services.navis-wifi-recovery = {
        description = "Recover an inaccessible Intel AX210 Wi-Fi adapter";
        wants = ["NetworkManager.service"];
        after = ["NetworkManager.service"];

        unitConfig = {
          StartLimitIntervalSec = "2min";
          StartLimitBurst = 3;
        };

        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${wifiRecovery}/bin/navis-wifi-recover";
          TimeoutStartSec = "3min";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
        };
      };

      systemd.settings.Manager.RebootWatchdogSec = "2min";
    };
  }
