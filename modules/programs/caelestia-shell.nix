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

    caelestiaCliStaticSchemePatch = pkgs.writeText "caelestia-cli-preserve-static-scheme.patch" ''
      diff --git a/src/caelestia/utils/wallpaper.py b/src/caelestia/utils/wallpaper.py
      --- a/src/caelestia/utils/wallpaper.py
      +++ b/src/caelestia/utils/wallpaper.py
      @@ -213,8 +213,10 @@ def set_wallpaper(wall: Path, no_smart: bool) -> None:
              scheme.mode = smart_opts["mode"]
              scheme.variant = smart_opts["variant"]

      -    # Update colours
      -    scheme.update_colours()
      +    # Only dynamic schemes follow the wallpaper. Named schemes keep the
      +    # colours already configured in scheme.json.
      +    if scheme.name == "dynamic":
      +        scheme.update_colours()
           apply_colours(scheme.colours, scheme.mode)

           # Run custom post-hook if configured
    '';

    caelestiaCli = inputs.caelestia-shell.inputs.caelestia-cli.packages.${system}.default.overrideAttrs (old: {
      # A wallpaper change should only regenerate colours for the dynamic
      # scheme. Upstream also reloads named schemes here, which discards a
      # custom declarative Catppuccin palette from scheme.json.
      patchPhase =
        (old.patchPhase or "")
        + ''
          ${pkgs.patch}/bin/patch -p1 < ${caelestiaCliStaticSchemePatch}
        '';
    });

    caelestiaScopedAppLaunchPatch = pkgs.writeText "caelestia-scoped-app-launch.patch" ''
      diff --git a/modules/launcher/services/Apps.qml b/modules/launcher/services/Apps.qml
      --- a/modules/launcher/services/Apps.qml
      +++ b/modules/launcher/services/Apps.qml
      @@ -11,11 +11,11 @@ Searcher {
           function launch(entry: DesktopEntry): void {
               appDb.incrementFrequency(entry.id);

      -        if (entry.runInTerminal)
      -            Quickshell.execDetached({
      -                command: [...GlobalConfig.general.apps.terminal, `''${Quickshell.shellDir}/assets/wrap_term_launch.sh`, ...entry.command],
      -                workingDirectory: entry.workingDirectory
      -            });
      -        else
      -            entry.execute();
      +        const command = entry.runInTerminal
      +            ? [...GlobalConfig.general.apps.terminal, `''${Quickshell.shellDir}/assets/wrap_term_launch.sh`, ...entry.command]
      +            : entry.command;
      +        Quickshell.execDetached({
      +            command: ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--", ...command],
      +            workingDirectory: entry.workingDirectory
      +        });
           }

           function search(search: string): var {
      diff --git a/modules/bar/components/Dock.qml b/modules/bar/components/Dock.qml
      --- a/modules/bar/components/Dock.qml
      +++ b/modules/bar/components/Dock.qml
      @@ -242 +242 @@ Item {
      -                                        command: subCmd,
      +                                        command: ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--", ...subCmd],
      diff --git a/modules/bar/popouts/DockContext.qml b/modules/bar/popouts/DockContext.qml
      --- a/modules/bar/popouts/DockContext.qml
      +++ b/modules/bar/popouts/DockContext.qml
      @@ -122 +122 @@ StyledRect {
      -                                command: subCmd,
      +                                command: ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--", ...subCmd],
    '';

    caelestiaDockPinnedFlickerPatch = pkgs.writeText "caelestia-dock-pinned-flicker.patch" ''
      diff --git a/modules/bar/components/Dock.qml b/modules/bar/components/Dock.qml
      --- a/modules/bar/components/Dock.qml
      +++ b/modules/bar/components/Dock.qml
      @@ -428,6 +428,9 @@

           property var modelDataArray: []

      +    property bool forceRebuild: false
      +    property int transientPinnedMisses: 0
      +
           property var currentOrder: []

           onModelDataArrayChanged: currentOrder = [...modelDataArray]
      @@ -536,6 +539,36 @@
                   root.launchingApps = newLaunching;
               }

      +        // A desktop entry rescan can transiently drop entries (e.g. while
      +        // the nix store or profile is being rebuilt). Pinned entries have
      +        // no running window to keep them in the model, so the dock would
      +        // remove and immediately re-add them, replaying the add/remove
      +        // animations. Ignore rebuilds that would only remove pinned
      +        // entries; a persistent removal is accepted after 25 consecutive
      +        // identical results so uninstalled apps still disappear.
      +        if (!root.forceRebuild) {
      +            const newIds = {};
      +            for (const app of apps) newIds[app.id] = true;
      +
      +            let missingPinned = false;
      +            let missingOther = false;
      +            for (const cur of root.modelDataArray) {
      +                if (!newIds[cur.id]) {
      +                    if (cur.isPinned) missingPinned = true;
      +                    else missingOther = true;
      +                }
      +            }
      +
      +            if (missingPinned && !missingOther && apps.length < root.modelDataArray.length) {
      +                if (root.transientPinnedMisses < 25) {
      +                    root.transientPinnedMisses += 1;
      +                    return;
      +                }
      +            }
      +        }
      +        root.forceRebuild = false;
      +        root.transientPinnedMisses = 0;
      +
               let changed = false;
               if (apps.length !== dockModel.count) {
                   changed = true;
      @@ -613,6 +646,7 @@
               target: GlobalConfig.launcher

               function onFavouriteAppsChanged(): void {
      +            root.forceRebuild = true;
                   root.rebuildModel();
               }
           }
    '';

    caelestiaLauncherExtrasPatch = pkgs.writeText "caelestia-launcher-extras.patch" ''
      diff --git a/modules/launcher/services/Clipboard.qml b/modules/launcher/services/Clipboard.qml
      --- a/modules/launcher/services/Clipboard.qml
      +++ b/modules/launcher/services/Clipboard.qml
      @@ -14,15 +14,28 @@

           readonly property string imageCacheDir: "/tmp/caelestia-clipboard"

      -    property Component waitTimer: Component {
      -        Timer {
      +    property Component imageDecoder: Component {
      +        Process {
      +            property int clipId
                   property string imgPath
                   property var callback

      -            interval: 1000
      -            repeat: false
      -
      -            onTriggered: callback(imgPath)
      +            command: [
      +                "sh",
      +                "-c",
      +                "if [ -s \"$2\" ]; then exit 0; fi; mkdir -p \"$1\"; tmp=\"$2.tmp.$$\"; trap 'rm -f \"$tmp\"' EXIT; cliphist decode \"$3\" > \"$tmp\" && mv -f \"$tmp\" \"$2\"",
      +                "sh",
      +                root.imageCacheDir,
      +                imgPath,
      +                String(clipId)
      +            ]
      +            running: true
      +
      +            onExited: exitCode => {
      +                if (exitCode === 0 && callback)
      +                    callback(imgPath);
      +                destroy();
      +            }
               }
           }

      @@ -46,12 +59,11 @@
                           result.push({
                               id: parseInt(match[1]),
                               preview: match[2],
      -                        isImage: /^\[\[ binary data \d+ KiB png \d+x\d+ \]\]/.test(match[2])
      +                        isImage: /^\[\[ binary data \d+(?:\.\d+)? (?:B|KiB|MiB) (?:png|jpe?g|bmp|webp) \d+x\d+ \]\]/i.test(match[2])
                           });
                       }

                       root.items = result;
      -                preloadImages();
                   }
               }
           }
      @@ -60,15 +72,6 @@
               fetcher.running = true;
           }

      -    function preloadImages(): void {
      -        for (const item of items) {
      -            if (item.isImage && item.id) {
      -                const imgPath = getImagePath(item.id);
      -                Quickshell.execDetached(["sh", "-c", "mkdir -p " + imageCacheDir + " && cliphist decode " + item.id + " > " + imgPath + " 2>&1"]);
      -            }
      -        }
      -    }
      -
           function getSortedItems(): var {
               if (!items.length)
                   return [];
      @@ -91,8 +94,8 @@

           function ensureImageCached(id: int, onReady: var): void {
               const imgPath = getImagePath(id);
      -        Quickshell.execDetached(["sh", "-c", "mkdir -p " + imageCacheDir + " && cliphist decode " + id + " > " + imgPath + " 2>&1"]);
      -        const timer = waitTimer.createObject(root, {
      +        imageDecoder.createObject(root, {
      +            clipId: id,
                   imgPath: imgPath,
                   callback: onReady
               });
      diff --git a/modules/launcher/items/ClipItem.qml b/modules/launcher/items/ClipItem.qml
      --- a/modules/launcher/items/ClipItem.qml
      +++ b/modules/launcher/items/ClipItem.qml
      @@ -25,7 +25,9 @@

           Component.onCompleted: {
               if (root.modelData?.isImage) {
      -            Clipboard.ensureImageCached(root.modelData.id);
      +            Clipboard.ensureImageCached(root.modelData.id, path => {
      +                imagePreview.imagePath = path;
      +            });
               }
           }

      @@ -58,7 +60,7 @@
               Item {
                   id: imagePreview

      -            property string imagePath: (root.modelData?.isImage ?? false) ? "/tmp/caelestia-clipboard/" + (root.modelData?.id ?? "") + ".png" : ""
      +            property string imagePath: ""

                   width: (root.modelData?.isImage ?? false) ? 120 : 0
                   height: (root.modelData?.isImage ?? false) ? 80 : 0
      @@ -70,6 +72,7 @@
                   Image {
                       anchors.fill: parent
                       asynchronous: true
      +                cache: false
                       fillMode: Image.PreserveAspectCrop
                    source: imagePreview.imagePath.length > 0 ? "file://" + imagePreview.imagePath : ""
                }
    '';

    caelestiaShellBase = inputs.caelestia-shell.packages.${system}.default.override {
      caelestia-cli = caelestiaCli;
      extraRuntimeDeps = [pkgs.cliphist];
      hyprland = inputs.hyprland.packages.${system}.hyprland;
      withCli = true;
    };

    # Quick Share uses generated protobuf sources, but the upstream plugin
    # derivation does not yet provide either protoc or libprotobuf.
    caelestiaPlugin = caelestiaShellBase.plugin.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.protobuf];
      buildInputs = (old.buildInputs or []) ++ [pkgs.protobuf];
    });

    caelestiaShell = caelestiaShellBase.overrideAttrs (old: {
      # Caelestia's audio service imports QtMultimedia even when its
      # background and video wallpaper support are disabled.
      buildInputs =
        map (
          input:
            if input == caelestiaShellBase.plugin
            then caelestiaPlugin
            else input
        )
        (old.buildInputs or [])
        ++ [pkgs.qt6.qtmultimedia];

      patches =
        (old.patches or [])
        ++ [
          caelestiaScopedAppLaunchPatch
          caelestiaLauncherExtrasPatch
          caelestiaDockPinnedFlickerPatch
        ];

      passthru = (old.passthru or {}) // {plugin = caelestiaPlugin;};

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

          substituteInPlace modules/launcher/services/Emojis.qml \
            --replace-fail 'command: ["cat", "/usr/lib/python3.14/site-packages/caelestia/data/emojis.txt"]' \
                           'command: ["${caelestiaCli}/bin/caelestia", "emoji", "--print"]' \
            --replace-fail 'import Caelestia.Config' $'import Caelestia.Config\nimport qs.utils'
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
        ${pkgs.jq}/bin/jq -s '
          .[0] as $defaults
          | .[1] as $runtime
          | ($defaults * $runtime)
          | .launcher.actions = reduce (
              (($defaults.launcher.actions // []) + ($runtime.launcher.actions // []))[]
            ) as $action (
              [];
              if any(.[]; .name == $action.name) then
                map(if .name == $action.name then $action else . end)
              else
                . + [$action]
              end
            )
          | .background.enabled = false
        ' "$seedPath" "$configPath" > "$tempPath"
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

    # Launcher and dock applications are moved into their own scopes by the
    # package patch above. Cleaning the whole Caelestia cgroup is therefore
    # safe and prevents internal helpers such as `nmcli monitor` accumulating
    # across shell reloads.
    systemd.user.services.caelestia.Service.KillMode = lib.mkForce "control-group";

    # Both files are atomically replaced by the Caelestia CLI when it applies a
    # scheme. Keep them mutable instead of allowing Home Manager to create store
    # symlinks, which causes the next activation to fail its collision check.
    xdg.configFile."cava/config".enable = lib.mkForce false;
    xdg.stateFile."caelestia/scheme.json".enable = lib.mkForce false;
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
        rosewater = "f5e0dc";
        flamingo = "f2cdcd";
        pink = "f5c2e7";
        mauve = "cba6f7";
        red = "f38ba8";
        maroon = "eba0ac";
        peach = "fab387";
        yellow = "f9e2af";
        green = "a6e3a1";
        teal = "94e2d5";
        sky = "89dceb";
        sapphire = "74c7ec";
        blue = "89b4fa";
        lavender = "b4befe";
        klink = "89b4fa";
        klinkSelection = "89b4fa";
        kvisited = "cba6f7";
        kvisitedSelection = "cba6f7";
        knegative = "f38ba8";
        knegativeSelection = "f38ba8";
        kneutral = "f9e2af";
        kneutralSelection = "f9e2af";
        kpositive = "a6e3a1";
        kpositiveSelection = "a6e3a1";
        text = "cdd6f4";
        subtext1 = "bac2de";
        subtext0 = "a6adc8";
        overlay2 = "9399b2";
        overlay1 = "7f849c";
        overlay0 = "6c7086";
        surface2 = "585b70";
        surface1 = "45475a";
        surface0 = "313244";
        base = "1e1e2e";
        mantle = "181825";
        crust = "11111b";
        success = "a6e3a1";
        onSuccess = "1e3a1c";
        successContainer = "2d5a2a";
        onSuccessContainer = "d4f7d2";
      };
    };

    home.activation.caelestiaMutableScheme = inputs.home-manager.lib.hm.dag.entryAfter ["writeBoundary"] ''
      stateDir="''${XDG_STATE_HOME:-$HOME/.local/state}/caelestia"
      schemePath="$stateDir/scheme.json"
      seedPath=${lib.escapeShellArg (pkgs.writeText "caelestia-scheme.json" xdg.stateFile."caelestia/scheme.json".text)}

      $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$stateDir"
      tempPath="$(${pkgs.coreutils}/bin/mktemp "$stateDir/.scheme.json.XXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tempPath"' EXIT

      ${pkgs.coreutils}/bin/cp "$seedPath" "$tempPath"
      ${pkgs.coreutils}/bin/chmod 0600 "$tempPath"
      if [[ -L "$schemePath" ]] || ! ${pkgs.diffutils}/bin/cmp -s "$tempPath" "$schemePath"; then
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$schemePath"
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv "$tempPath" "$schemePath"
      fi
    '';

    programs.caelestia = {
      enable = true;
      package = caelestiaShell;

      cli = {
        enable = true;
        package = caelestiaCli;
        settings.theme.enableGtk = false;
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

        background.enabled = false;

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
            name = "Clipboard";
            icon = "content_paste";
            description = "Browse clipboard history";
            command = ["autocomplete" "clipboard"];
            enabled = true;
            dangerous = false;
          }
          {
            name = "Emoji";
            icon = "emoji_emotions";
            description = "Pick an emoji to copy";
            command = ["autocomplete" "emoji"];
            enabled = true;
            dangerous = false;
          }
          {
            name = "Keybinds";
            icon = "keyboard";
            description = "View all keyboard shortcuts";
            command = ["autocomplete" "keybinds"];
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
