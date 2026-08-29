{
  delib,
  pkgs,
  lib,
  inputs,
  ...
}:
delib.module {
  name = "home.hyprland";

  options.home.hyprland = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {myconfig, ...}: let
    inherit (pkgs.stdenv.hostPlatform) system;

    snappySwitcher = inputs.snappy-switcher.packages.${system}.default;
    hyprshot = pkgs.hyprshot.overrideAttrs (old: {
      postPatch =
        (old.postPatch or "")
        + ''
          # Active captures do not run slurp, so the selector watchdog only
          # adds an unconditional one-second delay.
          substituteInPlace hyprshot \
            --replace-fail 'begin_grab $OPTION & checkRunning' \
            'if [ "$CURRENT" -eq 1 ]; then
                begin_grab "$OPTION"
            else
                begin_grab "$OPTION" & checkRunning
            fi'
        '';
    });
  in {
    wayland.windowManager.hyprland = let
      inherit (inputs.hyprland.packages.${system}) hyprland;

      hyprlandPlugins = pkgs.hyprlandPlugins.override {inherit hyprland;};
      enableHyprglass = false;

      hyprglass = hyprlandPlugins.mkHyprlandPlugin {
        pluginName = "hyprglass";
        version = "0.7.0";
        src = inputs.hyprglass;

        installPhase = ''
          runHook preInstall

          install -Dm755 hyprglass.so "$out/lib/libhyprglass.so"

          runHook postInstall
        '';

        meta = {
          description = "Liquid Glass window decoration effect for Hyprland";
          homepage = "https://github.com/hyprnux/hyprglass";
          license = lib.licenses.bsd3;
        };
      };
    in {
      enable = true;
      package = null;
      portalPackage = null;
      configType = "lua";
      systemd.variables = ["--all"];

      plugins = lib.optional enableHyprglass hyprglass;

      settings = let
        ddc-brightness = pkgs.writeShellScript "ddc-brightness" ''
          display_serial_num=$(hyprctl monitors -j | jq '.[].serial' --raw-output)

          ddcutil --sn "$display_serial_num" setvcp 10 $@
        '';

        scratchpad = let
          hyprctl = "${hyprland}/bin/hyprctl";
          jq = lib.getExe pkgs.jq;
        in
          pkgs.writeShellScript "hyprscratchpad" ''
            command=$1
            class=$2
            workspace=$3

            if ${hyprctl} -j clients | ${jq} -e --arg class "$class" \
              'any(.[]; .class == $class or .initialClass == $class)' >/dev/null; then
              exec ${hyprctl} dispatch "hl.dsp.workspace.toggle_special('$workspace')"
            fi

            ${hyprctl} dispatch "hl.dsp.workspace.toggle_special('$workspace')"
            exec ${hyprctl} dispatch "hl.dsp.exec_cmd('$command')"
          '';

        mod = "SUPER";
        modC = "SUPER + CTRL";
        modS = "SUPER + SHIFT";

        browser = "helium";
        fileManager = "nautilus";
        terminal = "ghostty";

        zipline-screenshot = pkgs.writeShellScript "zipline-screenshot" ''
          set -e
          TMPFILE=$(mktemp --suffix=.png)
          trap 'rm -f "$TMPFILE"' EXIT

          notify_error() {
            ${lib.getExe pkgs.libnotify} -u critical "Screenshot failed" "$1"
            exit 1
          }

          # Capture screenshot
          if ! ${lib.getExe hyprshot} -s -m "$@" -o "$(dirname "$TMPFILE")" -f "$(basename "$TMPFILE")"; then
            notify_error "Failed to capture screenshot"
          fi

          # Wait for file stability
          while [ "$(stat -c%s "$TMPFILE" 2>/dev/null)" != "$(sleep 0.05; stat -c%s "$TMPFILE" 2>/dev/null)" ]; do :; done

          # Hyprshot exits successfully but leaves the file empty when its selector is cancelled.
          if [ ! -s "$TMPFILE" ]; then
            exit 0
          fi

          # Get token
          TOKEN=$(cat /run/secrets/zipline_token 2>/dev/null | tr -d '\n') || notify_error "Failed to read zipline token"

          # Upload to zipline
          RESPONSE=$(${lib.getExe pkgs.curl} -s \
            -H "Authorization: $TOKEN" \
            -F "file=@$TMPFILE;type=image/png" \
            "https://zip.pupbrained.dev/api/upload") || notify_error "Upload request failed"

          # Parse URL from response
          URL=$(echo "$RESPONSE" | ${lib.getExe pkgs.jq} -r '.files[0].url') || notify_error "Failed to parse upload response"

          # Validate URL is not null/empty
          if [ -z "$URL" ] || [ "$URL" = "null" ]; then
            notify_error "Upload failed: invalid response from server"
          fi

          ${pkgs.wl-clipboard}/bin/wl-copy --type image/png < "$TMPFILE" || notify_error "Failed to copy screenshot to clipboard"

          trap - EXIT
          (
            ACTION=$(${lib.getExe pkgs.libnotify} \
              -i "$TMPFILE" \
              --action="open=Open uploaded URL" \
              "Screenshot uploaded" \
              "Image copied to clipboard" || true)

            if [ "$ACTION" = "open" ]; then
              ${pkgs.xdg-utils}/bin/xdg-open "$URL" >/dev/null 2>&1 || true
            fi

            rm -f "$TMPFILE"
          ) &
        '';

        screenshot = mode: "${zipline-screenshot} ${mode}";

        lua = lib.generators.mkLuaInline;
        toLua = lib.generators.toLua {};
        exec = command: lua "hl.dsp.exec_cmd(${toLua command})";
        mkBind = key: description: dispatcher: mkBindWith key description dispatcher {};
        mkBindWith = key: description: dispatcher: options: {
          _args = [
            key
            dispatcher
            (options // {inherit description;})
          ];
        };
      in {
        config = {
          animations.enabled = true;
          decoration.rounding = 16;
          dwindle.preserve_split = true;
          debug.disable_logs = false;

          cursor = {
            no_hardware_cursors = false;
            use_cpu_buffer = true;
          };

          input = {
            kb_options = "compose:ralt";

            touchpad = {
              clickfinger_behavior = true;
              natural_scroll = true;
            };
          };

          general = {
            border_size = 2;
            gaps_in = 10;
            layout = "scrolling";
            resize_on_border = true;

            col = {
              active_border = "rgba(cba6f7ee)";
              inactive_border = "rgba(595959aa)";
            };
          };

          misc = {
            disable_autoreload = true;
            force_default_wallpaper = 0;
            disable_hyprland_logo = true;
            vrr = 3;
          };
        };

        device = [
          {
            name = "logitech-usb-receiver";
            sensitivity = -0.75;
          }
          {
            name = "logitech-g502-x-plus";
            sensitivity = -0.65;
          }
          {
            name = "logitech-g502-x-plus-1";
            sensitivity = -0.65;
          }
        ];

        window_rule = [
          {
            match.class = "equibop";
            float = true;
            size = "1920 1080";
            workspace = "special:discord";
          }
          {
            match.class = "org.telegram.desktop";
            float = true;
            size = "1920 1080";
            workspace = "special:telegram";
          }
        ];

        layer_rule = [
          {
            match.namespace = "selection";
            no_anim = true;
          }
        ];

        curve = [
          {
            _args = [
              "decel"
              {
                type = "bezier";
                points = [
                  [0.05 0.7]
                  [0.1 1]
                ];
              }
            ];
          }
          {
            _args = [
              "accel"
              {
                type = "bezier";
                points = [
                  [0.3 0]
                  [0.8 0.15]
                ];
              }
            ];
          }
          {
            _args = [
              "linear"
              {
                type = "bezier";
                points = [
                  [0 0]
                  [1 1]
                ];
              }
            ];
          }
        ];

        animation = [
          {
            leaf = "windows";
            enabled = true;
            speed = 3;
            bezier = "decel";
            style = "popin";
          }
          {
            leaf = "fade";
            enabled = true;
            speed = 4;
            bezier = "decel";
          }
          {
            leaf = "fadeIn";
            enabled = true;
            speed = 4;
            bezier = "decel";
          }
          {
            leaf = "fadeOut";
            enabled = true;
            speed = 3;
            bezier = "accel";
          }
          {
            leaf = "fadeDim";
            enabled = true;
            speed = 4;
            bezier = "decel";
          }
          {
            leaf = "border";
            enabled = true;
            speed = 10;
            bezier = "default";
          }
          {
            leaf = "borderangle";
            enabled = true;
            speed = 100;
            bezier = "linear";
            style = "loop";
          }
          {
            leaf = "workspaces";
            enabled = true;
            speed = 4.5;
            bezier = "decel";
            style = "slidevert";
          }
          {
            leaf = "specialWorkspace";
            enabled = true;
            speed = 3;
            bezier = "decel";
            style = "slidevert";
          }
          {
            leaf = "layers";
            enabled = true;
            speed = 4;
            bezier = "decel";
            style = "fade";
          }
        ];

        monitor = {
          output = "DP-1";
          mode = "highrr";
          position = "auto";
          scale = "auto";
          bitdepth = 10;
        };

        env = [
          {_args = ["__GLX_VENDOR_LIBRARY_NAME" "nvidia"];}
          {_args = ["LIBVA_DRIVER_NAME" "nvidia"];}
          {_args = ["NVD_BACKEND" "direct"];}
          {_args = ["HYPRCURSOR_SIZE" "24"];}
          {_args = ["XCURSOR_SIZE" "24"];}
        ];

        bind =
          [
            (mkBindWith "${mod} + mouse:272" "Move window with mouse" (lua "hl.dsp.window.drag()") {mouse = true;})
            (mkBindWith "${mod} + mouse:273" "Resize window with mouse" (lua "hl.dsp.window.resize()") {mouse = true;})

            (mkBind "ALT + TAB" "Switch windows" (exec "${snappySwitcher}/bin/snappy-switcher next --mod alt"))

            (mkBind "${mod} + E" "Open file manager" (exec fileManager))
            (mkBind "${mod} + R" "Open application launcher" (lua ''hl.dsp.global("caelestia:launcher")''))
            (mkBind "${mod} + W" "Open web browser" (exec browser))
            (mkBind "${mod} + RETURN" "Open terminal" (exec terminal))

            (mkBind "${mod} + V" "Open clipboard history" (lua ''hl.dsp.global("caelestia:clipboard")''))
            (mkBind "${mod} + period" "Open emoji picker" (lua ''hl.dsp.global("caelestia:emoji")''))
            (mkBind "${mod} + slash" "Open keybind viewer" (lua ''hl.dsp.global("caelestia:keybinds")''))

            (mkBind "${mod} + D" "Open Discord scratchpad" (exec "${scratchpad} equibop equibop discord"))
            (mkBind "${mod} + T" "Open Telegram scratchpad" (exec "${scratchpad} Telegram org.telegram.desktop telegram"))

            (mkBind "${modS} + S" "Capture active window screenshot" (exec (screenshot "window -m active")))
            (mkBind "CTRL + 3" "Capture active monitor screenshot" (exec (screenshot "output -m active")))
            (mkBind "CTRL + 4" "Capture region screenshot" (exec (screenshot "region --freeze")))

            (mkBind "${mod} + mouse_down" "Previous workspace" (lua ''hl.dsp.focus({ workspace = "e-1" })''))
            (mkBind "${mod} + mouse_up" "Next workspace" (lua ''hl.dsp.focus({ workspace = "e+1" })''))

            (mkBind "${mod} + Q" "Close window" (lua "hl.dsp.window.close()"))
            (mkBind "${modS} + Q" "Log out" (exec "hyprexit"))

            (mkBind "${mod} + SPACE" "Toggle floating window" (lua ''hl.dsp.window.float({ action = "toggle" })''))
            (mkBind "${mod} + F" "Toggle fullscreen" (lua "hl.dsp.window.fullscreen()"))

            (mkBind "${mod} + H" "Focus left" (lua ''hl.dsp.focus({ direction = "left" })''))
            (mkBind "${mod} + J" "Focus down" (lua ''hl.dsp.focus({ direction = "down" })''))
            (mkBind "${mod} + K" "Focus up" (lua ''hl.dsp.focus({ direction = "up" })''))
            (mkBind "${mod} + L" "Focus right" (lua ''hl.dsp.focus({ direction = "right" })''))

            (mkBind "${modS} + H" "Move window left" (lua ''hl.dsp.window.move({ direction = "left" })''))
            (mkBind "${modS} + J" "Move window down" (lua ''hl.dsp.window.move({ direction = "down" })''))
            (mkBind "${modS} + K" "Move window up" (lua ''hl.dsp.window.move({ direction = "up" })''))
            (mkBind "${modS} + L" "Move window right" (lua ''hl.dsp.window.move({ direction = "right" })''))

            (mkBindWith "${modC} + H" "Shrink column width" (lua ''hl.dsp.layout("colresize -0.01")'') {repeating = true;})
            (mkBind "${modC} + J" "Grow window height" (lua "hl.dsp.window.resize({ x = 0, y = 30, relative = true })"))
            (mkBind "${modC} + K" "Shrink window height" (lua "hl.dsp.window.resize({ x = 0, y = -30, relative = true })"))
            (mkBindWith "${modC} + L" "Grow column width" (lua ''hl.dsp.layout("colresize +0.01")'') {repeating = true;})

            (mkBind "XF86AudioRaiseVolume" "Raise volume" (exec "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"))
            (mkBind "XF86AudioLowerVolume" "Lower volume" (exec "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"))
            (mkBind "XF86AudioMute" "Toggle audio mute" (exec "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))

            (mkBind "XF86AudioPlay" "Play or pause media" (exec "playerctl play-pause"))
            (mkBind "XF86AudioNext" "Next track" (exec "playerctl next"))
            (mkBind "XF86AudioPrev" "Previous track" (exec "playerctl previous"))

            (mkBind "XF86MonBrightnessUp" "Raise monitor brightness" (exec "${ddc-brightness} + 5"))
            (mkBind "XF86MonBrightnessDown" "Lower monitor brightness" (exec "${ddc-brightness} - 5"))
          ]
          ++ (
            builtins.concatLists (builtins.genList (
                x: let
                  workspace = toString (x + 1);
                  ws = let
                    c = (x + 1) / 10;
                  in
                    toString (x + 1 - (c * 10));
                in [
                  (mkBind "${mod} + ${ws}" "Switch to workspace ${workspace}" (lua "hl.dsp.focus({ workspace = ${toLua workspace} })"))
                  (mkBind "${modS} + ${ws}" "Move window to workspace ${workspace}" (lua "hl.dsp.window.move({ workspace = ${toLua workspace} })"))
                ]
              )
              10)
          );
      };

      # Clear maximize state restored by clients during their initial map while
      # retaining normal user-initiated maximize behavior afterwards.
      extraConfig = ''
        hl.on("window.open", function(window)
          if window.fullscreen == 1 then
            hl.dispatch(hl.dsp.window.fullscreen({
              mode = "maximized",
              action = "unset",
              window = window,
            }))
          end
        end)
      '';
    };

    # Hyprland plugins require an exact compositor ABI match. A NixOS switch
    # updates the generated plugin paths without replacing the running
    # compositor, so only reload when both sides use the same ABI.
    xdg.configFile."hypr/hyprland.lua".onChange = let
      hyprland = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
      sed = lib.getExe pkgs.gnused;
    in ''
      target_abi="$(${hyprland}/bin/Hyprland --version 2>/dev/null | ${sed} -n 's/^Version ABI string: //p')"
      running_version="$(${hyprland}/bin/hyprctl version 2>/dev/null || true)"
      running_abi="$(printf '%s\n' "$running_version" | ${sed} -n 's/^Version ABI string: //p')"

      if [ -n "$running_abi" ] && [ "$running_abi" = "$target_abi" ]; then
        ${hyprland}/bin/hyprctl reload >/dev/null 2>&1 || true
      elif [ -n "$running_abi" ]; then
        echo "Skipping Hyprland reload: running ABI $running_abi differs from configured ABI $target_abi"
      fi
    '';

    home.packages =
      (with pkgs; [
        ddcutil
        hyprpicker
        hyprshot
        libqalculate
        wl-clipboard
        (pkgs.writeShellScriptBin "hyprexit" ''
          ${inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland}/bin/hyprctl dispatch exit
          ${pkgs.systemd}/bin/loginctl terminate-user ${myconfig.constants.username}
        '')
      ])
      ++ [snappySwitcher];

    xdg.configFile."snappy-switcher/config.ini".text = ''
      [general]
      mode = overview
      follow_monitor = true
      show_workspace_badge = true
      sticky_mode = false
      ignore_pinned = false
      show_previews = true

      [layout]
      card_width = 300
      card_height = 190
      max_cols = 4

      [theme]
      name = catppuccin-mocha.ini

      [icons]
      theme = kora
      fallback = hicolor
      show_letter_fallback = true
    '';

    systemd.user.services.snappy-switcher = {
      Unit = {
        Description = "Snappy Switcher";
        After = ["hyprland-session.target"];
        PartOf = ["hyprland-session.target"];
      };

      Service = {
        ExecStart = "${snappySwitcher}/bin/snappy-switcher --daemon";
        Restart = "on-failure";
        RestartSec = 1;
      };

      Install.WantedBy = ["hyprland-session.target"];
    };

    services.cliphist.enable = true;
  };
}
