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
    piFishProfile = pkgs.writeText "pi-fish-profile.fish" ''
      # Commands entered with Pi's ! shortcut run in an interactive Fish shell.
      # Keep Pi-specific shell behavior here instead of changing the normal
      # Home Manager Fish configuration for every non-interactive invocation.
      set --global --export PI_MANUAL_SHELL 1
    '';
    piFishShell = pkgs.writeShellScript "pi-fish-shell" ''
      exec ${pkgs.fish}/bin/fish \
        --interactive \
        --init-command ${pkgs.lib.escapeShellArg "source ${piFishProfile}"} \
        "$@"
    '';
    piFishExtension = pkgs.writeText "pi-fish-shell.ts" ''
      import {
        createLocalBashOperations,
        type ExtensionAPI,
      } from "@earendil-works/pi-coding-agent";

      const fishOperations = createLocalBashOperations({
        shellPath: "${piFishShell}",
      });

      export default function (pi: ExtensionAPI): void {
        // Scope Fish to commands the user enters with ! or !!. Agent tool calls
        // keep Pi's normal shell backend and its predictable Bash semantics.
        pi.on("user_bash", () => ({ operations: fishOperations }));
      }
    '';
    piFishPackage = pkgs.linkFarm "pi-fish-shell-1.0.0" [
      {
        name = "extension.ts";
        path = piFishExtension;
      }
      {
        name = "package.json";
        path = pkgs.writeText "pi-fish-shell-package.json" (builtins.toJSON {
          name = "pi-fish-shell";
          version = "1.0.0";
          pi.extensions = ["./extension.ts"];
        });
      }
    ];
    piMoreBelowExtension = pkgs.writeText "more-below.ts" ''
      import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
      import { TuiAltScreen } from "@earendil-works/pi-tui";

      const WIDGET_ID = "more-messages-below";

      function labelForWidth(width: number): string {
        if (width >= 42) return "↓ more messages below · End to jump";
        if (width >= 24) return "↓ more messages below";
        if (width >= 12) return "↓ more below";
        return "↓";
      }

      export default function moreBelow(pi: ExtensionAPI): void {
        pi.on("session_start", (_event, ctx) => {
          if (ctx.mode !== "tui") return;

          ctx.ui.setWidget(
            WIDGET_ID,
            (tui, theme) => ({
              render(width: number): string[] {
                // The factory receives Pi's stable TUI proxy. Its prototype and
                // properties follow the active renderer when /settings switches modes.
                if (!(tui instanceof TuiAltScreen) || tui.isFollowingOutput) return [];

                const label = labelForWidth(width);
                return [theme.bold(theme.fg("warning", label))];
              },
              invalidate(): void {},
            }),
            { placement: "aboveEditor" },
          );
        });

        pi.on("session_shutdown", (_event, ctx) => {
          if (ctx.mode === "tui") ctx.ui.setWidget(WIDGET_ID, undefined);
        });
      }
    '';
    piSubagents =
      pkgs.runCommand "pi-subagents-0.45.1-prompt-status" {
        nativeBuildInputs = [pkgs.patch];
      } ''
        cp -R ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/pi-subagents/-/pi-subagents-0.45.1.tgz";
            hash = "sha256-tp4ToGLz9NIpAzdCOGQNV+0H0akPsFFh1FZQlVFAEdY=";
          }
        }/. "$out"
        chmod -R u+w "$out"
        patch --directory="$out" -p1 < ${./pi-subagents-prompt-status.patch}

        mkdir -p "$out/node_modules"
        ln -s ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/jiti/-/jiti-2.7.0.tgz";
            hash = "sha256-oPonUKfp30HUGa5NRgyRoVqpf+s5ztkB1YpUNOAUJIA=";
          }
        } "$out/node_modules/jiti"
        ln -s ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/typebox/-/typebox-1.1.38.tgz";
            hash = "sha256-0Drk/INyZFu562LoQa5wrB+b0DTQoTaotbI/spOCHVI=";
          }
        } "$out/node_modules/typebox"
        ln -s ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/yaml/-/yaml-2.8.3.tgz";
            hash = "sha256-sslihpXhi8dVxXJ8svHg4lpKGdGL74Oqqs5J/P/jvDg=";
          }
        } "$out/node_modules/yaml"
      '';
    piStarshipExtension = pkgs.writeText "extension.ts" ''
      import { execFile } from "node:child_process";
      import { basename } from "node:path";
      import { promisify } from "node:util";
      import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
      import { Text } from "@earendil-works/pi-tui";
      import { StarshipEditor, tk } from "./index.ts";

      const runFile = promisify(execFile);

      type FleetStatusSummary = {
        activeAgents: number;
      };

      function renderPiDetails(
        pi: ExtensionAPI,
        ctx: any,
        shellPrompt: string,
        fleetStatus: FleetStatusSummary | undefined,
      ): string {
        const theme = ctx.ui.theme;
        const parts: string[] = [
          shellPrompt || theme.bold(theme.fg("syntaxFunction", basename(ctx.cwd))),
        ];
        const model = ctx.model?.id;

        if (model) {
          const provider = ctx.model?.provider ?? "";
          const providerIcons: Record<string, string> = {
            "openai-codex": "",
            openai: "",
            anthropic: "",
            "github-copilot": "",
            "github-copilot-enterprise": "",
          };
          const icon = providerIcons[provider] ?? "󰚩";
          parts.push(" via ", theme.bold(theme.fg("syntaxString", icon + " " + model)));
        }

        const thinking = pi.getThinkingLevel();
        if (thinking !== "off") {
          const colors: Record<string, string> = {
            minimal: "thinkingMinimal",
            low: "thinkingLow",
            medium: "thinkingMedium",
            high: "thinkingHigh",
            xhigh: "thinkingXhigh",
          };
          parts.push(" ", theme.bold(theme.fg(colors[thinking] ?? "warning", "󱐋 " + thinking)));
        }

        if (fleetStatus && fleetStatus.activeAgents > 0) {
          const label = fleetStatus.activeAgents + " active " + (fleetStatus.activeAgents === 1 ? "agent" : "agents");
          parts.push(
            theme.fg("dim", " · "),
            theme.fg("muted", label),
          );
        }

        let input = 0;
        let output = 0;
        let cacheRead = 0;
        for (const entry of ctx.sessionManager.getBranch()) {
          if (entry.type !== "message" || entry.message.role !== "assistant") continue;
          input += entry.message.usage.input ?? 0;
          output += entry.message.usage.output ?? 0;
          cacheRead += entry.message.usage.cacheRead ?? 0;
        }

        parts.push(theme.fg("dim", " · "));
        parts.push(
          theme.fg("syntaxFunction", "↑ " + tk(input)) +
            (cacheRead > 0 ? theme.fg("dim", "/" + tk(cacheRead)) : "") +
            " " +
            theme.fg("syntaxString", "↓ " + tk(output)),
        );
        const usage = ctx.getContextUsage();
        if (usage) {
          const limit = ctx.model?.contextWindow ?? usage.limit;
          const percent = limit > 0 ? (usage.tokens / limit) * 100 : 0;
          const color = limit > 0 ? (percent > 85 ? "error" : percent > 60 ? "warning" : "success") : "dim";
          parts.push(
            theme.fg("dim", " · "),
            theme.fg(color, "󰍛 " + tk(usage.tokens) + "/" + (limit > 0 ? tk(limit) : "???")),
          );
        }

        return parts.join("");
      }

      export default function (pi: ExtensionAPI): void {
        let shellPrompt = "";
        let fleetStatus: FleetStatusSummary | undefined;
        let currentContext: any;
        let refreshGeneration = 0;
        let bashTimer: ReturnType<typeof setTimeout> | undefined;

        const update = (ctx: any) => {
          currentContext = ctx;
          const line = renderPiDetails(pi, ctx, shellPrompt, fleetStatus);
          ctx.ui.setWidget("starship-info", () => new Text(line, 0, 0));
        };

        pi.events.on("subagent:fleet-status", (value) => {
          if (
            value &&
            typeof value === "object" &&
            Number.isFinite((value as FleetStatusSummary).activeAgents)
          ) {
            fleetStatus = value as FleetStatusSummary;
          } else {
            fleetStatus = undefined;
          }
          if (currentContext?.hasUI) update(currentContext);
        });

        const refreshShellPrompt = async (ctx: any) => {
          const generation = ++refreshGeneration;
          try {
            const { stdout } = await runFile(
              "${pkgs.starship}/bin/starship",
              [
                "prompt",
                "--status", "0",
                "--pipestatus", "0",
                "--jobs", "0",
                "--cmd-duration", "0",
                "--keymap", "insert",
                "--terminal-width", "4096",
              ],
              {
                cwd: ctx.cwd,
                env: { ...process.env, STARSHIP_SHELL: "fish" },
                timeout: 1500,
              },
            );
            if (generation !== refreshGeneration) return;
            shellPrompt = stdout
              .replace(/\u001b\[J/g, "")
              .split("\n")
              .find((line) => line.trim().length > 0)
              ?.trim() ?? "";
          } catch {
            if (generation !== refreshGeneration) return;
            shellPrompt = "";
          }
          update(ctx);
        };

        pi.on("session_start", (_event, ctx) => {
          if (!ctx.hasUI) return;

          ctx.ui.setEditorComponent(
            (tui, editorTheme, keybindings) =>
              new StarshipEditor(tui, editorTheme, keybindings, undefined, ctx),
          );
          ctx.ui.setFooter(() => ({
            invalidate() {},
            render() {
              return [];
            },
          }));
          update(ctx);
          void refreshShellPrompt(ctx);
        });

        pi.on("session_switch", (_event, ctx) => void refreshShellPrompt(ctx));
        pi.on("agent_start", (_event, ctx) => update(ctx));
        pi.on("turn_end", (_event, ctx) => update(ctx));
        pi.on("agent_end", (_event, ctx) => update(ctx));
        pi.on("model_select", (_event, ctx) => update(ctx));
        pi.on("user_bash", (_event, ctx) => {
          if (bashTimer) clearTimeout(bashTimer);
          bashTimer = setTimeout(() => void refreshShellPrompt(ctx), 300);
        });
      }
    '';
    piStarship = pkgs.runCommand "pi-starship-1.0.0-earendil" {nativeBuildInputs = [pkgs.jq];} ''
      cp -R ${
        pkgs.fetchzip {
          url = "https://registry.npmjs.org/@elianiva/pi-starship/-/pi-starship-1.0.0.tgz";
          hash = "sha256-m/lOx6ddpFMMeMU/MFz7y4L41OMwQR2Vmawg/shT4I8=";
        }
      }/. "$out"
      chmod -R u+w "$out"

      substituteInPlace "$out/index.ts" \
        --replace-fail '@mariozechner/pi-ai' '@earendil-works/pi-ai' \
        --replace-fail '@mariozechner/pi-coding-agent' '@earendil-works/pi-coding-agent' \
        --replace-fail '@mariozechner/pi-tui' '@earendil-works/pi-tui'
      cp ${piStarshipExtension} "$out/extension.ts"
      jq '.pi = { extensions: ["./extension.ts"] }' "$out/package.json" > "$out/package.json.new"
      mv "$out/package.json.new" "$out/package.json"
    '';
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
          ./pi-wheel-scroll-lines.patch
          ./pi-starship-default-prompt.patch
          ./pi-fullscreen-scrollable-prompt.patch
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
          fleetViewPlacement = "prompt";
          missions.enabled = false;
          scheduledRuns.enabled = false;
          toolDescriptionMode = "compact";
        };
        ".pi/agent/extensions/more-below.ts".source = piMoreBelowExtension;
        ".pi/agent/themes/catppuccin-mocha.json".source =
          ../../files/pi/themes/catppuccin-mocha.json;
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
        theme = "catppuccin-mocha";
        tuiMode = "fullscreen";
        compaction = {
          reserveTokens = 49152;
          keepRecentTokens = 20000;
        };
        packages = [
          "npm:@owlburtoe/pi-claudify"
          # This package owns the final editor, widget, and hidden footer state.
          "${piStarship}"
          # Keep this after pi-starship so its user_bash refresh handler runs
          # before Fish supplies the execution backend.
          "${piFishPackage}"
          "npm:@mrclrchtr/supi-ask-user"
          "npm:pi-blackhole@0.4.5"
          "npm:pi-lens"
          "npm:pi-simplify"
          "${piSubagents}"
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
