{
  delib,
  config,
  inputs,
  pkgs,
  ...
}:
delib.module {
  name = "programs.pi-coding-agent";

  options.programs.pi-coding-agent = with delib; {
    enable = boolOption false;
  };

  home.ifEnabled = let
    piComfyUi = pkgs.applyPatches {
      name = "pi-comfy-ui-0.3.0-pi-0.84";
      src = pkgs.fetchFromGitHub {
        owner = "adanft";
        repo = "pi-comfy-ui";
        rev = "4b7251f2ccde4df46e6e2c77a93873d6056141cf";
        hash = "sha256-f0DaC8te+X0hnWehL4FSIKk3uy4M/uogqYRUCIIhCzM=";
      };
      patches = [./pi-comfy-ui-pi-0.84.patch];
    };
    claudifyDefaults = {
      accentColor = "theme";
      bashSemanticDisplay = true;
      diffPalette = "theme";
      editorBorder = "thinking";
      footerStyle = "pi";
      messageStyle = "classic";
      readOnlyToolGrouping = true;
      themeAdaptive = true;
      toolBackground = "outlines";
      toolChrome = "theme";
      userMessageBox = "theme";
    };
    blackholeDefaults = {
      compactAfterTokens = 150000;
      compaction = "auto";
      compactionEngine = "blackhole";
      debug = false;
      debugLog = false;
      memory = true;
      midRunCompaction = "off";
      tailBehavior = "pi-default";
    };
    piOpaque = pkgs.pi-coding-agent.overrideAttrs (old: rec {
      version = "0.84.0";
      src = pkgs.fetchFromGitHub {
        owner = "earendil-works";
        repo = "pi";
        tag = "v${version}";
        hash = "sha256-qySIyclHsWUo/Uap9rCl97amvKBbHfRXlOB16t8t3Ns=";
      };
      npmDepsHash = "sha256-pIpwMAmSWjJKM5P+jltU/L/vS+d5JWNJYiIChfSZGOE=";
      npmDeps = pkgs.fetchNpmDeps {
        inherit src;
        hash = npmDepsHash;
      };
      modelData = pkgs.fetchurl {
        url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-${version}.tgz";
        hash = "sha256-WWDOeXctyqZZmC8LENp3qeMvapehFSu7LMfsZh/LzOo=";
      };
      preConfigure = ''
        mkdir -p packages/ai/src/providers/data
        tar --extract --gzip --file=${modelData} \
          --directory=packages/ai/src/providers/data \
          --strip-components=4 \
          package/dist/providers/data
      '';
      patches =
        (old.patches or [])
        ++ [
          ./pi-opaque-background.patch
          ./pi-wheel-scroll-lines.patch
          ./pi-comfy-default-editor.patch
          ./pi-catppuccin-default-footer.patch
        ];
      buildPhase = ''
        runHook preBuild

        npx tsgo -p packages/tui/tsconfig.build.json
        npx tsgo -p packages/telemetry/tsconfig.build.json
        npx tsgo -p packages/ai/tsconfig.build.json
        npx tsgo -p packages/agent/tsconfig.build.json
        npx tsgo -p packages/protocol/tsconfig.build.json
        npx tsgo -p packages/client/tsconfig.build.json
        npm run build --workspace=packages/coding-agent

        runHook postBuild
      '';
      postInstall =
        ''
          local nm="$out/lib/node_modules/pi-monorepo/node_modules"

          for ws in @earendil-works/pi-ai:packages/ai \
                    @earendil-works/pi-agent-core:packages/agent \
                    @earendil-works/pi-client:packages/client \
                    @earendil-works/pi-protocol:packages/protocol \
                    @earendil-works/pi-telemetry:packages/telemetry \
                    @earendil-works/pi-tui:packages/tui; do
            IFS=: read -r pkg workspace <<< "$ws"
            rm "$nm/$pkg"
            cp -r "$workspace" "$nm/$pkg"
          done

          find "$nm" -type l -lname '*/packages/*' -delete
          find "$nm/.bin" -xtype l -delete
        ''
        + pkgs.lib.optionalString pkgs.stdenvNoCC.hostPlatform.isDarwin ''
          rm -rf \
            "$nm/@anthropic-ai/sandbox-runtime/dist/vendor/seccomp" \
            "$nm/@anthropic-ai/sandbox-runtime/vendor/seccomp"
        '';
    });
  in {
    home = {
      sessionVariables.PI_SKIP_VERSION_CHECK = "1";
      sessionPath = ["${piOpaque}/bin"];

      file = {
        ".pi/agent/bin/pi".source = "${piOpaque}/bin/pi";
        ".pi/agent/AGENTS.md".text = ''
          # Subagents

          For every non-trivial task, proactively use the `pi-subagents` skill and
          `subagent` tool without waiting for the user to ask. Read the skill before
          delegating, and use focused children for codebase reconnaissance, independent
          research, implementation, verification, or fresh review when they materially
          improve the result.

          Keep the parent session responsible for orchestration and the final answer. Use
          one writer per working directory, prefer fresh-context reviewers, and give each
          parallel child a distinct, self-contained assignment. Handle genuinely small or
          strictly linear tasks directly when delegation would add more overhead than value.
        '';
        ".pi/agent/extensions/subagent/config.json".text = builtins.toJSON {
          artifactDir = "session";
          asyncWidget = false;
          fleetView = true;
          fleetViewPlacement = "aboveEditor";
          missions.enabled = false;
          scheduledRuns.enabled = false;
          toolDescriptionMode = "compact";
        };
        ".pi/agent/themes/catppuccin-mocha-opaque.json".source =
          ../../files/pi/themes/catppuccin-mocha-opaque.json;
        ".pi-lens/config.json".text = builtins.toJSON {
          widget.visible = false;
        };
      };

      # Claudify's settings screen rewrites ~/.pi/settings.json. Seed a regular,
      # user-owned file so /claudify remains writable; runtime choices override
      # these declared defaults on later activations.
      activation.piClaudifyMutableSettings = inputs.home-manager.lib.hm.dag.entryAfter ["writeBoundary"] ''
        settingsDir="$HOME/.pi"
        settingsPath="$settingsDir/settings.json"
        seedPath=${pkgs.lib.escapeShellArg (pkgs.writeText "pi-claudify-defaults.json" (builtins.toJSON claudifyDefaults))}

        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$settingsDir"
        tempPath="$(${pkgs.coreutils}/bin/mktemp "$settingsDir/.settings.json.XXXXXX")"
        trap '${pkgs.coreutils}/bin/rm -f "$tempPath"' EXIT

        if [[ -L "$settingsPath" || ! -e "$settingsPath" ]]; then
          ${pkgs.coreutils}/bin/cp "$seedPath" "$tempPath"
        elif [[ -f "$settingsPath" ]]; then
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$seedPath" "$settingsPath" > "$tempPath"
        else
          errorEcho "Pi settings are not a regular file: $settingsPath"
          exit 1
        fi

        ${pkgs.coreutils}/bin/chmod 0600 "$tempPath"
        if [[ -L "$settingsPath" ]] || ! ${pkgs.diffutils}/bin/cmp -s "$tempPath" "$settingsPath"; then
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$settingsPath"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv "$tempPath" "$settingsPath"
        fi
      '';

      # Blackhole's settings overlay writes this file at runtime. Seed a regular,
      # user-owned file so experiments remain writable while these defaults are
      # restored whenever the file is missing or still managed as a symlink.
      activation.piBlackholeMutableConfig = inputs.home-manager.lib.hm.dag.entryAfter ["writeBoundary"] ''
        configDir="$HOME/.pi/agent/pi-blackhole"
        configPath="$configDir/pi-blackhole-config.json"
        seedPath=${pkgs.lib.escapeShellArg (pkgs.writeText "pi-blackhole-defaults.json" (builtins.toJSON blackholeDefaults))}

        $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$configDir"
        tempPath="$(${pkgs.coreutils}/bin/mktemp "$configDir/.pi-blackhole-config.json.XXXXXX")"
        trap '${pkgs.coreutils}/bin/rm -f "$tempPath"' EXIT

        if [[ -L "$configPath" || ! -e "$configPath" ]]; then
          ${pkgs.coreutils}/bin/cp "$seedPath" "$tempPath"
        elif [[ -f "$configPath" ]]; then
          ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$seedPath" "$configPath" > "$tempPath"
        else
          errorEcho "Blackhole config is not a regular file: $configPath"
          exit 1
        fi

        ${pkgs.coreutils}/bin/chmod 0600 "$tempPath"
        if [[ -L "$configPath" ]] || ! ${pkgs.diffutils}/bin/cmp -s "$tempPath" "$configPath"; then
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/rm -f "$configPath"
          $DRY_RUN_CMD ${pkgs.coreutils}/bin/mv "$tempPath" "$configPath"
        fi
      '';
    };

    programs.pi-coding-agent = {
      enable = true;
      package = piOpaque;
      extraPackages = with pkgs; [
        bun
        git
        nodejs
      ];

      settings = {
        defaultModel = "gpt-5.6-sol";
        defaultProvider = "openai-codex";
        defaultThinkingLevel = "high";
        npmCommand = [
          "${pkgs.bun}/bin/bun"
          "--minimum-release-age=0"
        ];
        theme = "catppuccin-mocha-opaque";
        tuiMode = "fullscreen";
        compaction = {
          reserveTokens = 49152;
          keepRecentTokens = 20000;
        };
        packages = [
          "${piComfyUi}"
          "npm:@owlburtoe/pi-claudify"
          "npm:@mrclrchtr/supi-ask-user"
          "npm:pi-blackhole@0.4.5"
          "npm:pi-lens"
          "npm:pi-simplify"
          "npm:pi-subagents@0.45.1"
          "npm:pi-undo-redo"
          "npm:pi-web-access"
        ];
      };
    };
  };

  nixos.ifEnabled = {myconfig, ...}: {
    sops.secrets.pi_meta_api_key.owner = myconfig.constants.username;

    sops.templates."pi-agent/models.json" = {
      owner = myconfig.constants.username;
      path = "/home/${myconfig.constants.username}/.pi/agent/models.json";
      content = builtins.toJSON {
        providers = {
          meta = {
            baseUrl = "https://api.meta.ai/v1";
            api = "openai-responses";
            apiKey = config.sops.placeholder.pi_meta_api_key;
            models = [
              {
                id = "muse-spark-1.2-contributor";
                name = "Muse Spark 1.2";
              }
            ];
          };
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d /home/${myconfig.constants.username}/.pi 0700 ${myconfig.constants.username} users -"
      "d /home/${myconfig.constants.username}/.pi/agent 0700 ${myconfig.constants.username} users -"
    ];
  };
}
