{
  description = "Modular configuration of NixOS, Home Manager, and Nix-Darwin with Denix";

  inputs = {
    catppuccin.url = "github:catppuccin/nix";
    impermanence.url = "github:nix-community/impermanence";
    nix-colors.url = "github:Misterio77/nix-colors";
    nix-minecraft.url = "github:skulldogged/nix-minecraft";
    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixvim.url = "github:skulldogged/nixvim-new";
    opencode.url = "github:anomalyco/opencode/dev";
    sops-nix.url = "github:Mic92/sops-nix";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    vscode-server.url = "github:nix-community/nixos-vscode-server";

    aurelia = {
      url = "git+ssh://git@github.com/skulldogged/aurelia";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    bang-bang = {
      url = "github:oh-my-fish/plugin-bang-bang";
      flake = false;
    };

    caelestia-shell = {
      url = "github:caelestia-dots/shell";
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

    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };

    jellyfin-src = {
      url = "github:skulldogged/jellyfin";
      flake = false;
    };

    jellyfin-web-src = {
      url = "github:skulldogged/jellyfin-web";
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

    linux-wallpaperengine-src = {
      url = "git+https://github.com/Almamu/linux-wallpaperengine?submodules=1";
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
  in {
    nixosConfigurations = mkConfigurations "nixos";
    homeConfigurations = mkConfigurations "home";
    darwinConfigurations = mkConfigurations "darwin";

    formatter = inputs.nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (
      system: let
        pkgs = import inputs.nixpkgs {inherit system;};
      in
        inputs.treefmt-nix.lib.mkWrapper pkgs {
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

    devShells = inputs.nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux" "aarch64-darwin"] (
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
              ${
                if stdenv.isLinux
                then ''
                  sudo nix run \
                    --option experimental-features "nix-command flakes" \
                    --option extra-substituters https://numtide.cachix.org \
                    --option extra-trusted-public-keys numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE= \
                    github:numtide/nixos-facter -- -o hosts/$(hostname)/facter.json
                ''
                else ""
              }
              nix fmt
              nh ${
                if stdenv.isDarwin
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
