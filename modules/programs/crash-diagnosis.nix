{
  delib,
  lib,
  pkgs,
  ...
}: let
  diagnoseCrashSkill = pkgs.writeTextDir "share/crash-diagnosis/SKILL.md" ''
    ---
    name: diagnose-crash
    description: >
      Diagnose a Linux user-process crash from a systemd-coredump entry. Use when
      launched from a crash notification or when asked why a program dumped core.
      Work read-only, keep core contents private, and distinguish evidence from inference.
    ---

    # Diagnose a systemd-coredump crash

    Establish what happened from local evidence. Do not edit files, change configuration,
    install packages, build or switch a NixOS generation, restart services, mute future
    notifications, or file/comment on an upstream issue during this diagnosis.

    ## Privacy boundary

    A core is a copy of process memory and may contain passwords, tokens, private documents,
    message contents, and other secrets.

    - Never upload, attach, share, or copy a raw core outside this machine.
    - Do not print `COREDUMP_ENVIRON` or broadly dump process memory.
    - Begin with metadata and stack frames. Inspect locals or memory only when the existing
      evidence gives a concrete reason, and explain the privacy risk first.
    - Extract a core only to a fresh `mktemp` path, keep it mode 0600, and remove it with a
      trap before finishing.

    ## Select the exact crash

    The initial prompt supplies a boot ID and PID. Always use both so PID reuse cannot select
    a different crash:

    ```bash
    coredumpctl info "COREDUMP_PID=<pid>" "_BOOT_ID=<boot-id>" --no-pager
    ```

    Record the executable, command line, signal and signal code, timestamp, user unit/cgroup,
    storage state, truncation state, and the stack already recorded by systemd-coredump.

    Use `coredumpctl list` to determine whether the same executable repeatedly crashes or
    whether several applications failed in the same time window. Do not inspect unrelated
    cores beyond the metadata needed to establish that pattern.

    ## Rule out system-level causes

    Check resource exhaustion before blaming the application:

    - `free -h`
    - journal messages around the crash for the kernel OOM killer or systemd-oomd
    - GPU reset, I/O, filesystem, portal, compositor, and service errors near the timestamp

    Correlate the crash against recent system generations, package/configuration changes,
    and the executable's immutable `/nix/store` path. A store path is strong version evidence;
    it is not by itself proof that NixOS or this configuration caused the crash.

    For a Nix store executable, derive the containing output path and inspect it read-only:

    ```bash
    nix-store -q --deriver /nix/store/<hash>-<name>
    nix-store -q --references /nix/store/<hash>-<name>
    ```

    ## Symbolize carefully

    The Arch Linux debuginfod instructions commonly shown for Omarchy do not apply to NixOS
    store builds. GDB automatically uses debug data already exposed through
    `NIX_DEBUG_INFO_DIRS`. If symbols are unavailable, say so; do not substitute guessed
    function names and do not build or download debug outputs without asking in the report.

    When the saved core is present and more stack detail is useful:

    ```bash
    core=$(mktemp -t crash-XXXXXX.core)
    chmod 0600 "$core"
    trap 'rm -f "$core"' EXIT
    coredumpctl dump "COREDUMP_PID=<pid>" "_BOOT_ID=<boot-id>" --output="$core"
    gdb -q <executable> "$core" \
      -batch \
      -ex 'set pagination off' \
      -ex 'thread apply all bt'
    ```

    Read all thread stacks, not just frame zero. Look for work in flight such as GPU queues,
    image loaders, IPC readers, allocators, extensions, plugins, injected libraries, or
    deleted mappings. Treat third-party code as a lead, not a verdict.

    ## Report

    Finish with:

    1. What crashed and what it was doing.
    2. What the evidence proves.
    3. The most likely mechanism, explicitly labeled as inference where appropriate.
    4. Whether data loss or recurrence is likely.
    5. The smallest reasonable next step, including any additional symbols or reproduction
       needed. Ask before any configuration change, package build, service restart, or
       upstream report.

    If the cause remains ambiguous, say that plainly. A bounded diagnosis is more useful
    than confident speculation.
  '';

  crashDiagnose = pkgs.writeShellApplication {
    name = "crash-diagnose";
    runtimeInputs = with pkgs; [
      coreutils
      elfutils
      findutils
      gdb
      git
      gnugrep
      jq
      nix
      procps
      systemd
      util-linux
    ];
    text = ''
      boot_id="''${1:-}"
      pid="''${2:-}"

      if [[ ! "$boot_id" =~ ^[0-9a-fA-F]{32}$ ]]; then
        echo "Invalid boot ID: $boot_id" >&2
        exit 2
      fi
      if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        echo "Invalid PID: $pid" >&2
        exit 2
      fi
      boot_id="''${boot_id,,}"
      pid=$((10#$pid))

      coredumpctl_bin=${lib.escapeShellArg (lib.getExe' pkgs.systemd "coredumpctl")}
      if [[ -n ''${CRASH_DIAGNOSIS_COREDUMPCTL:-} ]]; then
        coredumpctl_bin=$CRASH_DIAGNOSIS_COREDUMPCTL
      fi

      metadata="$($coredumpctl_bin info "COREDUMP_PID=$pid" "_BOOT_ID=$boot_id" --json=short 2>/dev/null || true)"
      if ! ${lib.getExe pkgs.jq} -e \
        --arg boot_id "$boot_id" \
        --argjson pid "$pid" \
        'type == "object" and .BootID == $boot_id and .PID == $pid' \
        <<<"$metadata" >/dev/null; then
        echo "No coredump found for boot $boot_id and PID $pid" >&2
        exit 1
      fi

      process="$(${lib.getExe pkgs.jq} -r '.Executable // .Command // .ThreadName // "unknown"' <<<"$metadata")"
      executable="$(${lib.getExe pkgs.jq} -r '.Executable // "unknown"' <<<"$metadata")"
      signal="$(${lib.getExe pkgs.jq} -r 'if .SignalName then "SIG" + .SignalName elif .Signal then "signal " + (.Signal | tostring) else "unknown" end' <<<"$metadata")"
      timestamp="$(${lib.getExe pkgs.jq} -r '.Timestamp // "unknown"' <<<"$metadata")"
      process="''${process##*/}"
      process="''${process//$'\n'/ }"
      process="''${process//$'\r'/ }"
      process="''${process:0:120}"

      prompt=$(printf '%s\n' \
        "A process dumped core on this NixOS machine. Diagnose it read-only." \
        "" \
        "Crash identity:" \
        "  boot ID:    $boot_id" \
        "  PID:        $pid" \
        "  process:    $process" \
        "  executable: $executable" \
        "  signal:     $signal" \
        "  timestamp:  $timestamp microseconds since the Unix epoch" \
        "" \
        "Use the loaded diagnose-crash skill. Start with the exact boot-ID/PID" \
        "coredumpctl match, do not inspect unrelated cores, and never upload the raw core.")

      pi_bin="''${CRASH_DIAGNOSIS_PI:-}"
      if [[ -z "$pi_bin" ]]; then
        pi_bin=$(command -v pi || true)
      fi
      if [[ -z "$pi_bin" || ! -x "$pi_bin" ]]; then
        echo "Pi is not available in the graphical-session PATH" >&2
        exit 1
      fi

      ghostty_bin="''${CRASH_DIAGNOSIS_GHOSTTY:-${lib.getExe pkgs.ghostty}}"
      workspace="''${CRASH_DIAGNOSIS_WORKSPACE:-$HOME/nix-config}"
      if [[ ! -d "$workspace" ]]; then
        workspace=$HOME
      fi
      cd "$workspace"

      "$ghostty_bin" +new-window -e \
        "$pi_bin" \
        --approve \
        --tools read,bash,grep,find,ls \
        --skill ${lib.escapeShellArg "${diagnoseCrashSkill}/share/crash-diagnosis/SKILL.md"} \
        --name "Crash: $process ($pid)" \
        "$prompt"
    '';
  };

  crashWatch = pkgs.writeShellApplication {
    name = "crash-watch";
    runtimeInputs = with pkgs; [
      coreutils
      inotify-tools
      jq
      libnotify
      systemd
    ];
    text = ''
      coredump_dir="''${CRASH_DIAGNOSIS_COREDUMP_DIR:-/var/lib/systemd/coredump}"
      dedupe_seconds="''${CRASH_DIAGNOSIS_DEDUPE_SECONDS:-60}"
      ignore_pattern="''${CRASH_DIAGNOSIS_IGNORE:-}"
      current_uid=$(${lib.getExe' pkgs.coreutils "id"} -u)

      coredumpctl_bin=${lib.escapeShellArg (lib.getExe' pkgs.systemd "coredumpctl")}
      inotifywait_bin=${lib.escapeShellArg (lib.getExe' pkgs.inotify-tools "inotifywait")}
      notify_send_bin=${lib.escapeShellArg (lib.getExe pkgs.libnotify)}
      systemd_run_bin=${lib.escapeShellArg (lib.getExe' pkgs.systemd "systemd-run")}
      launcher_bin=${lib.escapeShellArg (lib.getExe crashDiagnose)}

      [[ -n ''${CRASH_DIAGNOSIS_COREDUMPCTL:-} ]] && coredumpctl_bin=$CRASH_DIAGNOSIS_COREDUMPCTL
      [[ -n ''${CRASH_DIAGNOSIS_INOTIFYWAIT:-} ]] && inotifywait_bin=$CRASH_DIAGNOSIS_INOTIFYWAIT
      [[ -n ''${CRASH_DIAGNOSIS_NOTIFY_SEND:-} ]] && notify_send_bin=$CRASH_DIAGNOSIS_NOTIFY_SEND
      [[ -n ''${CRASH_DIAGNOSIS_LAUNCHER:-} ]] && launcher_bin=$CRASH_DIAGNOSIS_LAUNCHER

      if [[ ! "$dedupe_seconds" =~ ^[0-9]+$ ]]; then
        echo "CRASH_DIAGNOSIS_DEDUPE_SECONDS must be a non-negative integer" >&2
        exit 2
      fi
      if [[ ! -d "$coredump_dir" ]]; then
        echo "Coredump directory does not exist: $coredump_dir" >&2
        exit 1
      fi

      declare -A last_notified

      launch_diagnosis() {
        local boot_id=$1 pid=$2 unit

        if [[ ''${CRASH_DIAGNOSIS_LAUNCH_DIRECT:-false} == true ]]; then
          "$launcher_bin" "$boot_id" "$pid"
          return
        fi

        unit="crash-diagnosis-''${boot_id:0:12}-$pid"
        "$systemd_run_bin" \
          --user \
          --collect \
          --quiet \
          --service-type=exec \
          --unit="$unit" \
          "$launcher_bin" "$boot_id" "$pid"
      }

      offer_diagnosis() {
        local name=$1 boot_id=$2 pid=$3 selected

        selected="$($notify_send_bin \
          --app-name="Crash Diagnostics" \
          --urgency=critical \
          --icon=dialog-error \
          --action="diagnose=Diagnose with AI" \
          "Process crashed: $name" \
          "Inspect the saved core with Pi, or close this notification." || true)"

        if [[ "$selected" == diagnose ]]; then
          launch_diagnosis "$boot_id" "$pid"
        fi
      }

      lookup_metadata() {
        local boot_id=$1 pid=$2 attempt metadata

        for ((attempt = 0; attempt < 20; attempt++)); do
          metadata="$($coredumpctl_bin info "COREDUMP_PID=$pid" "_BOOT_ID=$boot_id" --json=short 2>/dev/null || true)"
          if ${lib.getExe pkgs.jq} -e \
            --arg boot_id "$boot_id" \
            --argjson pid "$pid" \
            'type == "object" and .BootID == $boot_id and .PID == $pid' \
            <<<"$metadata" >/dev/null; then
            printf '%s\n' "$metadata"
            return 0
          fi
          sleep 0.1
        done

        return 1
      }

      "$inotifywait_bin" \
        --monitor \
        --quiet \
        --event create \
        --event moved_to \
        --format '%f' \
        "$coredump_dir" |
        while IFS= read -r filename; do
          if [[ ! "$filename" =~ ^core\.(.*)\.([0-9]+)\.([0-9a-fA-F]{32})\.([0-9]+)\.[0-9]+(\.[^.]+)?$ ]]; then
            continue
          fi

          fallback_name=''${BASH_REMATCH[1]}
          uid=''${BASH_REMATCH[2]}
          boot_id=''${BASH_REMATCH[3],,}
          pid=''${BASH_REMATCH[4]}

          ((uid == current_uid)) || continue

          metadata=$(lookup_metadata "$boot_id" "$pid" || true)
          if [[ -n "$metadata" ]]; then
            name="$(${lib.getExe pkgs.jq} -r '.Executable // .Command // .ThreadName // "unknown"' <<<"$metadata")"
            name="''${name##*/}"
          else
            name=$fallback_name
          fi

          name="''${name//$'\n'/ }"
          name="''${name//$'\r'/ }"
          name="''${name:0:120}"
          [[ -n "$name" && "$name" != "." && "$name" != ".." ]] || name=unknown

          [[ -n "$ignore_pattern" && "$name" =~ $ignore_pattern ]] && continue
          [[ "$name" == crash-watch || "$name" == crash-diagnose ]] && continue

          now=$(${lib.getExe' pkgs.coreutils "date"} +%s)
          last=''${last_notified[$name]:-0}
          (((now - last) >= dedupe_seconds)) || continue

          last_notified[$name]=$now
          offer_diagnosis "$name" "$boot_id" "$pid" &
        done
    '';
  };
in
  delib.module {
    name = "programs.crash-diagnosis";

    options.programs.crash-diagnosis = with delib; {
      enable = boolOption false;
    };

    home.ifEnabled = {
      home = {
        packages = [
          crashDiagnose
          crashWatch
        ];

        file.".pi/agent/skills/diagnose-crash/SKILL.md".source = "${diagnoseCrashSkill}/share/crash-diagnosis/SKILL.md";
      };

      systemd.user.services.crash-watch = {
        Unit = {
          Description = "Watch systemd-coredump and offer a Pi diagnosis";
          After = [
            "caelestia.service"
            "hyprland-session.target"
          ];
          PartOf = ["hyprland-session.target"];
        };

        Service = {
          Type = "simple";
          ExecStart = lib.getExe crashWatch;
          Restart = "always";
          RestartSec = 3;
          NoNewPrivileges = true;
          PrivateTmp = true;
        };

        Install.WantedBy = ["hyprland-session.target"];
      };
    };
  }
