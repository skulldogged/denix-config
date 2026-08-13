{
  delib,
  pkgs,
  ...
}: let
  herdr = pkgs.herdr.overrideAttrs (old: {
    patches = (old.patches or []) ++ [./herdr-workspace-picker.patch];
  });

  # Herdr persists a workspace's launch environment and injects it into the
  # root pane, later tabs and splits, and restored panes. Dispatch SSH here so
  # remote spaces never start Fish or evaluate its interactive configuration.
  herdrPaneShell = pkgs.writeShellApplication {
    name = "herdr-pane-shell";
    text = ''
      host="''${HERDR_SSH_HOST:-}"
      if [[ -n "$host" ]]; then
        if [[ "$host" == -* || "$host" =~ [[:space:]] ]]; then
          printf 'Invalid SSH target in this Herdr space: %s\n' "$host" >&2
          exit 2
        fi

        # Reuse one authenticated SSH connection per Herdr space. The first
        # pane may prompt for a password; later tabs and splits open channels
        # through that master connection instead of authenticating again.
        workspace_id="''${HERDR_WORKSPACE_ID:-standalone}"
        if [[ ! "$workspace_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
          printf 'Invalid Herdr workspace ID: %s\n' "$workspace_id" >&2
          exit 2
        fi
        control_root="''${XDG_RUNTIME_DIR:-$HOME/.cache}/herdr/ssh-control"
        ${pkgs.lib.getExe' pkgs.coreutils "install"} -d -m 700 "$control_root"

        exec ${pkgs.lib.getExe pkgs.openssh} \
          -o ControlMaster=auto \
          -o ControlPersist=10m \
          -o "ControlPath=$control_root/$workspace_id-%C" \
          "$host"
      fi
      exec ${pkgs.lib.getExe pkgs.fish} "$@"
    '';
  };

  herdrRemoteSession = pkgs.writeShellApplication {
    name = "herdr-remote-session";
    runtimeInputs = [herdr];
    text = ''
      target="''${1:-}"
      if [[ -z "$target" ]]; then
        echo "usage: herdr-remote-session SSH_TARGET" >&2
        exit 2
      fi

      set +e
      herdr --remote "$target"
      status=$?
      set -e

      if [[ "$status" -ne 0 ]]; then
        printf '\nRemote Herdr exited with status %s.\n' "$status" >&2
        printf 'Press Enter to close this window.' >&2
        IFS= read -r _ || true
      fi
      exit "$status"
    '';
  };

  herdrSshPicker = pkgs.writeShellApplication {
    name = "herdr-ssh-picker";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      fzf
      gawk
      gnused
      herdr
      wezterm
    ];
    text = ''
      mode="''${1:-}"

      case "$mode" in
        workspace | remote) ;;
        *)
          echo "usage: herdr-ssh-picker workspace|remote" >&2
          exit 2
          ;;
      esac

      pause_on_error() {
        printf '\n%s\n' "$1" >&2
        printf 'Press Enter to close this popup.' >&2
        IFS= read -r _ || true
        exit 1
      }

      candidates="$({
        # Host aliases declared in the SSH client config. NixOS writes
        # programs.ssh.extraConfig to the system-wide file, and user-level
        # includes live under ~/.ssh. Only named Host aliases are listed
        # (the Host * catch-all and wildcard patterns are filtered below),
        # never the raw known_hosts entries.
        if [[ -r /etc/ssh/ssh_config ]]; then
          awk '
            tolower($1) == "host" {
              for (field = 2; field <= NF; field++) print $field
            }
          ' /etc/ssh/ssh_config
        fi

        if [[ -d "$HOME/.ssh" ]]; then
          while IFS= read -r -d "" file; do
            awk '
              tolower($1) == "host" {
                for (field = 2; field <= NF; field++) print $field
              }
            ' "$file"
          done < <(
            find "$HOME/.ssh" -maxdepth 3 -type f \
              \( -name config -o -name "*.conf" \) -print0
          )
        fi
      } | awk '
        {
          gsub(/,/, " ")
          for (field = 1; field <= NF; field++) {
            candidate = $field
            if (candidate !~ /^(\||\[)/ && candidate !~ /[*!?]/) print candidate
          }
        }
      ' | sort -u)"

      local_choice="Local (this machine)"
      picker_input="$candidates"
      picker_header="Select a host, or type any SSH target and press Enter"
      if [[ "$mode" == workspace ]]; then
        picker_input="$(printf '%s\n%s\n' "$local_choice" "$candidates")"
        picker_header="Select local or an SSH host for the new space"
      fi

      fzf_status=0
      selection="$(
        printf '%s\n' "$picker_input" |
          fzf \
            --print-query \
            --prompt="Machine> " \
            --header="$picker_header"
      )" || fzf_status=$?

      case "$fzf_status" in
        0)
          host="$(printf '%s\n' "$selection" | awk 'NF { selected = $0 } END { print selected }')"
          ;;
        1)
          # fzf returns 1 for an unmatched query but still prints that query.
          host="$(printf '%s\n' "$selection" | awk 'NF { print; exit }')"
          ;;
        130)
          exit 0
          ;;
        *)
          pause_on_error "The SSH host picker failed with status $fzf_status."
          ;;
      esac
      if [[ -z "$host" ]]; then
        exit 0
      fi

      local_selection=false
      if [[ "$mode" == workspace && "$host" == "$local_choice" ]]; then
        local_selection=true
      elif [[ "$host" == -* || "$host" =~ [[:space:]] ]]; then
        pause_on_error "SSH targets cannot begin with '-' or contain whitespace."
      fi

      case "$mode" in
        workspace)
          if [[ "$local_selection" == true ]]; then
            if ! response="$(herdr workspace create --focus 2>&1)"; then
              pause_on_error "$response"
            fi
          elif ! response="$(
            herdr workspace create \
              --label "ssh:$host" \
              --env "HERDR_SSH_HOST=$host" \
              --focus 2>&1
          )"; then
            pause_on_error "$response"
          fi
          ;;
        remote)
          if ! wezterm start -- \
            env \
              -u HERDR_ENV \
              -u HERDR_PANE_ID \
              -u HERDR_TAB_ID \
              -u HERDR_WORKSPACE_ID \
              -u HERDR_SOCKET_PATH \
              ${pkgs.lib.getExe herdrRemoteSession} "$host"; then
            pause_on_error "WezTerm could not open the remote Herdr window."
          fi
          ;;
      esac
    '';
  };
