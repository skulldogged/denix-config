{
  delib,
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
    piEnvironment = {
      PI_CACHE_RETENTION = "long";
      PI_SKIP_VERSION_CHECK = "1";
    };
    blackholeDefaults = {
      compactAfterTokens = 150000;
      compaction = "auto";
      compactionEngine = "blackhole";
      debug = false;
      debugLog = false;
      memory = true;
      midRunCompaction = "off";
      observerModel = {
        provider = "openai-codex";
        id = "gpt-5.6-luna";
        thinking = "low";
      };
      observerFallbackModels = [
        {
          provider = "openai-codex";
          id = "gpt-5.6-terra";
          thinking = "low";
        }
      ];
      reflectorModel = {
        provider = "openai-codex";
        id = "gpt-5.6-terra";
        thinking = "low";
      };
      reflectorFallbackModels = [
        {
          provider = "openai-codex";
          id = "gpt-5.6-luna";
          thinking = "low";
        }
      ];
      dropperModel = {
        provider = "openai-codex";
        id = "gpt-5.6-luna";
        thinking = "low";
      };
      dropperFallbackModels = [
        {
          provider = "openai-codex";
          id = "gpt-5.6-terra";
          thinking = "low";
        }
      ];
      sessionFallback = false;
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
    claudifySource = pkgs.fetchzip {
      url = "https://registry.npmjs.org/@owlburtoe/pi-claudify/-/pi-claudify-2.5.1.tgz";
      hash = "sha256-VnaO1O49fLbo50n3uGy7aIkuB3WyZISYL496G/gDSpw=";
    };
    diffSource = pkgs.fetchzip {
      url = "https://registry.npmjs.org/diff/-/diff-8.0.2.tgz";
      hash = "sha256-kJR4VIQfCCI4F0oa4y/cxza9PWJ7I9UC7lmj2MsJ0Y4=";
    };
    lspSource = pkgs.fetchzip {
      url = "https://registry.npmjs.org/lsp-pi/-/lsp-pi-1.0.5.tgz";
      hash = "sha256-TfPT32aBzeN7DUMxoAimilovT2gZ5B6epJ8PT0HqI5M=";
    };
    undoRedoSource = pkgs.fetchzip {
      url = "https://registry.npmjs.org/pi-undo-redo/-/pi-undo-redo-0.1.1.tgz";
      hash = "sha256-DqjwReYpgZNowax5I3yx60pYUMVXtwexCTH4QWtPJTg=";
    };
    piClaudify =
      pkgs.runCommand "pi-claudify-2.5.1-unified-edit-compat" {
        nativeBuildInputs = [pkgs.jq pkgs.patch];
      } ''
        cp -R ${claudifySource}/. "$out"
        chmod -R u+w "$out"
        patch --directory="$out" -p1 < ${./pi-claudify-unified-edit.patch}
        jq '.name = "pi-claudify-unified-edit-compat"' \
          "$out/package.json" > "$out/package.json.new"
        mv "$out/package.json.new" "$out/package.json"
        mkdir "$out/node_modules"
        ln -s ${diffSource} "$out/node_modules/diff"
      '';
    piRuntimeProbePackages = pkgs.linkFarm "pi-runtime-probe-node-modules" [
      {
        name = "@owlburtoe/pi-claudify";
        path = claudifySource;
      }
      {
        name = "lsp-pi";
        path = lspSource;
      }
      {
        name = "pi-undo-redo";
        path = undoRedoSource;
      }
    ];
    piUnifiedEdit =
      pkgs.runCommand "pi-unified-edit-1.6.0-compat" {
        nativeBuildInputs = [pkgs.bun pkgs.patch];
      } ''
        mkdir -p "$out/extensions" "$out/node_modules/@earendil-works"
        cp ${
          pkgs.fetchzip {
            url = "https://github.com/mitsuhiko/agent-stuff/archive/13bc8f87970bec8830aab0f1c0487d35aa7c0917.tar.gz";
            hash = "sha256-PmIfimUsSw+UnnWwth+x1gF1MHtAInZBfpx2Whvfbhw=";
          }
        }/extensions/unified-edit.ts "$out/extensions/unified-edit.ts"
        chmod -R u+w "$out"
        patch --directory="$out" -p1 < ${./pi-unified-edit.patch}
        ln -s ${diffSource} "$out/node_modules/diff"
        ln -s ${piOpaque}/lib/node_modules/pi-monorepo \
          "$out/node_modules/@earendil-works/pi-coding-agent"
        ln -s ${piOpaque}/lib/node_modules/pi-monorepo/node_modules/@earendil-works/pi-tui \
          "$out/node_modules/@earendil-works/pi-tui"
        cp ${
          pkgs.writeText "pi-unified-edit-package.json" (builtins.toJSON {
            name = "pi-unified-edit";
            version = "1.6.0";
            type = "module";
            dependencies.diff = "8.0.2";
            peerDependencies = {
              "@earendil-works/pi-coding-agent" = "*";
              "@earendil-works/pi-tui" = "*";
            };
            pi.extensions = ["./extensions/unified-edit.ts"];
          })
        } "$out/package.json"
        PI_UNIFIED_EDIT_SOURCE="$out/extensions/unified-edit.ts" \
          bun test ${./pi-unified-edit.test.mjs}
      '';
    piLsp =
      pkgs.runCommand "lsp-pi-1.0.5-unified-edit-compat" {
        nativeBuildInputs = [pkgs.bun pkgs.jq pkgs.patch];
      } ''
        cp -R ${lspSource}/. "$out"
        chmod -R u+w "$out"
        sed -i 's/[[:space:]]*$//' "$out/lsp-core.ts" "$out/lsp.ts"
        patch --directory="$out" -p1 < ${./lsp-pi-unified-edit.patch}

        mkdir -p "$out/node_modules/@earendil-works"
        cp -R ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/vscode-languageserver-protocol/-/vscode-languageserver-protocol-3.17.5.tgz";
            hash = "sha256-SR7l2IouLbWTyXNODq1fOm/JFdHWLHESARIpuG8e1iY=";
          }
        } "$out/node_modules/vscode-languageserver-protocol"
        chmod -R u+w "$out/node_modules/vscode-languageserver-protocol"
        mkdir -p "$out/node_modules/vscode-languageserver-protocol/node_modules"
        ln -s ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/vscode-languageserver-types/-/vscode-languageserver-types-3.17.5.tgz";
            hash = "sha256-YXOIdZS2zpA1JeBWRJzNf0NClUwhaRNMVOjLzJyDaNY=";
          }
        } "$out/node_modules/vscode-languageserver-types"
        ln -s ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/vscode-jsonrpc/-/vscode-jsonrpc-8.2.0.tgz";
            hash = "sha256-k26vzbJwUXgBn3zvwyN7lQ5eLRgnzZ8l0ntoV7dEJ8w=";
          }
        } "$out/node_modules/vscode-jsonrpc"
        ln -s ../../vscode-jsonrpc \
          "$out/node_modules/vscode-languageserver-protocol/node_modules/vscode-jsonrpc"
        ln -s ../../vscode-languageserver-types \
          "$out/node_modules/vscode-languageserver-protocol/node_modules/vscode-languageserver-types"
        ln -s ${piOpaque}/lib/node_modules/pi-monorepo \
          "$out/node_modules/@earendil-works/pi-coding-agent"
        ln -s ${piOpaque}/lib/node_modules/pi-monorepo/node_modules/@earendil-works/pi-ai \
          "$out/node_modules/@earendil-works/pi-ai"
        ln -s ${piOpaque}/lib/node_modules/pi-monorepo/node_modules/@earendil-works/pi-tui \
          "$out/node_modules/@earendil-works/pi-tui"

        jq '.name = "lsp-pi-unified-edit-compat"
          | .peerDependencies = {
              "@earendil-works/pi-ai": "*",
              "@earendil-works/pi-coding-agent": "*",
              "@earendil-works/pi-tui": "*"
            }
          | .pi = { extensions: ["./lsp-guard.ts", "./lsp.ts", "./lsp-tool.ts"] }' \
          "$out/package.json" > "$out/package.json.new"
        mv "$out/package.json.new" "$out/package.json"
        PATH=${pkgs.nixd}/bin:$PATH PI_LSP_SOURCE="$out" \
          bun test ${./lsp-pi-unified-edit.test.mjs}
        ${piOpaque}/lib/node_modules/pi-monorepo/node_modules/.bin/tsgo \
          -p "$out/tsconfig.json"
      '';
    piUndoRedo =
      pkgs.runCommand "pi-undo-redo-0.1.1-unified-edit-compat" {
        nativeBuildInputs = [pkgs.bun pkgs.jq pkgs.patch];
      } ''
        cp -R ${undoRedoSource}/. "$out"
        chmod -R u+w "$out"
        sed -i 's/\r$//' "$out/src/extension.ts"
        patch --directory="$out" -p1 < ${./pi-undo-redo-unified-edit.patch}
        jq '.name = "pi-undo-redo-unified-edit-compat" | .pi = { extensions: ["./src/extension.ts"] }' \
          "$out/package.json" > "$out/package.json.new"
        mv "$out/package.json.new" "$out/package.json"
        PI_CLAUDIFY_SOURCE=${piClaudify} \
        PI_LSP_SOURCE=${piLsp} \
        PI_UNDO_SOURCE="$out" \
          bun test ${./pi-unified-edit-compat.test.mjs}
        PI_BIN=${piOpaque}/bin/pi \
        PI_UNIFIED_EDIT_ROOT=${piUnifiedEdit} \
        PI_CLAUDIFY_ROOT=${piClaudify} \
        PI_LSP_ROOT=${piLsp} \
        PI_UNDO_ROOT="$out" \
        PI_NPM_ROOT=${piRuntimeProbePackages} \
        PATH=${pkgs.nixd}/bin:$PATH \
          ${pkgs.nodejs}/bin/node ${./pi-unified-edit-runtime-probe.mjs}
      '';
    piSubagents =
      pkgs.runCommand "pi-subagents-0.46.0-prompt-status" {
        nativeBuildInputs = [pkgs.patch];
      } ''
        cp -R ${
          pkgs.fetchzip {
            url = "https://registry.npmjs.org/pi-subagents/-/pi-subagents-0.46.0.tgz";
            hash = "sha256-vYns4/59C+gvEEIi/UDH8dUt21PBesh+PM/6xkU2/nQ=";
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

      type UsageTotals = {
        input: number;
        output: number;
        cacheRead: number;
      };

      function addAssistantUsage(totals: UsageTotals, message: any): void {
        if (message?.role !== "assistant") return;
        totals.input += message.usage?.input ?? 0;
        totals.output += message.usage?.output ?? 0;
        totals.cacheRead += message.usage?.cacheRead ?? 0;
      }

      function calculateUsageTotals(ctx: any): UsageTotals {
        const totals: UsageTotals = { input: 0, output: 0, cacheRead: 0 };
        for (const entry of ctx.sessionManager.getBranch()) {
          if (entry.type === "message") addAssistantUsage(totals, entry.message);
        }
        return totals;
      }

      function renderPiDetails(
        pi: ExtensionAPI,
        ctx: any,
        shellPrompt: string,
        fleetStatus: FleetStatusSummary | undefined,
        totals: UsageTotals,
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

        parts.push(theme.fg("dim", " · "));
        parts.push(
          theme.fg("syntaxFunction", "↑ " + tk(totals.input)) +
            (totals.cacheRead > 0 ? theme.fg("dim", "/" + tk(totals.cacheRead)) : "") +
            " " +
            theme.fg("syntaxString", "↓ " + tk(totals.output)),
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
        let usageTotals: UsageTotals = { input: 0, output: 0, cacheRead: 0 };

        const update = (ctx: any) => {
          if (ctx.mode !== "tui") return;
          currentContext = ctx;
          const line = renderPiDetails(pi, ctx, shellPrompt, fleetStatus, usageTotals);
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
          if (currentContext?.mode === "tui") update(currentContext);
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
          if (ctx.mode !== "tui") return;

          usageTotals = calculateUsageTotals(ctx);
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

        pi.on("session_shutdown", (_event, ctx) => {
          refreshGeneration++;
          if (bashTimer) clearTimeout(bashTimer);
          bashTimer = undefined;
          shellPrompt = "";
          fleetStatus = undefined;
          currentContext = undefined;
          usageTotals = { input: 0, output: 0, cacheRead: 0 };
          if (ctx.mode === "tui") {
            ctx.ui.setWidget("starship-info", undefined);
            ctx.ui.setFooter(undefined);
            ctx.ui.setEditorComponent(undefined);
          }
        });
        pi.on("agent_start", (_event, ctx) => update(ctx));
        pi.on("turn_end", (event, ctx) => {
          addAssistantUsage(usageTotals, event.message);
          update(ctx);
        });
        pi.on("agent_end", (_event, ctx) => update(ctx));
        pi.on("model_select", (_event, ctx) => update(ctx));
        pi.on("user_bash", (_event, ctx) => {
          if (ctx.mode !== "tui") return;
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
      version = "0.84.1";
      src = pkgs.fetchFromGitHub {
        owner = "earendil-works";
        repo = "pi";
        tag = "v${version}";
        hash = "sha256-lg+I4S/aAjazjhGZU567ow+rksoNiqOqjHl//TjAMes=";
      };
      npmDepsHash = "sha256-tufyZQRPAUeDtiq0UQodbKA/Y9xUAvNT8K+NWFjkeME=";
      npmDeps = pkgs.fetchNpmDeps {
        inherit src;
        hash = npmDepsHash;
      };
      modelData = pkgs.fetchurl {
        url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-${version}.tgz";
        hash = "sha256-araJGJ58s95c2xJjEqPmDorDX+XuXxtj0A9xHIpDDHM=";
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
      sessionVariables = piEnvironment;
      sessionPath = ["${piOpaque}/bin"];

      file = {
        ".pi/agent/bin/pi".source = "${piOpaque}/bin/pi";
        ".pi/agent/AGENTS.md".text = ''
          # Subagents

          Use subagents selectively. Delegate when parallel reconnaissance or research, a
          separate writer, or an independent review is expected to materially improve
          correctness or wall-clock time. Handle focused work directly when it can be
          inspected, completed, and verified in one linear pass.

          Before using an unfamiliar subagent workflow or execution control, read the
          relevant `pi-subagents` skill section; do not reread it for every child in the
          same session.

          Keep the parent responsible for orchestration and the final answer. Use one
          writer per working directory and give parallel children distinct, self-contained
          assignments. Prefer fresh context with a focused handoff; use forked context only
          when the child genuinely needs the parent session's decisions or history.

          Default to at most one scout when reconnaissance is needed and one fresh reviewer
          for material multi-file, risky, or user-requested changes. Use one review round by
          default. Do not launch duplicate reviews or sequential review loops without a
          concrete unresolved risk.

          Writers should run the narrowest relevant checks first. The parent owns at most
          one final full validation gate and should not repeat a passing full build unless
          relevant files or build inputs changed. Do not impose hard turn or tool limits on
          mutation-capable workers; narrow or steer an unexpectedly long run instead.
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

    systemd.user.sessionVariables = piEnvironment;

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
        enableInstallTelemetry = false;
        lsp.hookMode = "agent_end";
        subagents = {
          # Keep routine child work off the expensive parent model. Roles can still be
          # overridden explicitly per run when a task needs a different capability tier.
          defaultModel = "openai-codex/gpt-5.6-terra";
          defaultThinking = "medium";
          agentOverrides = {
            scout = {
              model = "openai-codex/gpt-5.6-luna";
              thinking = "low";
              extensions = [];
              defaultContext = "fresh";
            };
            delegate = {
              model = "openai-codex/gpt-5.6-luna";
              thinking = "low";
              extensions = [];
              defaultContext = "fresh";
            };
            worker = {
              model = "openai-codex/gpt-5.6-terra";
              thinking = "medium";
              extensions = [];
              defaultContext = "fresh";
            };
            reviewer = {
              model = "openai-codex/gpt-5.6-terra";
              thinking = "medium";
              extensions = [];
              defaultContext = "fresh";
            };
            researcher = {
              model = "openai-codex/gpt-5.6-terra";
              thinking = "medium";
              defaultContext = "fresh";
            };
            oracle = {
              model = "openai-codex/gpt-5.6-sol";
              thinking = "high";
              extensions = [];
              defaultContext = "fork";
            };
          };
        };
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
          # Unified Edit must load first: Pi 0.84.1 keeps the first extension
          # registration when several packages provide the same tool name.
          "${piUnifiedEdit}"
          # Claudify remains unpinned for dependencies and update visibility,
          # while the local build omits only its conflicting edit registration.
          {
            source = "npm:@owlburtoe/pi-claudify";
            extensions = [];
          }
          "${piClaudify}"
          # This package owns the final editor, widget, and hidden footer state.
          "${piStarship}"
          # Keep this after pi-starship so its user_bash refresh handler runs
          # before Fish supplies the execution backend.
          "${piFishPackage}"
          "npm:@mrclrchtr/supi-ask-user"
          "npm:pi-blackhole"
          # Keep upstream unpinned for update visibility, but run only the
          # reviewed local guard, hook, and tool extensions.
          {
            source = "npm:lsp-pi";
            extensions = [];
          }
          "${piLsp}"
          "npm:pi-mcp-adapter"
          "npm:pi-simplify"
          "${piSubagents}"
          {
            source = "npm:pi-undo-redo";
            extensions = [];
          }
          "${piUndoRedo}"
          "npm:pi-web-access"
        ];
      };
    };
  };

  nixos.ifEnabled = {myconfig, ...}: {
    systemd.tmpfiles.rules = [
      "d /home/${myconfig.constants.username}/.pi 0700 ${myconfig.constants.username} users -"
      "d /home/${myconfig.constants.username}/.pi/agent 0700 ${myconfig.constants.username} users -"
    ];
  };
}
