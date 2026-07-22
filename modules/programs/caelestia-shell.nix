{
  delib,
  inputs,
  lib,
  pkgs,
  ...
}:
delib.module {
  name = "programs.caelestia-shell";

  options.programs.caelestia-shell = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = let
    inherit (pkgs.stdenv.hostPlatform) system;

    caelestiaChatgpt = pkgs.writeScriptBin "caelestia-chatgpt" ''
      #!${pkgs.python3}/bin/python3
      ${builtins.readFile ./caelestia-chatgpt.py}
    '';

    caelestiaCli = inputs.caelestia-shell.inputs.caelestia-cli.packages.${system}.default.overrideAttrs (old: {
      propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [pkgs.ffmpeg];
    });

    caelestiaShell =
      (inputs.caelestia-shell.packages.${system}.default.override {
        caelestia-cli = caelestiaCli;
        withCli = true;
      }).overrideAttrs (old: {
        buildInputs = (old.buildInputs or []) ++ [pkgs.qt6.qtmultimedia];

        postPatch =
          (old.postPatch or "")
          + ''
            substituteInPlace modules/background/DesktopClock.qml \
              --replace-fail "readonly property color safePrimary: useLightSet ? Colours.palette.m3primaryContainer : Colours.palette.m3primary" "readonly property color safePrimary: Colours.palette.m3onSurface" \
              --replace-fail "readonly property color safeSecondary: useLightSet ? Colours.palette.m3secondaryContainer : Colours.palette.m3secondary" "readonly property color safeSecondary: Colours.palette.m3onSurfaceVariant" \
              --replace-fail "readonly property color safeTertiary: useLightSet ? Colours.palette.m3tertiaryContainer : Colours.palette.m3tertiary" "readonly property color safeTertiary: Colours.palette.m3onSurfaceVariant"

            substituteInPlace modules/background/DesktopLyrics.qml \
              --replace-fail "readonly property color safePrimary: useLightSet ? Colours.palette.m3primaryContainer : Colours.palette.m3primary" "readonly property color safePrimary: Colours.palette.m3onSurface" \
              --replace-fail "readonly property color safeSecondary: useLightSet ? Colours.palette.m3secondaryContainer : Colours.palette.m3secondary" "readonly property color safeSecondary: Colours.palette.m3onSurfaceVariant" \
              --replace-fail "readonly property color safeTertiary: useLightSet ? Colours.palette.m3tertiaryContainer : Colours.palette.m3tertiary" "readonly property color safeTertiary: Colours.palette.m3onSurfaceVariant" \
              --replace-fail "color: Colours.palette.m3primaryContainer" "color: Colours.palette.m3surfaceContainerHighest" \
              --replace-fail "color: Colours.palette.m3primary" "color: Colours.palette.m3onSurface" \
              --replace-fail "shadowColor: Colours.palette.m3primary" "shadowColor: Colours.palette.m3onSurface"

            substituteInPlace modules/background/Visualiser.qml \
              --replace-fail "primaryColor: Qt.alpha(Colours.palette.m3primary, 0.7)" "primaryColor: Qt.alpha(Colours.palette.m3onSurface, 0.7)" \
              --replace-fail "secondaryColor: Qt.alpha(Colours.palette.m3inversePrimary, 0.7)" "secondaryColor: Qt.alpha(Colours.palette.m3onSurfaceVariant, 0.7)"

            substituteInPlace modules/sidebar/AiAssistant.qml \
              --replace-fail "Ollama tags request failed" "ChatGPT model request failed" \
              --replace-fail "Ollama request failed" "ChatGPT request failed"
          '';
      });
  in rec {
    imports = [inputs.caelestia-shell.homeManagerModules.default];

    home.packages = [caelestiaChatgpt];

    # Caelestia persists settings and AI state by rewriting shell.json. The
    # upstream Home Manager module normally makes it an immutable store symlink,
    # so seed a regular user-owned file instead. Existing runtime choices win
    # over defaults, while newly declared settings are added on activation.
    xdg.configFile."caelestia/shell.json".enable = lib.mkForce false;

    home.activation.caelestiaMutableConfig = inputs.home-manager.lib.hm.dag.entryAfter ["writeBoundary"] ''
      configDir="''${XDG_CONFIG_HOME:-$HOME/.config}/caelestia"
      configPath="$configDir/shell.json"
      seedPath=${lib.escapeShellArg (pkgs.writeText "caelestia-shell-defaults.json" (builtins.toJSON programs.caelestia.settings))}

      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$configDir"
      tempPath="$(${pkgs.coreutils}/bin/mktemp "$configDir/.shell.json.XXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tempPath"' EXIT

      if [[ -L "$configPath" || ! -e "$configPath" ]]; then
        ${pkgs.coreutils}/bin/cp "$seedPath" "$tempPath"
      elif [[ -f "$configPath" ]]; then
        ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$seedPath" "$configPath" > "$tempPath"
      else
        errorEcho "Caelestia config is not a regular file: $configPath"
        exit 1
      fi

      ${pkgs.coreutils}/bin/chmod 0600 "$tempPath"
      if [[ -L "$configPath" ]] || ! ${pkgs.diffutils}/bin/cmp -s "$tempPath" "$configPath"; then
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$configPath"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv "$tempPath" "$configPath"
      fi
    '';

    systemd.user.services.caelestia-chatgpt = {
      Unit = {
        Description = "ChatGPT OAuth provider for Caelestia Shell";
        Before = ["caelestia.service"];
      };
      Service = {
        ExecStart = "${caelestiaChatgpt}/bin/caelestia-chatgpt serve";
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install.WantedBy = ["hyprland-session.target"];
    };

    xdg.stateFile."caelestia/scheme.json".text = builtins.toJSON {
      name = "catppuccin";
      flavour = "mocha";
      mode = "dark";
      variant = "tonalspot";
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
      package = caelestiaShell;

      cli = {
        enable = true;
        package = caelestiaCli;
      };

      settings = {
        ai = {
          ollamaUrl = "http://127.0.0.1:11435";
          ollamaModel = "gpt-5.4";
          defaultOllamaModel = "gpt-5.4";
          defaultProvider = "ollama";
          enableOllama = true;
        };

        appearance = {
          font = {
            headline.family = "Rubik";
            title.family = "Rubik";
            body.family = "Rubik";
            label.family = "Rubik";
            mono.family = "Maple Mono NF";
            clock = "Rubik";
            workspaces = "Rubik";
          };

          transparency.enabled = true;
        };

        background = {
          enabled = true;
          desktopClock.enabled = true;
          desktopLyrics.enabled = true;
          visualiser.enabled = true;
        };

        bar = {
          clock = {
            background = true;
            showDate = true;
          };

          entries = [
            {
              id = "logo";
              enabled = true;
            }
            {
              id = "workspaces";
              enabled = true;
            }
            {
              id = "github";
              enabled = true;
            }
            {
              id = "spacer";
              enabled = true;
            }
            {
              id = "dock";
              enabled = true;
            }
            {
              id = "spacer";
              enabled = true;
            }
            {
              id = "tray";
              enabled = true;
            }
            {
              id = "clock";
              enabled = true;
            }
            {
              id = "statusIcons";
              enabled = true;
            }
            {
              id = "power";
              enabled = true;
            }
          ];

          status.showBattery = false;
          workspaces.showWindows = true;
          tray = {
            background = true;
            compact = true;
          };
        };

        dashboard.profilePicShape = 20; # Cookie 12-Sided
        lock.profilePicShape = 20; # Cookie 12-Sided

        shimeji.enabled = false;

        sidebar.showNews = false;

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
          smartScheme = false;
        };

        utilities.toasts.transparency = true;
      };

      systemd = {
        enable = true;
        target = "hyprland-session.target";
      };
    };
  };
}