in
  delib.module {
    name = "programs.herdr";

    options.programs.herdr = with delib; {
      enable = boolOption false;
    };

    home.ifEnabled = {
      # The Home Manager module owns package installation, TOML generation, and
      # reloading the running server when its generated config changes.
      programs.herdr = {
        enable = true;
        package = herdr;
        settings = {
          onboarding = false;

          theme.name = "catppuccin";

          terminal = {
            default_shell = pkgs.lib.getExe herdrPaneShell;
            shell_mode = "non_login";
            new_cwd = "home";
          };

          update = {
            # Herdr itself is upgraded by the flake; agent detection manifests
            # may still refresh independently between Nix rebuilds.
            version_check = false;
            manifest_check = true;
          };

          # Keep the prefix bindings while mirroring the old WezTerm shortcuts.
          keys = {
            focus_pane_left = ["prefix+h" "ctrl+shift+h"];
            focus_pane_down = ["prefix+j" "ctrl+shift+j"];
            focus_pane_up = ["prefix+k" "ctrl+shift+k"];
            focus_pane_right = ["prefix+l" "ctrl+shift+l"];
            previous_tab = ["prefix+p" "ctrl+shift+tab"];
            next_tab = ["prefix+n" "ctrl+tab"];
            previous_workspace = ["prefix+shift+k" "ctrl+alt+k"];
            next_workspace = ["prefix+shift+j" "ctrl+alt+j"];
            switch_workspace = ["prefix+shift+1..9" "ctrl+alt+1..9"];
            new_workspace = ["prefix+shift+n" "ctrl+shift+s"];
            new_tab = ["prefix+c" "ctrl+shift+t"];
            switch_tab = ["prefix+1..9" "ctrl+shift+1..9"];
            split_vertical = ["prefix+v" "ctrl+shift+enter"];
            split_horizontal = ["prefix+minus" "ctrl+alt+enter"];
            close_tab = ["prefix+shift+x" "ctrl+shift+w"];
            zoom = ["prefix+z" "ctrl+shift+z"];

            command = [
              {
                key = "ctrl+shift+n";
                type = "shell";
                description = "open the focused pane in another WezTerm window";
                command = ''
                  terminal_id="$(${pkgs.lib.getExe herdr} pane get "$HERDR_ACTIVE_PANE_ID" | ${pkgs.lib.getExe pkgs.jq} -r '.result.pane.terminal_id')"
                  exec ${pkgs.lib.getExe pkgs.wezterm} start -- ${pkgs.lib.getExe herdr} terminal attach "$terminal_id"
                '';
              }
              {
                key = "ctrl+shift+g";
                type = "popup";
                description = "open a remote Herdr session in another WezTerm window";
                command = "${pkgs.lib.getExe herdrSshPicker} remote";
                width = "70%";
                height = "70%";
              }
            ];
          };

          ui = {
            sidebar_width = 28;
            new_workspace_command = "${pkgs.lib.getExe herdrSshPicker} workspace";
            sidebar.agents.rows = [
              ["state_icon" "workspace" "tab"]
              ["agent" "$summary"]
            ];
            hide_tab_bar_when_single_tab = true;
            prompt_new_tab_name = false;
            show_agent_labels_on_pane_borders = true;
            toast = {
              delivery = "system";
              delay_seconds = 2;
            };
            sound.enabled = false;
          };

          session.resume_agents_on_restore = true;

          # Herdr must decode pane Kitty graphics and repaint them into the
          # Kitty-compatible outer terminal; raw escape passthrough is not enough.
          experimental.kitty_graphics = true;
        };
      };

      # Home Manager does not manage Herdr's Pi integration or agent skill.
      home.file = {
        ".pi/agent/extensions/herdr-agent-state.ts".source = "${herdr.src}/src/integration/assets/pi/herdr-agent-state.ts";
        ".pi/agent/skills/herdr/SKILL.md".source = "${herdr}/share/herdr/skills/herdr/SKILL.md";
      };
    };
  }
