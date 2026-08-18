{
  config,
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "navis";

  nixos.ifEnabled = {
    hardware.rasdaemon = {
      enable = true;
      record = true;
    };

    systemd = {
      tmpfiles.rules = [
        "d /var/lib/systemd/bert 0700 root root -"
        "d /var/lib/navis-diagnostics 0700 root root -"
        "d /var/lib/rasdaemon 0700 root root -"
      ];

      services = {
        navis-bert-archive = {
          description = "Archive firmware boot error records";
          wantedBy = ["multi-user.target"];
          after = ["local-fs.target" "systemd-journald.service"];

          unitConfig = {
            ConditionPathExists = "/sys/firmware/acpi/tables/data/BERT";
            RequiresMountsFor = "/var/lib/systemd/bert";
          };

          serviceConfig = {
            Type = "oneshot";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = ["/var/lib/systemd/bert"];
          };

          path = [
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.systemd
          ];

          script = ''
            set -euo pipefail
            umask 077

            source_file=/sys/firmware/acpi/tables/data/BERT
            output_dir=/var/lib/systemd/bert

            if ! journalctl \
              --boot=0 \
              --dmesg \
              --grep='BERT: Total records found: [1-9][0-9]*' \
              --no-pager \
              --quiet; then
              exit 0
            fi

            boot_id="$(cat /proc/sys/kernel/random/boot_id)"
            timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"
            output_file="$output_dir/$timestamp-$boot_id.bin"
            metadata_file="$output_dir/$timestamp-$boot_id.meta"

            if [[ -e "$output_file" ]]; then
              exit 0
            fi

            mkdir -p "$output_dir"
            cp --reflink=auto "$source_file" "$output_file.tmp"
            chmod 0400 "$output_file.tmp"

            {
              printf 'Captured: %s\n' "$timestamp"
              printf 'Boot ID: %s\n' "$boot_id"
              printf 'Kernel: '
              uname -a
              printf 'System generation: '
              readlink -f /run/current-system
              printf 'BERT bytes: '
              stat --format=%s "$output_file.tmp"
              printf 'BERT SHA-256: '
              sha256sum "$output_file.tmp" | cut --delimiter=' ' --fields=1
            } > "$metadata_file.tmp"
            chmod 0400 "$metadata_file.tmp"

            mv "$output_file.tmp" "$output_file"
            mv "$metadata_file.tmp" "$metadata_file"
            sync "$output_file" "$metadata_file"
          '';
        };

        navis-hardware-telemetry = {
          description = "Record navis hardware telemetry";
          wantedBy = ["multi-user.target"];
          after = ["local-fs.target"];

          unitConfig.RequiresMountsFor = "/var/lib/navis-diagnostics";

          serviceConfig = {
            Type = "simple";
            Restart = "always";
            RestartSec = "10s";
            UMask = "0077";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            ReadWritePaths = ["/var/lib/navis-diagnostics"];
          };

          path = [
            config.hardware.nvidia.package
            pkgs.coreutils
            pkgs.jq
          ];

          script = ''
            set -uo pipefail
            umask 077

            output_dir=/var/lib/navis-diagnostics
            output_file="$output_dir/telemetry.jsonl"
            boot_id="$(cat /proc/sys/kernel/random/boot_id)"

            read_path() {
              if [[ -r "$1" ]]; then
                tr -d '\n' < "$1"
              fi
            }

            hwmon_value() {
              local wanted_name="$1"
              local attribute="$2"
              local directory

              for directory in /sys/class/hwmon/hwmon*; do
                if [[ -r "$directory/name" ]] \
                  && [[ "$(read_path "$directory/name")" == "$wanted_name" ]] \
                  && [[ -r "$directory/$attribute" ]]; then
                  read_path "$directory/$attribute"
                  return
                fi
              done
            }

            hwmon_values() {
              local wanted_name="$1"
              local attribute="$2"
              local directory
              local values=""
              local value

              for directory in /sys/class/hwmon/hwmon*; do
                if [[ -r "$directory/name" ]] \
                  && [[ "$(read_path "$directory/name")" == "$wanted_name" ]] \
                  && [[ -r "$directory/$attribute" ]]; then
                  value="$(read_path "$directory/$attribute")"
                  values="''${values:+$values,}$value"
                fi
              done

              printf '%s' "$values"
            }

            thermal_zone_values() {
              local zone
              local zone_type
              local zone_temp
              local values=""

              for zone in /sys/class/thermal/thermal_zone*; do
                if [[ -r "$zone/type" ]] && [[ -r "$zone/temp" ]]; then
                  zone_type="$(read_path "$zone/type")"
                  zone_temp="$(read_path "$zone/temp")"
                  values="''${values:+$values,}$zone_type:$zone_temp"
                fi
              done

              printf '%s' "$values"
            }

            mkdir -p "$output_dir"

            while true; do
              timestamp="$(date --utc --iso-8601=seconds)"
              nvidia_csv="$(
                nvidia-smi \
                  --query-gpu=temperature.gpu,power.draw,utilization.gpu,clocks.current.graphics,memory.used \
                  --format=csv,noheader,nounits 2>/dev/null \
                  | head --lines=1 \
                  || true
              )"

              jq --compact-output --null-input \
                --arg timestamp "$timestamp" \
                --arg boot_id "$boot_id" \
                --arg uptime_seconds "$(cut --delimiter=' ' --fields=1 /proc/uptime)" \
                --arg ac_online "$(read_path /sys/class/power_supply/ACAD/online)" \
                --arg battery_status "$(read_path /sys/class/power_supply/BAT1/status)" \
                --arg battery_capacity_percent "$(read_path /sys/class/power_supply/BAT1/capacity)" \
                --arg battery_voltage_uv "$(read_path /sys/class/power_supply/BAT1/voltage_now)" \
                --arg battery_current_ua "$(read_path /sys/class/power_supply/BAT1/current_now)" \
                --arg battery_power_uw "$(read_path /sys/class/power_supply/BAT1/power_now)" \
                --arg platform_profile "$(read_path /sys/firmware/acpi/platform_profile)" \
                --arg cpu_package_millicelsius "$(hwmon_value coretemp temp1_input)" \
                --arg acpi_zone_millicelsius "$(hwmon_value acpitz temp1_input)" \
                --arg wifi_millicelsius "$(hwmon_value iwlwifi_1 temp1_input)" \
                --arg cpu_fan_rpm "$(hwmon_value asus fan1_input)" \
                --arg gpu_fan_rpm "$(hwmon_value asus fan2_input)" \
                --arg nvme_millicelsius "$(hwmon_values nvme temp1_input)" \
                --arg thermal_zones_millicelsius "$(thermal_zone_values)" \
                --arg nvidia_csv "$nvidia_csv" \
                '{
                  timestamp: $timestamp,
                  boot_id: $boot_id,
                  uptime_seconds: $uptime_seconds,
                  ac_online: $ac_online,
                  battery_status: $battery_status,
                  battery_capacity_percent: $battery_capacity_percent,
                  battery_voltage_uv: $battery_voltage_uv,
                  battery_current_ua: $battery_current_ua,
                  battery_power_uw: $battery_power_uw,
                  platform_profile: $platform_profile,
                  cpu_package_millicelsius: $cpu_package_millicelsius,
                  acpi_zone_millicelsius: $acpi_zone_millicelsius,
                  wifi_millicelsius: $wifi_millicelsius,
                  cpu_fan_rpm: $cpu_fan_rpm,
                  gpu_fan_rpm: $gpu_fan_rpm,
                  nvme_millicelsius: $nvme_millicelsius,
                  thermal_zones_millicelsius: $thermal_zones_millicelsius,
                  nvidia_csv: $nvidia_csv
                }' >> "$output_file"

              sync --data "$output_file"
              sleep 10
            done
          '';
        };
      };
    };

    services.logrotate.settings.navis-hardware-telemetry = {
      files = "/var/lib/navis-diagnostics/telemetry.jsonl";
      frequency = "daily";
      rotate = 7;
      compress = true;
      missingok = true;
      notifempty = true;
      create = "0600 root root";
    };
  };
}
