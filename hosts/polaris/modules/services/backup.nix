{
  config,
  delib,
  pkgs,
  ...
}: let
  backupStage = "/var/backup/polaris";
  backupName = "polaris";
in
  delib.module {
    name = "polaris";

    nixos.ifEnabled = {
      sops = {
        secrets = {
          restic_b2_key_id = {};
          restic_b2_application_key = {};
          restic_repository_password = {};
        };

        templates."restic-b2.env" = {
          owner = "root";
          group = "root";
          mode = "0400";
          content = ''
            AWS_ACCESS_KEY_ID=${config.sops.placeholder.restic_b2_key_id}
            AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.restic_b2_application_key}
            RESTIC_REPOSITORY=s3:s3.us-east-005.backblazeb2.com/polaris-restic-a7f39c
          '';
        };
      };

      services.restic.backups.${backupName} = {
        initialize = true;
        environmentFile = config.sops.templates."restic-b2.env".path;
        passwordFile = config.sops.secrets.restic_repository_password.path;

        paths = [
          # Server and user identities that cannot be reconstructed from Nix.
          "/etc/ssh"
          "/home/marshall/.gnupg"
          "/home/marshall/.local/share/keyrings"
          "/home/marshall/.pki"
          "/home/marshall/.ssh"
          "/root/.ssh"

          # Local source and application state that may not have been pushed.
          "/home/marshall/.config"
          "/home/marshall/Desktop"
          "/home/marshall/Documents"
          "/home/marshall/Projects"
          "/home/marshall/nix-config"
          "/home/marshall/personal-agent"

          # Media stored on the single external SSD.
          "/mnt/books"
          "/mnt/migration-backup"
          "/mnt/minecraft"
          "/mnt/muse"
          "/mnt/music"
          "/mnt/music-videos"
          "/mnt/shows"
          "/mnt/stump"

          # Consistent copies of stateful service data, prepared below.
          backupStage
        ];

        exclude = [
          # GnuPG creates transient socket/lock files with this prefix.
          "**/.#*"

          # Reproducible development outputs and dependency caches dwarf the
          # source trees and are unnecessary for bare-metal recovery.
          "**/.cache/**"
          "**/.direnv/**"
          "**/node_modules/**"
          "**/target/**"
        ];

        extraBackupArgs = [
          "--cleanup-cache"
          "--compression=auto"
          "--exclude-caches"
          "--one-file-system"
          "--tag=${backupName}"
        ];

        pruneOpts = [
          "--keep-daily=7"
          "--keep-weekly=5"
          "--keep-monthly=12"
          "--keep-yearly=3"
        ];

        checkOpts = ["--with-cache"];

        timerConfig = {
          OnCalendar = "*-*-* 03:15:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };

        backupPrepareCommand = ''
          #!${pkgs.runtimeShell}
          set -euo pipefail
          umask 0077

          stage=${backupStage}
          systemctl=${pkgs.systemd}/bin/systemctl
          rsync=${pkgs.rsync}/bin/rsync
          install=${pkgs.coreutils}/bin/install
          mv=${pkgs.coreutils}/bin/mv
          runuser=${pkgs.util-linux}/bin/runuser
          pg_dumpall=${config.services.postgresql.package}/bin/pg_dumpall

          "$install" -d -m 0700 "$stage"

          stopped_units=()
          for unit in \
            home-assistant.service \
            mosquitto.service \
            forgejo.service \
            vaultwarden-cloudflared.service \
            vaultwarden.service \
            zipline.service \
            bluesky-pds.service \
            jellyfin.service \
            slskd.service \
            samba-smbd.service \
            samba-winbindd.service
          do
            if "$systemctl" is-active --quiet "$unit"; then
              "$systemctl" stop "$unit"
              stopped_units+=("$unit")
            fi
          done

          restart_services() {
            local result=0
            local i
            for ((i=''${#stopped_units[@]} - 1; i >= 0; i--)); do
              "$systemctl" start "''${stopped_units[$i]}" || result=1
            done
            return "$result"
          }
          trap restart_services EXIT

          sync_state() {
            local source=$1
            local destination=$2
            shift 2
            if [[ -d "$source" ]]; then
              "$install" -d -m 0700 "$destination"
              "$rsync" -aHAX --delete --delete-excluded --numeric-ids "$@" "$source/" "$destination/"
            fi
          }

          # Keep the material required to bootstrap SOPS and this flake on the
          # external VHD as well as in encrypted Restic. The physical SSD must
          # remain untouched until this VHD has been recovered after install.
          bootstrap=/mnt/migration-backup/baremetal-bootstrap
          "$install" -d -o root -g root -m 0700 "$bootstrap"
          "$install" -o root -g root -m 0600 \
            /etc/ssh/ssh_host_ed25519_key \
            "$bootstrap/ssh_host_ed25519_key"
          "$install" -o root -g root -m 0644 \
            /etc/ssh/ssh_host_ed25519_key.pub \
            "$bootstrap/ssh_host_ed25519_key.pub"
          if [[ -f /home/marshall/amt.txt ]]; then
            "$install" -o root -g root -m 0600 \
              /home/marshall/amt.txt \
              "$bootstrap/amt.txt"
          fi
          if [[ -f /home/marshall/xoa.txt ]]; then
            "$install" -o root -g root -m 0600 \
              /home/marshall/xoa.txt \
              "$bootstrap/xoa.txt"
          fi
          sync_state /home/marshall/nix-config "$bootstrap/nix-config" \
            --exclude=/.direnv/ \
            --exclude=/result

          sync_state /var/lib/forgejo "$stage/forgejo"
          # Polaris keeps system.stateVersion at 23.11, so the NixOS
          # Vaultwarden module intentionally retains its historical state
          # directory name.
          sync_state /var/lib/bitwarden_rs "$stage/vaultwarden"
          sync_state /var/lib/hass "$stage/home-assistant" \
            --exclude=/.cache/
          sync_state /var/lib/mosquitto "$stage/mosquitto"
          sync_state /var/lib/slskd "$stage/slskd" \
            --exclude=/data/backups/ \
            --exclude=/incomplete/
          sync_state /mnt/jellyfin "$stage/jellyfin" \
            --exclude=/log/
          sync_state /mnt/pds "$stage/bluesky-pds"
          sync_state /mnt/zipline "$stage/zipline"
          sync_state /var/lib/samba "$stage/samba"

          # Tailscale remains online so the backup cannot sever remote access.
          # Its state file is atomically replaced, making a live copy safe.
          sync_state /var/lib/tailscale "$stage/tailscale"

          "$runuser" -u postgres -- "$pg_dumpall" > "$stage/postgresql.sql.tmp"
          "$mv" "$stage/postgresql.sql.tmp" "$stage/postgresql.sql"

          restart_services
          trap - EXIT
        '';
      };

      systemd = {
        services = {
          "restic-backups-${backupName}" = {
            after = ["mnt.mount"];
            requires = ["mnt.mount"];
            unitConfig.ConditionPathIsMountPoint = "/mnt";
          };

          "restic-check-${backupName}-data" = {
            description = "Verify a rotating subset of the ${backupName} Restic repository";
            wants = ["network-online.target"];
            after = ["network-online.target"];
            environment.RESTIC_PASSWORD_FILE = config.sops.secrets.restic_repository_password.path;
            environment.RESTIC_CACHE_DIR = "/var/cache/restic-backups-${backupName}";
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = config.sops.templates."restic-b2.env".path;
              ExecStart = "${pkgs.restic}/bin/restic check --with-cache --read-data-subset=5%";
              CacheDirectory = "restic-backups-${backupName}";
              CacheDirectoryMode = "0700";
            };
          };
        };

        timers."restic-check-${backupName}-data" = {
          description = "Weekly Restic data-integrity verification";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = "Sun *-*-* 05:00:00";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
        };

        tmpfiles.rules = [
          "d /var/backup 0700 root root - -"
          "d ${backupStage} 0700 root root - -"
        ];
      };
    };
  }
