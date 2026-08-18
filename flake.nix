{
  description = "Modular configuration of NixOS, Home Manager, and Nix-Darwin with Denix";

  inputs = {
    catppuccin = {
      url = "github:catppuccin/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.home-manager.follows = "home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-colors.url = "github:Misterio77/nix-colors";

    nautilus-my-computer = {
      url = "github:yannmasoch/nautilus-my-computer?dir=packaging/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    nixvim.url = "github:skulldogged/nixvim-new";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    snappy-switcher = {
      url = "github:skulldogged/snappy-switcher/feature/window-previews";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    twemoji-src = {
      url = "github:jdecked/twemoji";
      flake = false;
    };

    bang-bang = {
      url = "github:oh-my-fish/plugin-bang-bang";
      flake = false;
    };

    caelestia-shell = {
      url = "github:dim-ghub/caelestia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-cli-nix = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    t3code-flake = {
      url = "github:omarcresp/t3code-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    denix = {
      url = "github:yunfachi/denix";
      inputs = {
        home-manager.follows = "home-manager";
        nix-darwin.follows = "nix-darwin";
        nixpkgs.follows = "nixpkgs";
      };
    };

    difftastic-src = {
      url = "github:skulldogged/difftastic";
      flake = false;
    };

    draconisplusplus = {
      url = "github:skulldogged/draconisplusplus-monorepo";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    draconisplusplus-plugins = {
      url = "github:skulldogged/draconisplusplus-plugins";
      inputs.draconisplusplus.follows = "draconisplusplus";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.utils.follows = "draconisplusplus/utils";
    };

    draconisplusplus-plugin-lab = {
      url = "github:skulldogged/draconisplusplus-plugin-lab";
      inputs.draconisplusplus.follows = "draconisplusplus";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.utils.follows = "draconisplusplus/utils";
    };

    fish-git-abbr = {
      url = "github:pupbrained/fish-git-abbr/patch-1";
      flake = false;
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland = {
      url = "github:hyprwm/Hyprland";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    gloview = {
      url = "github:fedsfarm/gloview";
      inputs.hyprland.follows = "hyprland";
    };

    grok-build-src = {
      url = "github:xai-org/grok-build";
      flake = false;
    };

    hyprglass = {
      url = "github:hyprnux/hyprglass";
      flake = false;
    };

    jellyfin-src = {
      url = "github:skulldogged/jellyfin";
      flake = false;
    };

    jellyfin-web-src = {
      url = "github:jellyfin/jellyfin-web";
      flake = false;
    };

    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    license = {
      url = "github:oh-my-fish/plugin-license";
      flake = false;
    };

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    replay-fish = {
      url = "github:jorgebucaran/replay.fish";
      flake = false;
    };

    vicinae = {
      url = "github:vicinaehq/vicinae";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {denix, ...} @ inputs: let
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = inputs.nixpkgs.lib.genAttrs systems;

    treefmtEval = forAllSystems (
      system:
        inputs.treefmt-nix.lib.evalModule (import inputs.nixpkgs {inherit system;}) {
          projectRootFile = "flake.nix";

          programs = {
            alejandra.enable = true;
            deadnix.enable = true;
            jsonfmt.enable = true;
            stylua.enable = true;
            taplo.enable = true;
          };
        }
    );

    mkConfigurations = moduleSystem:
      denix.lib.configurations {
        inherit moduleSystem;
        homeManagerUser = "marshall";

        paths = [
          ./hosts
          ./modules
          ./rices
        ];

        extensions = with denix.lib.extensions; [
          args
          (base.withConfig {
            args.enable = true;
          })
        ];

        specialArgs = {
          inherit inputs;
        };
      };
  in rec {
    nixosConfigurations =
      inputs.nixpkgs.lib.getAttrs ["navis" "polaris"]
      (mkConfigurations "nixos")
      // {
        polaris-bootstrap = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {inherit inputs;};
          modules = [./migration/polaris/bootstrap.nix];
        };

        polaris-installer = inputs.nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {inherit inputs;};
          modules = [./migration/polaris/installer.nix];
        };
      };

    darwinConfigurations =
      inputs.nixpkgs.lib.getAttrs ["canis"]
      (mkConfigurations "darwin");

    formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

    packages.x86_64-linux.pi = let
      pkgs = import inputs.nixpkgs {system = "x86_64-linux";};
      homeConfig = nixosConfigurations.navis.config.home-manager.users.marshall;
      piConfig = homeConfig.programs.pi-coding-agent;
      piPackage = piConfig.package;
      piFiles = homeConfig.home.file;
      standaloneSettings =
        piConfig.settings
        // {
          packages = piConfig.settings.packages ++ ["npm:pi-mcp-adapter"];
        };

      settings = pkgs.writeText "pi-denix-settings.json" (builtins.toJSON standaloneSettings);
      claudifyDefaults = pkgs.writeText "pi-claudify-defaults.json" (builtins.toJSON {
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
      });
      blackholeDefaults = pkgs.writeText "pi-blackhole-defaults.json" (builtins.toJSON {
        compactAfterTokens = 150000;
        compaction = "auto";
        compactionEngine = "blackhole";
        debug = false;
        debugLog = false;
        memory = true;
        midRunCompaction = "off";
        tailBehavior = "pi-default";
      });

      setup = pkgs.writeShellScript "pi-denix-setup" ''
        set -eu

        link_managed() {
          target="$1"
          source="$2"
          ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$target")"
          if [ -L "$target" ]; then
            ${pkgs.coreutils}/bin/ln -sfn "$source" "$target"
          elif [ -e "$target" ]; then
            echo "pi-denix: preserving unmanaged file $target" >&2
          else
            ${pkgs.coreutils}/bin/ln -s "$source" "$target"
          fi
        }

        seed_mutable() {
          target="$1"
          seed="$2"
          directory="$(${pkgs.coreutils}/bin/dirname "$target")"
          ${pkgs.coreutils}/bin/mkdir -p "$directory"
          temporary="$(${pkgs.coreutils}/bin/mktemp "$directory/.pi-denix.XXXXXX")"
          trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT

          if [ -L "$target" ] || [ ! -e "$target" ]; then
            ${pkgs.coreutils}/bin/cp "$seed" "$temporary"
          elif [ -f "$target" ]; then
            ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$seed" "$target" > "$temporary"
          else
            echo "pi-denix: expected a regular file at $target" >&2
            exit 1
          fi

          ${pkgs.coreutils}/bin/chmod 0600 "$temporary"
          if [ -L "$target" ] || ! ${pkgs.diffutils}/bin/cmp -s "$temporary" "$target"; then
            ${pkgs.coreutils}/bin/rm -f "$target"
            ${pkgs.coreutils}/bin/mv "$temporary" "$target"
          fi
          trap - EXIT
          [ ! -e "$temporary" ] || ${pkgs.coreutils}/bin/rm -f "$temporary"
        }

        ${pkgs.coreutils}/bin/mkdir -p "$HOME/.pi/agent"
        ${pkgs.coreutils}/bin/chmod 0700 "$HOME/.pi" "$HOME/.pi/agent"

        link_managed "$HOME/.pi/agent/bin/pi" "${piPackage}/bin/pi"
        link_managed "$HOME/.pi/agent/settings.json" "${settings}"
        link_managed "$HOME/.pi/agent/AGENTS.md" "${piFiles.".pi/agent/AGENTS.md".source}"
        link_managed "$HOME/.pi/agent/extensions/subagent/config.json" "${piFiles.".pi/agent/extensions/subagent/config.json".source}"
        link_managed "$HOME/.pi/agent/extensions/more-below.ts" "${piFiles.".pi/agent/extensions/more-below.ts".source}"
        link_managed "$HOME/.pi/agent/themes/catppuccin-mocha.json" "${piFiles.".pi/agent/themes/catppuccin-mocha.json".source}"

        seed_mutable "$HOME/.pi/settings.json" "${claudifyDefaults}"
        seed_mutable "$HOME/.pi/agent/pi-blackhole/pi-blackhole-config.json" "${blackholeDefaults}"
      '';

      setupCommand = pkgs.writeShellScriptBin "pi-denix-setup" ''
        exec ${setup} "$@"
      '';
      launcher = pkgs.writeShellScriptBin "pi" ''
        ${setup}
        export PI_SKIP_VERSION_CHECK=1
        export PATH="${pkgs.lib.makeBinPath piConfig.extraPackages}:$PATH"
        exec ${piPackage}/bin/pi "$@"
      '';
    in
      pkgs.symlinkJoin {
        name = "pi-denix-0.84.0";
        paths = [launcher setupCommand] ++ piConfig.extraPackages;
        passthru = {
          inherit piPackage settings;
        };
        meta.mainProgram = "pi";
      };

    checks = forAllSystems (system: {
      formatting = treefmtEval.${system}.config.build.check inputs.self;
    });

    devShells = forAllSystems (
      system: let
        pkgs = import inputs.nixpkgs {inherit system;};
      in {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            alejandra
            git
            lua-language-server
            nh
            statix

            (writeScriptBin "build" ''
              nix fmt
              nh ${
                if stdenv.hostPlatform.isDarwin
                then "darwin"
                else "os"
              } switch
            '')
            (writeScriptBin "up" "nix flake update")
          ];
        };
      }
    );
  };
}
