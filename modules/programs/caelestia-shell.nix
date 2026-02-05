{
  delib,
  inputs,
  ...
}:
delib.module {
  name = "programs.caelestia-shell";

  options.programs.caelestia-shell = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = {
    imports = [inputs.caelestia-shell.homeManagerModules.default];

    xdg.stateFile."caelestia/scheme.json".text = builtins.toJSON {
      name = "Catppuccin";
      flavour = "Mocha";
      mode = "dark";
      colours = {
        primary_paletteKeyColor = "a6e3a1";
        secondary_paletteKeyColor = "76758e";
        tertiary_paletteKeyColor = "94e2d5";
        neutral_paletteKeyColor = "78767b";
        neutral_variant_paletteKeyColor = "777680";
        background = "181825";
        onBackground = "cdd6f4";
        surface = "181825";
        surfaceDim = "1a1829";
        surfaceBright = "3a3950";
        surfaceContainerLowest = "11111b";
        surfaceContainerLow = "1e1e2e";
        surfaceContainer = "242438";
        surfaceContainerHigh = "2d2c43";
        surfaceContainerHighest = "36354c";
        onSurface = "cdd6f4";
        surfaceVariant = "4a4957";
        onSurfaceVariant = "bac2de";
        inverseSurface = "cdd6f4";
        inverseOnSurface = "1a1825";
        outline = "6c7086";
        outlineVariant = "585b70";
        shadow = "000000";
        scrim = "000000";
        surfaceTint = "a6e3a1";
        primary = "a6e3a1";
        onPrimary = "1e3a1c";
        primaryContainer = "2d5a2a";
        onPrimaryContainer = "d4f7d2";
        inversePrimary = "40a33c";
        secondary = "cba6f7";
        onSecondary = "2e2e44";
        secondaryContainer = "45455c";
        onSecondaryContainer = "b4b2ce";
        tertiary = "94e2d5";
        onTertiary = "1e4a44";
        tertiaryContainer = "2d6a5c";
        onTertiaryContainer = "d4f7f0";
        error = "f38ba8";
        onError = "690005";
        errorContainer = "93000a";
        onErrorContainer = "ffdad6";
        primaryFixed = "d4f7d2";
        primaryFixedDim = "a6e3a1";
        onPrimaryFixed = "0d290c";
        onPrimaryFixedVariant = "2d5a2a";
        secondaryFixed = "e2e0fd";
        secondaryFixedDim = "cba6f7";
        onSecondaryFixed = "19192e";
        onSecondaryFixedVariant = "45455c";
        tertiaryFixed = "d4f7f0";
        tertiaryFixedDim = "94e2d5";
        onTertiaryFixed = "0d2924";
        onTertiaryFixedVariant = "2d6a5c";
        term0 = "1e1e2f";
        term1 = "f38ba8";
        term2 = "a6e3a1";
        term3 = "f9e2af";
        term4 = "89b4fa";
        term5 = "cba6f7";
        term6 = "94e2d5";
        term7 = "cdd6f4";
        term8 = "6c7086";
        term9 = "f38ba8";
        term10 = "a6e3a1";
        term11 = "f9e2af";
        term12 = "89b4fa";
        term13 = "cba6f7";
        term14 = "94e2d5";
        term15 = "cdd6f4";
        success = "a6e3a1";
        onSuccess = "1e3a1c";
        successContainer = "2d5a2a";
        onSuccessContainer = "d4f7d2";
      };
    };

    programs.caelestia = {
      enable = true;
      cli.enable = true;

      settings = {
        background.enabled = false;

        appearance.font.family = {
          sans = "Rubik";
          mono = "Maple Mono NF";
        };

        bar = {
          status.showBattery = false;
          workspaces.showWindows = false;
          tray.compact = true;
        };

        general = {
          apps = {
            terminal = ["wezterm"];
            explorer = ["nautilus"];
            playback = ["mpv"];
          };

          idle = {
            lockBeforeSleep = true;
            inhibitWhenAudio = true;
            timeouts = [
              {
                timeout = 1800; # 30min
                idleAction = "lock";
              }
              {
                timeout = 2700; # 45min
                idleAction = "dpms off";
                returnAction = "dpms on";
              }
              {
                timeout = 3600; # 60min
                idleAction = ["systemctl" "suspend-then-hibernate"];
              }
            ];
          };
        };

        launcher.actions = [
          {
            name = "Calculator";
            icon = "calculate";
            description = "Do simple math equations (powered by Qalc)";
            command = ["autocomplete" "calc"];
            enabled = true;
            dangerous = false;
          }
          {
            name = "Shutdown";
            icon = "power_settings_new";
            description = "Shutdown the system";
            command = ["systemctl" "poweroff"];
            enabled = true;
            dangerous = true;
          }
          {
            name = "Reboot";
            icon = "cached";
            description = "Reboot the system";
            command = ["systemctl" "reboot"];
            enabled = true;
            dangerous = true;
          }
          {
            name = "Logout";
            icon = "exit_to_app";
            description = "Log out of the current session";
            command = ["loginctl" "terminate-user" ""];
            enabled = true;
            dangerous = true;
          }
          {
            name = "Lock";
            icon = "lock";
            description = "Lock the current session";
            command = ["loginctl" "lock-session"];
            enabled = true;
            dangerous = false;
          }
          {
            name = "Sleep";
            icon = "bedtime";
            description = "Suspend then hibernate";
            command = ["systemctl" "suspend-then-hibernate"];
            enabled = true;
            dangerous = false;
          }
        ];

        services = {
          weatherLocation = "39.953388,-74.198151";
          useFahrenheit = true;
          defaultPlayer = "Jellyfin";
          smartScheme = false;
        };
      };

      systemd = {
        enable = true;
        target = "hyprland-session.target";
      };
    };
  };
}
