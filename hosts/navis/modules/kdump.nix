{
  delib,
  pkgs,
  ...
}:
delib.module {
  name = "navis";

  nixos.ifEnabled = {
    boot.crashDump = {
      enable = true;
      reservedMemory = "512M";
      kernelParams = [
        "systemd.unit=kdump-save.target"
        "boot.shell_on_fail"
        "loglevel=7"
      ];
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
  };
}
