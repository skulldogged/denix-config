{
  delib,
  pkgs,
  lib,
  ...
}: let
  t3Start = pkgs.writeText "t3Start" ''
    #!/usr/bin/env python3
    """Start the pinned T3 CLI independently of the graphical desktop."""
    import json, os, pathlib, shutil, sqlite3, subprocess
    home = pathlib.Path('/home/marshall')
    state = home / '.t3/userdata'
    cli = (home / '.nix-profile/bin/t3').resolve()
    desktop = (home / '.nix-profile/bin/t3code').resolve()
    if desktop.parent != cli.parent and str(cli.parent / 't3code') not in desktop.read_text():
        raise SystemExit('Installed CLI differs from the installed desktop fork.')

    # Refuse a second backend against the same database, even if a GUI was opened directly.
    runtime = state / 'server-runtime.json'
    if runtime.exists():
        pid = json.loads(runtime.read_text()).get('pid')
        if pid and pathlib.Path(f'/proc/{pid}').exists():
            cmd = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes()
            if b't3' in cmd:
                raise SystemExit('An existing T3 backend is still using ~/.t3; refusing duplicate startup.')
    backup = home / '.t3/backups/before-background-server'
    if not backup.exists():
        backup.mkdir(parents=True, mode=0o700)
        for db in state.glob('*.sqlite'):
            with sqlite3.connect(db) as src, sqlite3.connect(backup / db.name) as dst:
                src.backup(dst)
        for name in ('settings.json', 'client-settings.json', 'desktop-settings.json'):
            if (state / name).exists(): shutil.copy2(state / name, backup / name)
    for key in ('DISPLAY','WAYLAND_DISPLAY','HYPRLAND_INSTANCE_SIGNATURE','AQ_DRM_DEVICES'):
        os.environ.pop(key, None)
    os.execv(str(cli), ['t3','serve','--host','192.168.122.1','--port','3774','--base-dir',str(home / '.t3'),'--no-browser'])
  '';
