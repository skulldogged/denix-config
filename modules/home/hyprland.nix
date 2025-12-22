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
        ${inputs.hyprland.packages.${pkgs.system}.hyprland}/bin/hyprctl dispatch exit
        ${pkgs.systemd}/bin/loginctl terminate-user ${myconfig.constants.username}
      '')
    ];

    services.cliphist.enable = true;

    wayland.windowManager.hyprland = {
      enable = true;
      package = null;
      portalPackage = null;
      systemd.variables = ["--all"];

      settings = let
        ddc-brightness = pkgs.writeScript "ddc-brightness" ''
          display_serial_num=$(hyprctl monitors -j | jq '.[].serial' --raw-output)

          ddcutil --sn "$display_serial_num" setvcp 10 $@
        '';

        hyprscreensharefix = pkgs.writeScript "hyprscreensharefix" ''
          dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=hyprland
          systemctl --user stop pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-hyprland
          systemctl --user start pipewire wireplumber xdg-desktop-portal xdg-desktop-portal-hyprland
        '';

        scratchpad = pkgs.writeScript "hyprscratchpad" ''
          COMMAND=$1
          CLASS=$2
          WORKSPACE=$3

          if [[ $(hyprctl clients | grep -v '"title":' | grep "class: $CLASS") ]];then
            hyprctl dispatch togglespecialworkspace $WORKSPACE
          else
            hyprctl dispatch togglespecialworkspace $WORKSPACE && hyprctl dispatch exec "$COMMAND"
          fi
        '';

        mod = "SUPER";
        modC = "SUPER CTRL";
        modS = "SUPER SHIFT";

        browser = "helium";
        fileManager = "nautilus";
        launcher = "vicinae";
        terminal = "wezterm";

        zipline-screenshot = pkgs.writeShellScript "zipline-screenshot" ''
          set -e

          TMPFILE=$(mktemp --suffix=.png)
          trap 'rm -f "$TMPFILE"' EXIT

          ${lib.getExe pkgs.hyprshot} --freeze --raw -m "$1" > "$TMPFILE"

          TOKEN=$(cat /run/agenix/zipline_token)
          RESPONSE=$(${lib.getExe pkgs.curl} -s \
            -H "Authorization: $TOKEN" \
            -F "file=@$TMPFILE" \
            "https://zip.pupbrained.dev/api/upload")

          URL=$(echo "$RESPONSE" | ${lib.getExe pkgs.jq} -r '.files[0]')
          echo -n "$URL" | ${pkgs.wl-clipboard}/bin/wl-copy

          ${lib.getExe pkgs.libnotify} "Screenshot uploaded" "$URL"
        '';

        screenshot = mode: "${zipline-screenshot} ${mode}";
      in {
        decoration.rounding = 5;
        dwindle.preserve_split = true;
        experimental.xx_color_management_v4 = true;
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

        device = [
          {
            name = "logitech-usb-receiver";
            sensitivity = -0.75;
          }
          {
            name = "logitech-g502-x-plus";
            sensitivity = -0.75;
          }
        ];

        windowrule = [
          "match:class equibop, float true"
          "match:class org.telegram.desktop, float true"
        ];

        layerrule = [
          "match:namespace vicinae, dim_around true"
          "match:namespace selection, no_anim true"
        ];

        animations = {
          enabled = true;

          bezier = [
            "decel, 0.05, 0.7, 0.1, 1"
            "accel, 0.3, 0, 0.8, 0.15"
            "linear, 0, 0, 1, 1"
          ];

          animation = [
            "windows, 1, 3, decel, popin"
            "fade, 1, 4, decel"
            "fadeIn, 1, 4, decel"
            "fadeOut, 1, 3, accel"
            "fadeDim, 1, 4, decel"
            "border, 1, 10, default"
            "borderangle, 1, 100, linear, loop"
            "workspaces, 1, 4.5, decel, slide"
            "specialWorkspace, 1, 3, decel, slidevert"
            "layers, 1, 4, decel, fade"
          ];
        };

        general = {
          border_size = 2;
          gaps_in = 10;
          resize_on_border = true;

          "col.active_border" = "rgba(f38ba8ee) rgba(fab387ee) rgba(a6e3a1ee) rgba(89dcebee) rgba(89b4faee) rgba(cba6f7ee) 45deg";
          "col.inactive_border" = "rgba(595959aa)";
        };

        exec-once = [
          "${hyprscreensharefix}"
        ];

        misc = {
          force_default_wallpaper = 0;
          disable_hyprland_logo = true;
          vrr = 3;
        };

        monitor = ["DP-1, highrr, auto, auto"];

        env = [
          "__GLX_VENDOR_LIBRARY_NAME, nvidia"
          "LIBVA_DRIVER_NAME,         nvidia"
          "NVD_BACKEND,               direct"
          "HYPRCURSOR_SIZE, 24"
          "XCURSOR_SIZE, 24"
        ];

        bindm = [
          "${mod},  mouse:272, movewindow"
          "${mod},  mouse:273, resizewindow"
        ];

        bind =
          [
            "${mod},         e, exec, ${fileManager}"
            "${mod},         r, exec, ${launcher} toggle"
            "${mod},         w, exec, ${browser}"
            "${mod},    Return, exec, ${terminal}"

            "${mod}, d, exec, ${scratchpad} equibop equibop discord"
            "${mod}, t, exec, ${scratchpad} Telegram org.telegram.desktop telegram"

            "${modS}, s, exec, ${screenshot "window"}"
            "CTRL, 3, exec, ${screenshot "output -c"}"
            "CTRL, 4, exec, ${screenshot "region -C 0,0"}"

            "${mod}, mouse_down, workspace, e-1"
            "${mod},   mouse_up, workspace, e+1"

            "${mod},  q, killactive"
            "${modS}, q, exec, hyprexit"

            "${mod}, Space, togglefloating"
            "${mod}, f, fullscreen"

            "${mod}, h, movefocus, l"
            "${mod}, j, movefocus, d"
            "${mod}, k, movefocus, u"
            "${mod}, l, movefocus, r"

            "${modS}, h, movewindow, l"
            "${modS}, j, movewindow, d"
            "${modS}, k, movewindow, u"
            "${modS}, l, movewindow, r"

            "${modC}, h, resizeactive, -30  0"
            "${modC}, j, resizeactive, 0   30"
            "${modC}, k, resizeactive, 0  -30"
            "${modC}, l, resizeactive, 30   0"

            ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
            ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
            ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"

            ", XF86AudioPlay, exec, playerctl play-pause"
            ", XF86AudioNext, exec, playerctl next"
            ", XF86AudioPrev, exec, playerctl previous"

            ", XF86MonBrightnessUp, exec, ${ddc-brightness} + 5"
            ", XF86MonBrightnessDown, exec, ${ddc-brightness} - 5"
          ]
          ++ (
            builtins.concatLists (builtins.genList (
                x: let
                  ws = let
                    c = (x + 1) / 10;
                  in
                    builtins.toString (x + 1 - (c * 10));
                in [
                  "${mod},  ${ws}, workspace,       ${builtins.toString (x + 1)}"
                  "${modS}, ${ws}, movetoworkspace, ${builtins.toString (x + 1)}"
                ]
              )
              10)
          );
      };
    };
  };
}
