{
  delib,
  config,
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
      patches = (old.patches or []) ++ [./pi-opaque-background.patch];
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
    home.sessionVariables.PI_SKIP_VERSION_CHECK = "1";
    home.sessionPath = ["${piOpaque}/bin"];
    home.file = {
      ".pi/agent/bin/pi".source = "${piOpaque}/bin/pi";
      ".pi/agent/themes/catppuccin-mocha-opaque.json".source =
        ../../files/pi/themes/catppuccin-mocha-opaque.json;
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
        theme = "catppuccin-mocha-opaque";
        tuiMode = "fullscreen";

        packages = [
          "${piComfyUi}"
          "npm:@heyhuynhgiabuu/pi-pretty"
          "npm:@mjakl/pi-subagent"
          "npm:@mrclrchtr/supi-ask-user"
          "npm:pi-catppuccin-tui"
          "npm:pi-lens"
          "npm:pi-simplify"
          "npm:pi-smart-compact"
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