in
  delib.module {
    name = "navis";

    nixos.ifEnabled = let
      switchFiles = [
        "navis-windows-switch.py"
        "navis-windows-gpu.py"
        "navis-gpu-binding.py"
      ];
      switchLauncher = pkgs.writeShellScript "windows-switch-control" ''
        set -euo pipefail
        case "''${1:-}" in windows|linux) ;; *) echo 'Usage: windows-switch-control windows|linux' >&2; exit 2;; esac
        exec /run/wrappers/bin/sudo -n /run/current-system/sw/bin/python3 /etc/navis-windows-switch/navis-windows-switch.py "$1"
      '';
      switchPackage = pkgs.runCommand "navis-windows-switch" {} (
        "mkdir -p $out\n"
        + lib.concatMapStringsSep "\n"
        (name: "cp ${../../../tools/vfio + "/${name}"} $out/${name}")
        switchFiles
        + "\nln -s ${switchLauncher} $out/windows-switch-control\n"
      );
      control = "${pkgs.python3}/bin/python3 /etc/navis-windows-switch/navis-windows-switch.py";
      switchPath = with pkgs; [python3 libvirt systemd util-linux coreutils kmod procps pciutils usbutils iproute2 "/run/current-system/sw" "/run/wrappers"];
    in {
      environment.etc."navis-windows-switch".source = switchPackage;
      # Remain active across desktop sessions and rebuilds. Only host shutdown
      # (or an explicit administrator stop) shuts down the direct-disk guest.
      systemd.services.navis-windows-background = {
        description = "Windows background VM with clean host shutdown";
        wantedBy = ["multi-user.target"];
        after = ["libvirtd.service" "libvirt-guests.service" "network-online.target"];
        wants = ["network-online.target"];
        requires = ["libvirtd.service"];
        restartIfChanged = false;
        stopIfChanged = false;
        path = switchPath;
        unitConfig.RequiresMountsFor = ["/var/lib/libvirt" "/var/lib/navis-windows-switch"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${control} background";
          ExecStop = "${control} shutdown";
          TimeoutStartSec = "120s";
          TimeoutStopSec = "infinity";
          Environment = "PYTHONDONTWRITEBYTECODE=1";
        };
      };
      systemd.services.navis-windows-request = {
        description = "Switch the GPU to running Windows";
        after = ["navis-windows-background.service"];
        requires = ["navis-windows-background.service"];
        path = switchPath;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${control} _foreground";
          TimeoutStartSec = "10min";
          Environment = "PYTHONDONTWRITEBYTECODE=1";
        };
      };

      systemd.services.navis-windows-usb = {
        description = "Follow external USB devices while Windows is active";
        bindsTo = ["navis-windows-gpu.service"];
        after = ["navis-windows-gpu.service"];
        path = switchPath;
        serviceConfig = {
          ExecStart = "${control} _usb";
          Environment = "PYTHONDONTWRITEBYTECODE=1";
          TimeoutStopSec = "20s";
        };
      };

      virtualisation.libvirtd = {
        enable = true;
        qemu = {
          package = pkgs.qemu_kvm;
          runAsRoot = false;
          swtpm.enable = true;
        };
      };

      # Compress idle guest pages without resizing Windows' 48 GiB allocation.
      zramSwap = {
        enable = true;
        # Logical capacity, allocated/compressed on demand; not reserved RAM.
        memoryPercent = 100;
      };

      programs.virt-manager.enable = true;
      users.users.marshall.extraGroups = ["libvirtd"];
      users.users.marshall.linger = lib.mkForce true;
      networking.firewall.interfaces.virbr0.allowedTCPPorts = [3774 445];

      # Share the mounted NTFS filesystem, never attach it to two kernels at once.
      services.samba = {
        enable = true;
        nmbd.enable = false;
        winbindd.enable = false;
        openFirewall = false;
        settings = {
          global = {
            interfaces = "192.168.122.1/24";
            "bind interfaces only" = "yes";
            "smb ports" = "445";
            "map to guest" = "Never";
            "server min protocol" = "SMB3_00";
            "server signing" = "mandatory";
            "load printers" = "no";
            "disable spoolss" = "yes";
          };
          Shared = {
            path = "/mnt/Shared";
            "read only" = "no";
            "valid users" = "marshall";
            "force user" = "marshall";
            "guest ok" = "no";
          };
        };
      };
      systemd.services.samba-smbd.unitConfig.RequiresMountsFor = lib.mkForce ["/mnt/Shared" "/var/lib/samba"];

      # Udev/CDI refreshes and the telemetry collector must not reload NVIDIA
      # while Windows owns it. The handoff pauses them and recovery restarts them.
      systemd.services.navis-hardware-telemetry.serviceConfig.ExecCondition = "${pkgs.coreutils}/bin/test ! -e /sys/bus/pci/drivers/vfio-pci/0000:01:00.0";
      systemd.services.navis-hardware-telemetry.unitConfig.ConditionPathExists = "!/run/navis-windows-gpu/host-gpu-probes.json";
      systemd.services.nvidia-container-toolkit-cdi-generator.serviceConfig.ExecCondition = "${pkgs.coreutils}/bin/test ! -e /sys/bus/pci/drivers/vfio-pci/0000:01:00.0";
      systemd.services.nvidia-container-toolkit-cdi-generator.unitConfig.ConditionPathExists = "!/run/navis-windows-gpu/host-gpu-probes.json";

      # libvirt encrypts its persistent secret key with this systemd host key.
      environment.persistence."/persist".files = ["/var/lib/systemd/credential.secret"];

      # swtpm_setup runs as tss and needs a writable, persistent local CA.
      environment.persistence."/persist".directories = [
        "/var/lib/samba"
        "/var/lib/navis-windows-switch"
        {
          directory = "/var/lib/swtpm-localca";
          user = "tss";
          group = "tss";
          mode = "0700";
        }
      ];
    };

    home.ifEnabled = {
      # The same installed personal fork and ~/.t3 database as the desktop.
      # No WantedBy: the GPU controller owns the server's start/stop lifecycle.
      systemd.user.services.navis-t3-server = {
        Unit = {
          Description = "T3 Linux backend independent of Hyprland";
          StartLimitIntervalSec = 300;
          StartLimitBurst = 5;
        };
        Service = {
          Type = "simple";
          WorkingDirectory = "/home/marshall";
          Environment = [
            "PATH=/home/marshall/.nix-profile/bin:/run/current-system/sw/bin:/run/wrappers/bin"
            "PYTHONDONTWRITEBYTECODE=1"
          ];
          ExecStart = "${pkgs.python3}/bin/python3 ${t3Start}";
          Restart = "no";
          KillMode = "mixed";
          TimeoutStopSec = 45;
          UMask = "0077";
          StandardOutput = "append:/home/marshall/.t3/userdata/logs/windows-server.log";
          StandardError = "append:/home/marshall/.t3/userdata/logs/windows-server.log";
        };
      };
      # Replace the identical-purpose manually installed unit on first activation.
      xdg.configFile."systemd/user/navis-t3-server.service".force = true;
      home.packages = [
        (pkgs.writeShellScriptBin "navis-t3-pair" ''
          set -euo pipefail
          exec "$HOME/.nix-profile/bin/t3" auth pairing create --base-dir "$HOME/.t3" \
            --ttl 1h --label 'Navis Windows desktop' --base-url http://192.168.122.1:3774
        '')
      ];
      xdg.desktopEntries.navis-windows = {
        name = "Switch to Windows";
        comment = "Continue Windows on the RTX 3050; closes Linux apps";
        exec = "/etc/navis-windows-switch/windows-switch-control windows";
        icon = "computer";
        terminal = false;
        categories = ["System"];
      };
    };
  }
