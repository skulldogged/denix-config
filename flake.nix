{
  description = "Modular configuration of NixOS, Home Manager, and Nix-Darwin with Denix";

  inputs = {
    cua.url = "github:trycua/cua/cua-driver-rs-v0.21.0";
    nix-colors.url = "github:Misterio77/nix-colors";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixvim.url = "github:skulldogged/nixvim-new";

    bang-bang = {
      url = "github:oh-my-fish/plugin-bang-bang";
      flake = false;
    };

    caelestia-shell = {
      url = "github:dim-ghub/caelestia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    catppuccin = {
      url = "github:catppuccin/nix";
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

    draconisplusplus-plugin-lab = {
      url = "github:skulldogged/draconisplusplus-plugin-lab";
      inputs = {
        draconisplusplus.follows = "draconisplusplus";
        nixpkgs.follows = "nixpkgs";
        utils.follows = "draconisplusplus/utils";
      };
    };

    draconisplusplus-plugins = {
      url = "github:skulldogged/draconisplusplus-plugins";
      inputs = {
        draconisplusplus.follows = "draconisplusplus";
        nixpkgs.follows = "nixpkgs";
        utils.follows = "draconisplusplus/utils";
      };
    };

    fish-git-abbr = {
      url = "github:pupbrained/fish-git-abbr/patch-1";
      flake = false;
    };

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprglass = {
      url = "github:hyprnux/hyprglass";
      flake = false;
    };

    hyprland = {
      url = "github:hyprwm/Hyprland";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.home-manager.follows = "home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
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

    nautilus-my-computer = {
      url = "github:yannmasoch/nautilus-my-computer?dir=packaging/nix";
      inputs.nixpkgs.follows = "nixpkgs";
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

    snappy-switcher = {
      url = "github:skulldogged/snappy-switcher/feature/window-previews";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    t3code-flake = {
      url = "github:omarcresp/t3code-flake";
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
      (mkConfigurations "nixos");

    darwinConfigurations =
      inputs.nixpkgs.lib.getAttrs ["canis"]
      (mkConfigurations "darwin");

    formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

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
