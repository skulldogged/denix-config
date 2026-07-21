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

  home.ifEnabled = {myconfig, ...}: {
    home.packages = with pkgs; [
      ddcutil
      hyprpicker
      hyprshot
      libqalculate
      wl-clipboard
      (pkgs.writeShellScriptBin "hyprexit" ''
        ${inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland}/bin/hyprctl dispatch exit
        ${pkgs.systemd}/bin/loginctl terminate-user ${myconfig.constants.username}
      '')
    ];

    services.cliphist.enable = true;

    wayland.windowManager.hyprland = {
      enable = true;
      package = null;
      portalPackage = null;
      configType = "lua";
      systemd.variables = ["--all"];

      settings = let
        ddc-brightness = pkgs.writeShellScript "ddc-brightness" ''
          display_serial_num=$(hyprctl monitors -j | jq '.[].serial' --raw-output)

          ddcutil --sn "$display_serial_num" setvcp 10 $@
        '';

        scratchpad = let
          hyprctl = "${inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland}/bin/hyprctl";
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
        terminal = "wezterm";

        zipline-screenshot = pkgs.writeShellScript "zipline-screenshot" ''
          set -e
          TMPFILE=$(mktemp --suffix=.png)
          trap 'rm -f "$TMPFILE"' EXIT

          notify_error() {
            ${lib.getExe pkgs.libnotify} -u critical "Screenshot failed" "$1"
            exit 1
          }

          # Capture screenshot
          if ! ${lib.getExe pkgs.hyprshot} -s -m "$@" --freeze -o "$(dirname "$TMPFILE")" -f "$(basename "$TMPFILE")"; then
            notify_error "Failed to capture screenshot"
          fi

          # Wait for file stability
          while [ "$(stat -c%s "$TMPFILE" 2>/dev/null)" != "$(sleep 0.05; stat -c%s "$TMPFILE" 2>/dev/null)" ]; do :; done

          # Check if file exists and has content
          if [ ! -s "$TMPFILE" ]; then
            notify_error "Screenshot file is empty"
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

          echo -n "$URL" | ${pkgs.wl-clipboard}/bin/wl-copy || notify_error "Failed to copy URL to clipboard"
          ${lib.getExe pkgs.libnotify} -i "$TMPFILE" "Screenshot uploaded" "$URL"

          trap - EXIT
          (sleep 1 && rm "$TMPFILE") &
        '';

        screenshot = mode: "${zipline-screenshot} ${mode}";

        lua = lib.generators.mkLuaInline;
        toLua = lib.generators.toLua {};
        exec = command: lua "hl.dsp.exec_cmd(${toLua command})";
        mkBind = key: dispatcher: {
          _args = [key dispatcher];
        };
        mkBindWith = key: dispatcher: options: {
          _args = [key dispatcher options];
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
            resize_on_border = true;

            col = {
              active_border = "rgba(cba6f7ee)";
              inactive_border = "rgba(595959aa)";
            };
          };

          misc = {
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
            style = "slide";
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
            (mkBindWith "${mod} + mouse:272" (lua "hl.dsp.window.drag()") {mouse = true;})
            (mkBindWith "${mod} + mouse:273" (lua "hl.dsp.window.resize()") {mouse = true;})

            (mkBind "${mod} + E" (exec fileManager))
            (mkBind "${mod} + R" (lua ''hl.dsp.global("caelestia:launcher")''))
            (mkBind "${mod} + W" (exec browser))
            (mkBind "${mod} + RETURN" (exec terminal))

            (mkBind "${mod} + D" (exec "${scratchpad} equibop equibop discord"))
            (mkBind "${mod} + T" (exec "${scratchpad} Telegram org.telegram.desktop telegram"))

            (mkBind "${modS} + S" (exec (screenshot "window")))
            (mkBind "CTRL + 3" (exec (screenshot "output -m active")))
            (mkBind "CTRL + 4" (exec (screenshot "region -C 0,0")))

            (mkBind "${mod} + mouse_down" (lua ''hl.dsp.focus({ workspace = "e-1" })''))
            (mkBind "${mod} + mouse_up" (lua ''hl.dsp.focus({ workspace = "e+1" })''))

            (mkBind "${mod} + Q" (lua "hl.dsp.window.close()"))
            (mkBind "${modS} + Q" (exec "hyprexit"))

            (mkBind "${mod} + SPACE" (lua ''hl.dsp.window.float({ action = "toggle" })''))
            (mkBind "${mod} + F" (lua "hl.dsp.window.fullscreen()"))

            (mkBind "${mod} + H" (lua ''hl.dsp.focus({ direction = "left" })''))
            (mkBind "${mod} + J" (lua ''hl.dsp.focus({ direction = "down" })''))
            (mkBind "${mod} + K" (lua ''hl.dsp.focus({ direction = "up" })''))
            (mkBind "${mod} + L" (lua ''hl.dsp.focus({ direction = "right" })''))

            (mkBind "${modS} + H" (lua ''hl.dsp.window.move({ direction = "left" })''))
            (mkBind "${modS} + J" (lua ''hl.dsp.window.move({ direction = "down" })''))
            (mkBind "${modS} + K" (lua ''hl.dsp.window.move({ direction = "up" })''))
            (mkBind "${modS} + L" (lua ''hl.dsp.window.move({ direction = "right" })''))

            (mkBind "${modC} + H" (lua "hl.dsp.window.resize({ x = -30, y = 0, relative = true })"))
            (mkBind "${modC} + J" (lua "hl.dsp.window.resize({ x = 0, y = 30, relative = true })"))
            (mkBind "${modC} + K" (lua "hl.dsp.window.resize({ x = 0, y = -30, relative = true })"))
            (mkBind "${modC} + L" (lua "hl.dsp.window.resize({ x = 30, y = 0, relative = true })"))

            (mkBind "XF86AudioRaiseVolume" (exec "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"))
            (mkBind "XF86AudioLowerVolume" (exec "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"))
            (mkBind "XF86AudioMute" (exec "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"))

            (mkBind "XF86AudioPlay" (exec "playerctl play-pause"))
            (mkBind "XF86AudioNext" (exec "playerctl next"))
            (mkBind "XF86AudioPrev" (exec "playerctl previous"))

            (mkBind "XF86MonBrightnessUp" (exec "${ddc-brightness} + 5"))
            (mkBind "XF86MonBrightnessDown" (exec "${ddc-brightness} - 5"))
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
                  (mkBind "${mod} + ${ws}" (lua "hl.dsp.focus({ workspace = ${toLua workspace} })"))
                  (mkBind "${modS} + ${ws}" (lua "hl.dsp.window.move({ workspace = ${toLua workspace} })"))
                ]
              )
              10)
          );
      };
    };
  };
}
